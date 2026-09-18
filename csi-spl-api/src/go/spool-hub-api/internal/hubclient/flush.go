package hubclient

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SendMessage delivers a composed v:1 message in hub mode (contracts/flush.md
// §1) and returns its delivery: local, sent, queued or pending (OQ-09).
//
//   - same box (to_box == this box): local inbox + outbox; the hub is skipped
//     unless mirror is on.
//   - cross box: outbox, then the signed envelope is written pending-flush
//     BEFORE the hub is tried, so a crash or an unreachable hub loses nothing.
func (c *Client) SendMessage(ctx context.Context, m *msg.Message, explicitToBox string) (string, error) {
	own, priv, err := c.box()
	if err != nil {
		return "", err
	}
	toBox, err := c.ResolveToBox(m.To, explicitToBox)
	if err != nil {
		return "", err
	}
	mirror, err := c.Cfg.Mirror()
	if err != nil {
		return "", err
	}
	st := spool.New(c.Cfg)
	if toBox == own {
		if _, err := st.Deliver(m); err != nil {
			return "", err
		}
		if err := st.WriteOutbox(m); err != nil {
			return "", err
		}
		if !mirror {
			return wire.DeliveryLocal, nil
		}
	} else if err := st.WriteOutbox(m); err != nil {
		return "", err
	}

	env, err := wire.NewEnvelope(priv, own, toBox, m)
	if err != nil {
		return "", err
	}
	pending, err := c.writePending(m, env)
	if err != nil {
		return "", err
	}
	delivery, err := c.sendNow(ctx, env, m, pending)
	if toBox == own && err == nil {
		return wire.DeliveryLocal, nil // mirrored; the local copy is the delivery
	}
	return delivery, err
}

// sendNow tries one cli-role session: upload blobs, send, settle the pending file.
func (c *Client) sendNow(ctx context.Context, env *wire.Envelope, m *msg.Message, pending string) (string, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if errors.Is(err, ErrUnreachable) {
		return wire.DeliveryPending, nil
	}
	if err != nil {
		return "", err // e.g. an unpinned box: kept pending for a later flush
	}
	defer sess.Close()
	return sess.sendPending(ctx, env, m, pending)
}

func (s *Session) sendPending(ctx context.Context, env *wire.Envelope, m *msg.Message, pending string) (string, error) {
	for _, a := range m.Files {
		if a.Mode != "blob" {
			continue
		}
		if err := s.UploadFile(ctx, a.FileID); err != nil {
			if errors.Is(err, ErrUnreachable) {
				return wire.DeliveryPending, nil
			}
			return "", err
		}
	}
	f, err := s.Send(ctx, env)
	var he *HubError
	switch {
	case errors.Is(err, ErrUnreachable):
		return wire.DeliveryPending, nil
	case errors.As(err, &he) && he.clientError():
		s.c.reject(pending)
		return "", err
	case err != nil:
		return wire.DeliveryPending, nil // 5xx: retry on the next flush
	}
	os.Remove(pending)
	return f.Delivery, nil
}

func (c *Client) pendingDir() string  { return filepath.Join(c.Cfg.HubDir(), "pending") }
func (c *Client) rejectedDir() string { return filepath.Join(c.Cfg.HubDir(), "rejected") }

// writePending stores the signed envelope as <ts>--<msg_id>.json (oldest-first
// by name). Flush sends these exact bytes: no re-sign, ts and to_box unchanged.
func (c *Client) writePending(m *msg.Message, env *wire.Envelope) (string, error) {
	raw, err := env.Marshal()
	if err != nil {
		return "", err
	}
	stamp := strings.NewReplacer("-", "", ":", "").Replace(m.TS)
	p := filepath.Join(c.pendingDir(), stamp+"--"+m.MsgID+".json")
	return p, writeAtomic(p, raw)
}

func (c *Client) reject(pending string) {
	if pending == "" {
		return
	}
	dst := filepath.Join(c.rejectedDir(), filepath.Base(pending))
	if err := os.MkdirAll(c.rejectedDir(), 0o775); err == nil {
		os.Rename(pending, dst) //nolint:errcheck
	}
}

// Pending lists the pending-flush envelope files, oldest first.
func (c *Client) Pending() ([]string, error) {
	ents, err := os.ReadDir(c.pendingDir())
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") {
			out = append(out, filepath.Join(c.pendingDir(), e.Name()))
		}
	}
	sort.Strings(out)
	return out, nil
}

