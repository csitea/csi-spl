package action

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// LaneArgs is one write, or the list, of the fleet-wide lane map
// (CLE-77920): the verb behind `spool lane`. Agent "" = list; with Agent the
// rest is the row of <Agent>@<Box> to write (State defaults to live).
type LaneArgs struct {
	Fleet  string            `json:"fleet"`
	Agent  string            `json:"agent_id,omitempty"`
	Box    string            `json:"agent_box,omitempty"`
	Repo   string            `json:"repo,omitempty"`
	Branch string            `json:"branch,omitempty"`
	Scope  string            `json:"scope,omitempty"`
	Files  []string          `json:"files,omitempty"`
	Topic  string            `json:"topic,omitempty"`
	State  string            `json:"state,omitempty"`
	Hub    *hubclient.Client `json:"-"` // nil = hubclient.New(cfg)
}

// Lane writes one row or lists the map and returns the hub's answer
// {fleet, lanes}. Hub mode only: the map lives on the hub, shared by every
// machine.
func Lane(ctx context.Context, cfg *config.Config, in LaneArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("the lane map needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	if !store.FleetNameRe.MatchString(in.Fleet) {
		return nil, fmt.Errorf("--fleet must be a lowercase slug ([a-z0-9-], up to 32)")
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	if in.Agent == "" {
		return hc.Lane(ctx, "list", in.Fleet, nil)
	}
	if in.State == "" {
		in.State = "live"
	}
	if in.Files == nil {
		in.Files = []string{}
	}
	l := store.FleetLane{Fleet: in.Fleet, AgentID: in.Agent, AgentBox: in.Box, Repo: in.Repo, Branch: in.Branch,
		Scope: in.Scope, Files: in.Files, Topic: in.Topic, State: in.State}
	if why := store.CheckFleetLane(l); why != "" {
		return nil, fmt.Errorf("lane: %s", why)
	}
	row, err := json.Marshal(map[string]any{"agent_id": l.AgentID, "agent_box": l.AgentBox, "repo": l.Repo,
		"branch": l.Branch, "scope": l.Scope, "files": l.Files, "topic": l.Topic, "state": l.State})
	if err != nil {
		return nil, err
	}
	return hc.Lane(ctx, "put", in.Fleet, row)
}
