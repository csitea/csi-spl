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

// ArchiveArgs is one topic archive or unarchive by a box agent (CLE-77869):
// the verb behind `spool archive`.
type ArchiveArgs struct {
	TaskID    string            `json:"task_id"`
	As        string            `json:"as"`
	Unarchive bool              `json:"unarchive,omitempty"`
	Hub       *hubclient.Client `json:"-"` // nil = hubclient.New(cfg)
}

// Archive archives (or unarchives) the topic and returns the hub's answer.
// Hub mode only: the archive flag lives on the hub.
func Archive(ctx context.Context, cfg *config.Config, in ArchiveArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("archiving a topic needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	task := strings.ToLower(in.TaskID)
	if !editMsgIDRe.MatchString(task) {
		return nil, fmt.Errorf("--task must be the topic's task UUID")
	}
	if !msg.ValidID(in.As) {
		return nil, fmt.Errorf("--as (the acting agent id) is required")
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	return hc.ArchiveTopic(ctx, task, in.As, !in.Unarchive)
}