// Flush sends every pending envelope on s (contracts/flush.md §2). It stops at
// the first refusal (moved to rejected/, returned: exit 78 for verify-class)
// or when the hub drops (the rest stay pending).
func (s *Session) Flush(ctx context.Context) (int, error) {
	list, err := s.c.Pending()
	if err != nil {
		return 0, err
	}
	n := 0
	for _, p := range list {
		raw, err := os.ReadFile(p)
		if err != nil {
			return n, err
		}
		env, err := wire.ParseEnvelope(raw)
		if err != nil {
			s.c.reject(p)
			return n, fmt.Errorf("pending %s: %w", filepath.Base(p), err)
		}
		m, err := env.Inner()
		if err != nil {
			s.c.reject(p)
			return n, fmt.Errorf("pending %s: %w", filepath.Base(p), err)
		}
		d, err := s.sendPending(ctx, env, m, p)
		if err != nil {
			return n, err
		}
		if d == wire.DeliveryPending {
			return n, fmt.Errorf("%w: flush interrupted", ErrUnreachable)
		}
		n++
	}
	return n, nil
}

// SyncReport is what a one-shot hub-sync did.
type SyncReport struct {
	Delivered int `json:"delivered"`
	Flushed   int `json:"flushed"`
	Pending   int `json:"pending"`
	Refused   int `json:"refused"`
}

// Sync is one role=box session: hello, pin sync, drain the hub queue, flush
// pending, close. A refused recv frame (e.g. unsynced sender pin) is returned
// as the error after the rest has run.
func (c *Client) Sync(ctx context.Context) (SyncReport, error) {
	var r SyncReport
	sess, err := c.Dial(ctx, wire.RoleBox)
	if err != nil {
		return r, err
	}
	defer sess.Close()
	if _, err := sess.WaitQueueEnd(ctx); err != nil {
		return r, err
	}
	r.Flushed, err = sess.Flush(ctx)
	left, _ := c.Pending()
	r.Pending = len(left)
	r.Delivered = sess.Delivered()
	rerrs := sess.RecvErrors()
	r.Refused = len(rerrs)
	if err != nil {
		return r, err
	}
	if len(rerrs) > 0 {
		return r, rerrs[0]
	}
	return r, nil
}

// Run is the box daemon (`spool hub-run`): it holds the role=box session,
// reconnecting with exponential backoff (1 s doubling to a 30 s cap, jitter)
// on any close, re-helloing, flushing, refreshing pins on an interval and
// re-announcing the roster when the $SPOOL_ROOT/*/ scan changes (OQ-05). It
// returns when ctx ends, or ErrSuperseded when a newer hello took the box.
func (c *Client) Run(ctx context.Context) error {
	const base, maxBackoff = time.Second, 30 * time.Second
	backoff := base
	for {
		sess, err := c.Dial(ctx, wire.RoleBox)
		if err == nil {
			backoff = base
			c.Log.Info().Str("box", c.Cfg.BoxID).Msg("hub session up")
			if err := c.hold(ctx, sess); err != nil {
				return err
			}
		} else {
			c.Log.Warn().Err(err).Dur("retry_in", backoff).Msg("hub session down")
		}
		if ctx.Err() != nil {
			return nil
		}
		sleep := backoff/2 + time.Duration(rand.Int64N(int64(backoff/2)+1))
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(sleep):
		}
		if backoff *= 2; backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

// hold serves one session until it ends. It returns ErrSuperseded on 4409 and
// nil for every other close (the caller reconnects).
func (c *Client) hold(ctx context.Context, sess *Session) error {
	defer sess.Close()
	if _, err := sess.Flush(ctx); err != nil {
		c.Log.Warn().Err(err).Msg("flush")
	}
	agents, _ := c.scanAgents()
	last := strings.Join(agents, ",")
	pins := time.NewTicker(c.PinRefresh)
	defer pins.Stop()
	scan := time.NewTicker(10 * time.Second)
	defer scan.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-sess.Done():
			if sess.CloseCode() == wire.CloseSuperseded {
				return ErrSuperseded
			}
			return nil
		case <-pins.C:
			if err := sess.SyncPins(ctx); err != nil {
				c.Log.Warn().Err(err).Msg("pin refresh")
			}
		case <-scan.C:
			if a, err := c.scanAgents(); err == nil && strings.Join(a, ",") != last {
				last = strings.Join(a, ",")
				sess.Announce(ctx) //nolint:errcheck
			}
			if left, _ := c.Pending(); len(left) > 0 {
				sess.Flush(ctx) //nolint:errcheck
			}
		}
	}
}
