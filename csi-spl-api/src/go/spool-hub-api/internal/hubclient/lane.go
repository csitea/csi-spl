package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Lane writes one row (op "put", row = the lane object) or lists every row
// (op "list", row nil) of the fleet-wide lane map over a one-shot role=cli
// session (CLE-77920). It returns the hub's answer {fleet, lanes}. A refusal
// is a *HubError.
func (c *Client) Lane(ctx context.Context, op, fleet string, row json.RawMessage) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	id := uid.New()
	f, err := sess.request(ctx, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: op, Fleet: fleet, Lane: row}, wire.TLane,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Lane, nil
}
