package action

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// TopicsArgs is one agent topic-list read (SPL t1 1457bb6f): the verb
// `spool topics`.
type TopicsArgs struct {
	As      string            `json:"as"`
	Channel string            `json:"channel"`
	Limit   int               `json:"limit,omitempty"`  // topics, 1..100; 0 = the hub's 50
	Before  string            `json:"before,omitempty"` // the previous page's next
	Hub     *hubclient.Client `json:"-"`                // nil = hubclient.New(cfg)
}

// Topics lists the root topics of one channel the acting agent is seated in,
// newest activity first: task id, subject and last activity, no bodies. A
// channel it is not in reads an empty page. Hub mode only.
func Topics(ctx context.Context, cfg *config.Config, in TopicsArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("the topic list needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	if in.As == "" {
		return nil, fmt.Errorf("--as (the acting agent id) is required")
	}
	in.Channel = strings.TrimPrefix(in.Channel, "#")
	if in.Channel == "" {
		return nil, fmt.Errorf("--channel is required")
	}
	v := url.Values{"channel": {in.Channel}}
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
	return hc.TopicList(ctx, in.As, v.Encode())
}
