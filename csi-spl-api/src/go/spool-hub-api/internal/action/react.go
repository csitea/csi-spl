package action

import (
	"context"
	"encoding/json"
	"errors"
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
	List   bool              `json:"list,omitempty"` // read only: no emoji, nothing written
	Hub    *hubclient.Client `json:"-"`              // nil = hubclient.New(cfg)
}

// React adds (or removes) the reaction - or, List, only reads the target's
// reactions - and returns the hub's answer.
// Hub mode only: reactions live on the hub. It refuses, before any hub call:
//   - no $SPOOL_HUB_URL (not in hub mode);
//   - a --msg that is not a UUID, or a --task that is not one while it is set
//     or --msg is empty;
//   - an empty --emoji (unless List) or an --as that is not a valid agent id.
func React(ctx context.Context, cfg *config.Config, in ReactArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, errors.New("reacting needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	task, m := strings.ToLower(in.TaskID), strings.ToLower(in.MsgID)
	if m != "" && !editMsgIDRe.MatchString(m) {
		return nil, errors.New("--msg must be a message UUID")
	}
	if (task != "" || m == "") && !editMsgIDRe.MatchString(task) {
		return nil, errors.New("--task must be the topic's task UUID (or give --msg)")
	}
	if !in.List && strings.TrimSpace(in.Emoji) == "" {
		return nil, errors.New("--emoji is required")
	}
	if !msg.ValidID(in.As) {
		return nil, errors.New("--as (the acting agent id) is required")
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	if in.List {
		return hc.Reactions(ctx, task, m, in.As)
	}
	return hc.React(ctx, task, m, in.Emoji, in.As, !in.Remove)
}
