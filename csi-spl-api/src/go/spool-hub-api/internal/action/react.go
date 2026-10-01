package action

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// ReactArgs is one emoji reaction added or removed by a box agent
// (CLE-77895): the verb behind `spool react`. MsgID "" = the topic's
// opening message; TaskID may be "" when MsgID names the message.
type ReactArgs struct {
	TaskID string            `json:"task_id"`
	MsgID  string            `json:"msg_id,omitempty"`
	Emoji  string            `json:"emoji"`
	As     string            `json:"as"`
	Remove bool              `json:"remove,omitempty"`
	Hub    *hubclient.Client `json:"-"` // nil = hubclient.New(cfg)
}

// React adds (or removes) the reaction and returns the hub's answer.
// Hub mode only: reactions live on the hub.
func React(ctx context.Context, cfg *config.Config, in ReactArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("reacting needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	task, m := strings.ToLower(in.TaskID), strings.ToLower(in.MsgID)
	if m != "" && !editMsgIDRe.MatchString(m) {
		return nil, fmt.Errorf("--msg must be a message UUID")
	}
	if (task != "" || m == "") && !editMsgIDRe.MatchString(task) {
		return nil, fmt.Errorf("--task must be the topic's task UUID (or give --msg)")
	}
	if strings.TrimSpace(in.Emoji) == "" {
		return nil, fmt.Errorf("--emoji is required")
	}
	if !msg.ValidID(in.As) {
		return nil, fmt.Errorf("--as (the acting agent id) is required")
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	return hc.React(ctx, task, m, in.Emoji, in.As, !in.Remove)
}
