package action

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// MoveArgs is one topic move to another channel by a box agent: the verb
// behind `spool move`.
type MoveArgs struct {
	TaskID    string            `json:"task_id"`
	Channel   string            `json:"channel"`
	As        string            `json:"as"`
	ActingFor string            `json:"acting_for,omitempty"` // a HUM-* box operator, owner or admin
	Hub       *hubclient.Client `json:"-"`                    // nil = hubclient.New(cfg)
}

var moveHumanRe = regexp.MustCompile(`^HUM-[0-9]+$`)

// Move moves the topic and returns the hub's answer. Hub mode only: a
// topic's channel lives on the hub.
func Move(ctx context.Context, cfg *config.Config, in MoveArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("moving a topic needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	task := strings.ToLower(in.TaskID)
	if !editMsgIDRe.MatchString(task) {
		return nil, fmt.Errorf("--task must be the topic's task UUID")
	}
	ch := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(in.Channel), "#"))
	if ch == "" {
		return nil, fmt.Errorf("--channel (the target channel id) is required")
	}
	if !msg.ValidID(in.As) {
		return nil, fmt.Errorf("--as (the acting agent id) is required")
	}
	if in.ActingFor != "" && !moveHumanRe.MatchString(in.ActingFor) {
		return nil, fmt.Errorf("--acting-for must be a HUM-* id")
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	return hc.MoveTopic(ctx, task, ch, in.As, in.ActingFor)
}
