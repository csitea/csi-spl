package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Lease reads (op "get") or compare-and-sets (op "cas": holder, ifGen) one
// role's fleet-wide lease over a one-shot role=cli session (CLE-77911). It
// returns the hub's answer {fleet, role, holder, box, gen, age_s, won}; a
// lost race is won=false, not an error. A refusal is a *HubError.
func (c *Client) Lease(ctx context.Context, op, fleet, role, holder string, ifGen int64) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	id := uid.New()
	f, err := sess.request(ctx, wire.Frame{Type: wire.TLease, MsgID: id, LeaseOp: op, Fleet: fleet, LeaseRole: role, Holder: holder, IfGen: ifGen}, wire.TLease,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Lease, nil
}
