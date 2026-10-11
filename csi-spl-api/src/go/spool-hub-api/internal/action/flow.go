package action

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// FlowArgs is one agent Flow read (spec 130 section 5): the verb `spool
// flow` and the MCP tool spool_flow share.
type FlowArgs struct {
	As     string            `json:"as"`
	Kind   string            `json:"kind,omitempty"`   // mention | blocked | ready | release; "" = all
	Limit  int               `json:"limit,omitempty"`  // topic lines, 1..50; 0 = the hub's 30
	Before string            `json:"before,omitempty"` // the previous page's next
	Hub    *hubclient.Client `json:"-"`                // nil = hubclient.New(cfg)
}

// Flow reads the acting agent's folded Flow from the hub: one line per topic
// per UTC day of the lines that name it, blocked and ready included, and one
// line per UTC day of releases. Hub mode only.
func Flow(ctx context.Context, cfg *config.Config, in FlowArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("the flow needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	if in.As == "" {
		return nil, fmt.Errorf("--as (the acting agent id) is required")
	}
	v := url.Values{}
	if in.Kind != "" {
		v.Set("kind", in.Kind)
	}
	if in.Limit != 0 {
		v.Set("limit", strconv.Itoa(in.Limit))
	}
	if in.Before != "" {
		v.Set("before", in.Before)
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	return hc.FlowRead(ctx, in.As, v.Encode())
}
