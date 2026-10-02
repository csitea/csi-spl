package hubclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
	return c.SendMessageTyped(ctx, m, explicitToBox, "")
}

// SendMessageTyped is SendMessage with a typed_by claim on the send frame
// (specs/036 FR-009): the HUM-* who typed this line at the agent's terminal.
// It rides outside the signed envelope, is kept beside the pending file so a
// queued send still carries it, and the hub accepts it only against a
// box_operators binding (FR-010) - else typed_by_not_bound, a 4xx.
func (c *Client) SendMessageTyped(ctx context.Context, m *msg.Message, explicitToBox, typedBy string) (string, error) {
	own, priv, err := c.box()
	if err != nil {
		return "", err
	}
	st := spool.New(c.Cfg)
	toBox, err := c.ResolveToBox(m.To, explicitToBox)
	// specs/061 3.6: an id this box retired inside the quarantine, addressed
	// here (or announced by no other box), bounces to its sender as a reject.
	if (err == nil && toBox == own) || (err != nil && explicitToBox == "") {
		if berr := st.BounceRetired(m); berr != nil {
			return "", berr
		}
	}
	if err != nil {
		return "", err
	}
	mirror, err := c.Cfg.Mirror()
	if err != nil {
		return "", err
	}
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
	pending, err := c.writePending(m, env, typedBy)
	if err != nil {
		return "", err
	}
	delivery, err := c.sendNow(ctx, env, m, pending, typedBy)
	if toBox == own && err == nil {
		return wire.DeliveryLocal, nil // mirrored; the local copy is the delivery
	}
	return delivery, err
}

// SendChannelTyped posts m into channel (specs/038): the agent's broadcast,
// the same shape a human's post has - msg.to ALL-0, to_box box-wui (no box
// owns a channel post; the hub builds one delivery per member box and shows
// it in the channel feed), the channel tag signed into the envelope. Nothing
// is written to a local inbox: the sender does not read its own post, and the
// other members on THIS box receive it back from the hub like any member.
// Queued and flushed like any cross-box send.
func (c *Client) SendChannelTyped(ctx context.Context, m *msg.Message, channel, typedBy string) (string, error) {
	own, priv, err := c.box()
	if err != nil {
		return "", err
	}
	if err := spool.New(c.Cfg).WriteOutbox(m); err != nil {
		return "", err
	}
	env, err := wire.NewEnvelopeIn(priv, own, wuiBox, channel, "", m)
	if err != nil {
		return "", err
	}
	pending, err := c.writePending(m, env, typedBy)
	if err != nil {
		return "", err
	}
	return c.sendNow(ctx, env, m, pending, typedBy)
}

// sendNow delivers one already-signed, already-pending envelope.
//
// specs/030 FP-2: it first offers the envelope to a LOCAL hub-run sidecar,
// which writes it on the warm hub session it already holds. That skips the
// cold dial this function used to pay every time - 220.6 ms p50 / 266.5 ms p95
// against the live dev hub (2026-09-21, n=20) - and the hub cannot tell the
// difference, because the bytes on the wire are the ones the CLI signed.
//
// Without a sidecar (or with SPOOL_SUBMIT_SOCKET=off) it falls through to the
// unchanged role=cli dial, so a box that runs no sidecar behaves exactly as it
// did before 030.
func (c *Client) sendNow(ctx context.Context, env *wire.Envelope, m *msg.Message, pending, typedBy string) (string, error) {
	if len(m.Files) == 0 { // blobs need the REST upload a cli session carries
		raw, err := env.Marshal()
		if err != nil {
			return "", err
		}
		switch d, serr := c.submit(ctx, raw, typedBy); {
		case serr == nil:
			removePending(pending)
			return d, nil
		case errors.Is(serr, errNoSidecar):
			// no listener: fall through to the dial below
		case errors.Is(serr, ErrUnreachable):
			// The sidecar or its hub link is in trouble. The pending file is
			// already on disk, so the flush retries and the hub dedups on
			// msg_id: at-most-once delivery is preserved either way.
			return wire.DeliveryPending, nil
		default:
			var he *HubError
			if errors.As(serr, &he) && he.clientError() {
				c.reject(pending, serr) // a 4xx will never be accepted, whoever sends it
			}
			return "", serr
		}
	}
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if errors.Is(err, ErrUnreachable) {
		return wire.DeliveryPending, nil
	}
	if err != nil {
		return "", err // e.g. an unpinned box: kept pending for a later flush
	}
	defer sess.Close()
	return sess.sendPending(ctx, env, m, pending, typedBy)
}

