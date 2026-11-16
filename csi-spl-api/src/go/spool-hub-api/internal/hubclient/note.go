package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// NoteAdd adds one note for agent as to the Notes of the person who asked
// for it (spec 155 2.11) over a one-shot role=cli session: note is the
// request object {ask_msg_id, title, body, pinned, priority, archived,
// items, links}. It returns the hub's {msg_id, id, created_at}; a refusal
// is a *HubError.
func (c *Client) NoteAdd(ctx context.Context, as string, note json.RawMessage) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	return sess.NoteAdd(ctx, as, note)
}

// NoteAdd sends one note_add frame on s and waits for its reply.
func (s *Session) NoteAdd(ctx context.Context, as string, note json.RawMessage) (json.RawMessage, error) {
	id := uid.New()
	f, err := s.request(ctx, wire.Frame{Type: wire.TNoteAdd, MsgID: id, As: as, Note: note}, wire.TNoteAdd,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Note, nil
}
