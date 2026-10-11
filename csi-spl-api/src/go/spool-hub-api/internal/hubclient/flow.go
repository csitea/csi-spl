package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// FlowRead reads agent as's folded Flow (spec 130 section 5) over a
// one-shot role=cli session: query is the page's kind / limit / before in
// URL query form. It returns the page object; a refusal is a *HubError.
func (c *Client) FlowRead(ctx context.Context, as, query string) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	return sess.FlowRead(ctx, as, query)
}

// FlowRead sends one flow_read frame on s and waits for its reply.
func (s *Session) FlowRead(ctx context.Context, as, query string) (json.RawMessage, error) {
	id := uid.New()
	f, err := s.request(ctx, wire.Frame{Type: wire.TFlowRead, MsgID: id, As: as, Query: query}, wire.TFlowRead,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Flow, nil
}