func (s *Session) sendPending(ctx context.Context, env *wire.Envelope, m *msg.Message, pending, typedBy string) (string, error) {
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
	f, err := s.SendTyped(ctx, env, typedBy)
	var he *HubError
	switch {
	case errors.Is(err, ErrUnreachable):
		return wire.DeliveryPending, nil
	case s.role == wire.RoleCLI && errors.As(err, &he) && he.Token == wire.TokenFromNotAnnounced:
		// A cli session cannot announce. The box session's flush will: it
		// re-announces and resends, or rejects if the agent is not hosted.
		return wire.DeliveryPending, nil
	case errors.As(err, &he) && he.clientError():
		s.c.reject(pending, err)
		return "", err
	case err != nil:
		return wire.DeliveryPending, nil // 5xx: retry on the next flush
	}
	removePending(pending)
	return f.Delivery, nil
}

// typedBySuffix names the file beside a pending envelope that holds its
// typed_by claim (specs/036 FR-009). The envelope file stays the exact signed
// bytes, so an older flusher still sends it (without the claim); Pending
// lists only *.json, so the sidecar is never mistaken for an envelope.
const typedBySuffix = ".typed_by"

// removePending drops a delivered pending envelope and its typed_by file.
func removePending(pending string) {
	if pending == "" {
		return
	}
	os.Remove(pending)                 //nolint:errcheck
	os.Remove(pending + typedBySuffix) //nolint:errcheck
}

// pendingTypedBy reads a pending envelope's typed_by claim ("" = none).
func pendingTypedBy(pending string) string {
	b, err := os.ReadFile(pending + typedBySuffix)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func (c *Client) pendingDir() string  { return filepath.Join(c.Cfg.HubDir(), "pending") }
func (c *Client) rejectedDir() string { return filepath.Join(c.Cfg.HubDir(), "rejected") }

// writePending stores the signed envelope as <ts>--<msg_id>.json (oldest-first
// by name). Flush sends these exact bytes: no re-sign, ts and to_box unchanged.
//
// A typed_by claim is written FIRST, beside it, so a flush that sees the
// envelope always sees its claim too.
func (c *Client) writePending(m *msg.Message, env *wire.Envelope, typedBy string) (string, error) {
	raw, err := env.Marshal()
	if err != nil {
		return "", err
	}
	stamp := strings.NewReplacer("-", "", ":", "").Replace(m.TS)
	p := filepath.Join(c.pendingDir(), stamp+"--"+m.MsgID+".json")
	if typedBy != "" {
		if err := writeAtomic(p+typedBySuffix, []byte(typedBy+"\n")); err != nil {
			return "", err
		}
	}
	return p, writeAtomic(p, raw)
}

// reasonSuffix names the file beside a rejected envelope that says why it was
// rejected (rejectReason as JSON). Like typedBySuffix it is not *.json, so
// nothing ever mistakes it for an envelope.
const reasonSuffix = ".reason"

// rejectReason is why an envelope left pending/ for good: the hub's refusal
// (Status + Token + Detail) or, with Status 0, a local one - an envelope this
// binary cannot parse or validate (Error).
type rejectReason struct {
	At     string `json:"at"`
	Status int    `json:"status,omitempty"`
	Token  string `json:"token,omitempty"`
	Detail string `json:"detail,omitempty"`
	Error  string `json:"error"`
}

// reject moves a pending envelope that will never be accepted to rejected/,
// and says why: one ERROR log line plus a <file>.reason beside it. A move
// without a reason is a message lost in silence: on prd 2026-10-02 two
// box-rsp -> c-002 sends sat in rejected/ with no trace, and the cause
// (a sidecar binary older than the c-NNN id grammar) had to be dug out of
// the binary itself.
func (c *Client) reject(pending string, why error) {
	if pending == "" {
		return
	}
	dst := filepath.Join(c.rejectedDir(), filepath.Base(pending))
	if err := os.MkdirAll(c.rejectedDir(), 0o775); err != nil {
		return
	}
	os.Rename(pending, dst)                             //nolint:errcheck
	os.Rename(pending+typedBySuffix, dst+typedBySuffix) //nolint:errcheck
	r := rejectReason{At: time.Now().UTC().Format(time.RFC3339)}
	if why != nil {
		r.Error = why.Error()
	}
	var he *HubError
	if errors.As(why, &he) {
		r.Status, r.Token, r.Detail = he.Status, he.Token, he.Detail
	}
	if raw, err := json.Marshal(r); err == nil {
		writeAtomic(dst+reasonSuffix, append(raw, '\n')) //nolint:errcheck
	}
	c.Log.Error().Str("box", c.Cfg.BoxID).Str("file", dst).Int("status", r.Status).
		Str("token", r.Token).Str("detail", r.Detail).Str("error", r.Error).
		Msg("moved a pending envelope to rejected/: it will never be delivered")
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
			s.c.reject(p, err)
			return n, fmt.Errorf("pending %s: %w", filepath.Base(p), err)
		}
		m, err := env.Inner()
		if err != nil {
			s.c.reject(p, err)
			return n, fmt.Errorf("pending %s: %w", filepath.Base(p), err)
		}
		d, err := s.sendPending(ctx, env, m, p, pendingTypedBy(p))
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
	// hub-sync still reports a pin it refused to overwrite. Run does not:
	// Dial has already kept the session.
	if sess.pinConflict != nil {
		return r, sess.pinConflict
	}
	return r, nil
}

