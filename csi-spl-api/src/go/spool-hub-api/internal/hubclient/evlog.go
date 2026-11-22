package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Evlog sends one evlog frame (spec 162 10.4.4: op cursor or put, body the
// wire.EvlogCursorReq or wire.EvlogPutReq) on a one-shot role=cli session
// and returns the hub's answer, a wire.EvlogCursor. A refusal (403
// operator.workspaces, 409 cursor_moved, ...) is a *HubError.
func (c *Client) Evlog(ctx context.Context, op string, body json.RawMessage) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	id := uid.New()
	f, err := sess.request(ctx, wire.Frame{Type: wire.TEvlog, MsgID: id, EvlogOp: op, Evlog: body}, wire.TEvlog,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Evlog, nil
}
