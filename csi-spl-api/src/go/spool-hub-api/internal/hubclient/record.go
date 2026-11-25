package hubclient

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SendRecord hands the hub a record-only copy of m, a message this box
// already delivered locally (spec 058 section 7, `spool send --record-of`).
// The hub stores it by msg_id and delivers it to no box, so nothing here
// writes an inbox or an outbox.
//
// The signed envelope (to_box = this box) is written to the record queue
// FIRST, then sent on a one-shot cli session; a hub that is down leaves it
// queued (delivery pending) and the sidecar's flush sends it later. It never
// goes through the submit socket or pending/: an older sidecar would send it
// as a plain message, and the hub would then deliver it a second time.
func (c *Client) SendRecord(ctx context.Context, m *msg.Message) (string, error) {
	if err := c.redactKeys(ctx, m); err != nil { // spec 127 L9, as every hub send
		return "", err
	}
	if len(m.Files) > 0 {
		return "", fmt.Errorf("a record-only copy carries no attachments")
	}
	own, priv, err := c.box()
	if err != nil {
		return "", err
	}
	env, err := wire.NewEnvelope(priv, own, own, m)
	if err != nil {
		return "", err
	}
	raw, err := env.Marshal()
	if err != nil {
		return "", err
	}
	stamp := strings.NewReplacer("-", "", ":", "").Replace(m.TS)
	p := filepath.Join(c.recordDir(), stamp+"--"+m.MsgID+".json")
	if err := writeAtomic(p, raw); err != nil {
		return "", err
	}
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if errors.Is(err, ErrUnreachable) {
		return wire.DeliveryPending, nil
	}
	if err != nil {
		return "", err // e.g. an unpinned box: kept queued for a later flush
	}
	defer sess.Close()
	return sess.sendRecord(ctx, env, p)
}

// sendRecord sends one queued record and settles its file: removed once the
// hub took it, moved to rejected/ on a 4xx, kept (pending) otherwise.
func (s *Session) sendRecord(ctx context.Context, env *wire.Envelope, p string) (string, error) {
	f, err := s.sendFrame(ctx, env, wire.Frame{RecordOnly: true})
	var he *HubError
	switch {
	case errors.Is(err, ErrUnreachable):
		return wire.DeliveryPending, nil
	case errors.As(err, &he) && he.clientError():
		s.c.reject(p, err)
		return "", err
	case err != nil:
		return wire.DeliveryPending, nil // 5xx: retry on the next flush
	}
	os.Remove(p) //nolint:errcheck
	return f.Delivery, nil
}

// recordDir is the record queue: signed record-only envelopes the hub has
// not taken yet. Beside pending/, never inside it (see SendRecord).
func (c *Client) recordDir() string { return filepath.Join(c.Cfg.HubDir(), "pending-record") }

// Records lists the queued record envelopes, oldest first.
func (c *Client) Records() ([]string, error) {
	ents, err := os.ReadDir(c.recordDir())
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") {
			out = append(out, filepath.Join(c.recordDir(), e.Name()))
		}
	}
	sort.Strings(out)
	return out, nil
}

// flushRecords sends every queued record on s; it stops when the hub drops
// (the rest stay queued). A refused record is moved to rejected/ and the
// flush goes on: a record never holds back the next one.
func (s *Session) flushRecords(ctx context.Context) (int, error) {
	list, err := s.c.Records()
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
			continue
		}
		d, err := s.sendRecord(ctx, env, p)
		if d == wire.DeliveryPending {
			return n, fmt.Errorf("%w: record flush interrupted", ErrUnreachable)
		}
		if err == nil {
			n++
		}
	}
	return n, nil
}
