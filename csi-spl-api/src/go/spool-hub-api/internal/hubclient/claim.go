package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Claim sends one claim frame (op poll | renew | release | done, body = the
// op's claim object) over a one-shot role=cli session (spec 068 4.1). It
// returns the hub's answer {seat, msgs, dead}. A refusal is a *HubError.
func (c *Client) Claim(ctx context.Context, op string, body json.RawMessage) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	id := uid.New()
	f, err := sess.request(ctx, wire.Frame{Type: wire.TClaim, MsgID: id, ClaimOp: op, Claim: body}, wire.TClaim,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Claim, nil
}
