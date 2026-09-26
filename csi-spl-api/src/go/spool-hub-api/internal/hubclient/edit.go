package hubclient

import (
	"context"
	"fmt"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// EditResult is the hub's answer to a box edit (specs/032 message-edit-v1 §10).
type EditResult struct {
	MsgID    string `json:"msg_id"`
	TaskID   string `json:"task_id"`
	From     string `json:"from"`
	Revision int    `json:"revision"`
}

// EditMessage replaces the body of a message THIS box sent, over a one-shot
// role=cli session (§10): it fetches the stored envelope, swaps the body,
// re-signs it with this box's key and sends it back. as != "" also requires
// the stored msg.from to be that agent, so one agent on a shared box does not
// rewrite another's line by a mistyped id. A refusal is a *HubError.
func (c *Client) EditMessage(ctx context.Context, msgID, body, as string) (EditResult, error) {
	own, priv, err := c.box()
	if err != nil {
		return EditResult{}, err
	}
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return EditResult{}, err
	}
	defer sess.Close()
	id := strings.ToLower(msgID)
	old, err := sess.EditFetch(ctx, id)
	if err != nil {
		return EditResult{}, err
	}
	m, err := old.Inner()
	if err != nil {
		return EditResult{}, fmt.Errorf("stored message: %w", err)
	}
	if as != "" && m.From != as {
		return EditResult{}, fmt.Errorf("message %s was written by %s, not %s", id, m.From, as)
	}
	m.Body = body
	env, err := wire.NewEnvelopeIn(priv, own, old.ToBox, old.Channel, old.ParentTaskID, m)
	if err != nil {
		return EditResult{}, err
	}
	r, err := sess.EditApply(ctx, id, env)
	if err != nil {
		return EditResult{}, err
	}
	return EditResult{MsgID: id, TaskID: r.TaskID, From: m.From, Revision: r.Revision}, nil
}

// DeleteMessage removes a message THIS box sent (§10). as != "" requires the
// stored msg.from to be that agent, as for an edit.
func (c *Client) DeleteMessage(ctx context.Context, msgID, as string) (string, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return "", err
	}
	defer sess.Close()
	id := strings.ToLower(msgID)
	if as != "" {
		old, err := sess.EditFetch(ctx, id)
		if err != nil {
			return "", err
		}
		if m, err := old.Inner(); err != nil || m.From != as {
			return "", fmt.Errorf("message %s was not written by %s", id, as)
		}
	}
	r, err := sess.boxOp(ctx, wire.Frame{Type: wire.TDelete, MsgID: id})
	if err != nil {
		return "", err
	}
	return r.TaskID, nil
}

// EditFetch asks the hub for the stored envelope of a message this box sent:
// the bytes an edit re-signs.
func (s *Session) EditFetch(ctx context.Context, msgID string) (*wire.Envelope, error) {
	f, err := s.boxOp(ctx, wire.Frame{Type: wire.TEdit, MsgID: msgID})
	if err != nil {
		return nil, err
	}
	env, err := wire.ParseEnvelope(f.Env)
	if err != nil {
		return nil, fmt.Errorf("stored envelope: %w", err)
	}
	return env, nil
}

// EditApply sends a re-signed envelope for msgID; the reply carries the
// revision the hub wrote.
func (s *Session) EditApply(ctx context.Context, msgID string, env *wire.Envelope) (wire.Frame, error) {
	raw, err := env.Marshal()
	if err != nil {
		return wire.Frame{}, err
	}
	return s.boxOp(ctx, wire.Frame{Type: wire.TEdit, MsgID: msgID, Env: raw})
}

// boxOp sends one edit / delete frame and waits for its reply, paired on msg_id.
func (s *Session) boxOp(ctx context.Context, f wire.Frame) (wire.Frame, error) {
	id := f.MsgID
	return s.request(ctx, f, f.Type,
		func(r wire.Frame) bool { return r.MsgID == id || (r.Type == wire.TError && r.MsgID == "") })
}
