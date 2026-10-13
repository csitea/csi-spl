package action

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// IssueArgs is one agent issue request (specs/039 issues-v1 §6): the verb the
// CLI's `spool issue` and the MCP spool_issue tool share.
type IssueArgs struct {
	Op    string            `json:"op"`
	As    string            `json:"as"`
	Ref   string            `json:"ref,omitempty"`
	Issue json.RawMessage   `json:"issue,omitempty"`
	Query string            `json:"query,omitempty"`
	Body  string            `json:"body,omitempty"`
	Hub   *hubclient.Client `json:"-"` // nil = hubclient.New(cfg)
}

// Issue sends the request to the hub and returns its answer object. Hub mode
// only: issues live on the hub, never in the local folder spool.
func Issue(ctx context.Context, cfg *config.Config, in IssueArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("issues need hub mode ($SPOOL_HUB_URL is not set)")
	}
	switch in.Op {
	case "create", "update", "get", "list", "label", "comment", "delete", "archive", "unarchive", "link", "unlink":
	default:
		return nil, fmt.Errorf("op must be create, update, get, list, label, comment, delete, archive, unarchive, link or unlink")
	}
	if in.As == "" {
		return nil, fmt.Errorf("--as (the acting agent id) is required")
	}
	// archive and unarchive are the soft archive of rdb 0084. --cascade rides
	// in Query as cascade=1; the hub's agent issue op is what applies it.
	if (in.Op == "archive" || in.Op == "unarchive") && in.Ref == "" {
		return nil, fmt.Errorf("--ref is required")
	}
	// link and unlink (SPL-1593): one discussion of the issue, the topic id
	// or a /t/<id> link in Body; the hub keeps the last one.
	if (in.Op == "link" || in.Op == "unlink") && (in.Ref == "" || in.Body == "") {
		return nil, fmt.Errorf("--ref and --discussion are required")
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	return hc.Issue(ctx, hubclient.IssueRequest{Op: in.Op, As: in.As, Ref: in.Ref, Issue: in.Issue, Query: in.Query, Body: in.Body})
}
