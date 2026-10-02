package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Ask sends one ask frame (op put | list | ack | done | decline | raise |
// escalate, body = the op's ask object) over a one-shot role=cli session
// (CLE-77929). It returns the hub's answer {fleet, created, asks}. A refusal
// is a *HubError.
func (c *Client) Ask(ctx context.Context, op, fleet string, body json.RawMessage) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	id := uid.New()
	f, err := sess.request(ctx, wire.Frame{Type: wire.TAsk, MsgID: id, AskOp: op, Fleet: fleet, Ask: body}, wire.TAsk,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Ask, nil
}