// Run is the box daemon (`spool hub-run`): it holds the role=box session,
// reconnecting with capped exponential backoff and full jitter (1 s ceiling
// doubling to a 30 s cap; a Retry-After on the refused upgrade is honoured,
// see backoff.go) on any close, re-helloing, flushing, refreshing pins on an
// interval and re-announcing the roster when the $SPOOL_ROOT/*/ scan changes
// (OQ-05). The backoff resets only after a session stayed up for stableAfter,
// so a hub that accepts and drops at once is not hammered every second. It
// returns when ctx ends, or ErrSuperseded when a newer hello took the box.
func (c *Client) Run(ctx context.Context) error {
	b := newBackoff(runBackoffBase, runBackoffMax, runBackoffMax)
	for {
		var retryAfter time.Duration
		sess, err := c.Dial(ctx, wire.RoleBox)
		if err == nil {
			c.Log.Info().Str("box", c.Cfg.BoxID).Msg("hub session up")
			up := time.Now()
			if err := c.hold(ctx, sess); err != nil {
				return err
			}
			if time.Since(up) >= stableAfter {
				b.reset()
			}
		} else {
			retryAfter = retryAfterOf(err)
		}
		if ctx.Err() != nil {
			return nil
		}
		sleep := b.next(retryAfter)
		if err != nil {
			c.Log.Warn().Err(err).Dur("retry_in", sleep).Msg("hub session down")
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(sleep):
		}
	}
}

// hold serves one session until it ends. It returns ErrSuperseded on 4409 and
// nil for every other close (the caller reconnects).
//
// While it holds the session it also answers the box-local submit socket
// (specs/030 FP-2), so a `spool send` on this box writes its envelope on THIS
// warm socket instead of dialling its own. The listener lives and dies with the
// session: between reconnects there is nothing to submit to, and a CLI that
// finds no listener dials as it did before 030.
func (c *Client) hold(ctx context.Context, sess *Session) error {
	defer sess.Close()
	sctx, stopSubmit := context.WithCancel(ctx)
	defer stopSubmit()
	if srv, err := c.Listen(); err != nil {
		// Not fatal: the box keeps working, every send just pays the dial.
		c.Log.Warn().Err(err).Str("socket", c.Cfg.SubmitPath()).Msg("submit listener not opened; sends will dial")
	} else if srv != nil {
		defer srv.Close()
		go srv.Serve(sctx, sess)
		c.Log.Info().Str("socket", c.Cfg.SubmitPath()).Msg("submit listener up")
	}
	if _, err := sess.Flush(ctx); err != nil {
		c.Log.Warn().Err(err).Msg("flush")
	}
	agents, _ := c.scanAgents()
	last := strings.Join(agents, ",")
	pins := time.NewTicker(c.PinRefresh)
	defer pins.Stop()
	scan := time.NewTicker(10 * time.Second)
	defer scan.Stop()
	var probeC <-chan time.Time
	if every := c.SessionProbe; every >= 0 {
		if every == 0 {
			every = defaultSessionProbe
		}
		probe := time.NewTicker(every)
		defer probe.Stop()
		probeC = probe.C
	}
	// stranded logs why this session is being given up and returns true when
	// err proves the socket belongs to a hub process that no longer serves
	// REST (see Client.SessionProbe). hold then returns, its deferred Close
	// ends the socket, and Run redials - onto the process that does serve,
	// whose hello drains everything queued for this box meanwhile.
	stranded := func(what string, err error) bool {
		if !orphaned(err) {
			return false
		}
		c.Log.Warn().Err(err).Str("check", what).
			Msg("hub no longer knows this session (a hub redeploy or restart); closing it so the session reconnects")
		return true
	}
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
				if stranded("pin refresh", err) {
					return nil
				}
				c.Log.Warn().Err(err).Msg("pin refresh")
			}
		case <-probeC:
			if err := sess.Probe(ctx); err != nil {
				if stranded("session probe", err) {
					return nil
				}
				c.Log.Debug().Err(err).Msg("session probe")
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
