package hub

import (
	"context"
	"slices"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Every workspace sees its own token costs (spec 140 section 3.10, SPL-3565;
// owner HUM-10, t1 f3ed0eed, msgs 1bb1f74b "each of the workspaces should be
// able to distinguish between the token costs of it's own workspace" and
// 96d69790 "but the admin of the spoool-hub should be able to see the costs
// of the other workspaces as well").
//
// The write: before a box's push is stored, each sample's lane is looked up
// in the operator workspace's lane map (fleet_lanes, fleet main, the row of
// that agent at the pushing box) and its topic (spec 153 3.4 / 3.7, the one
// lane-to-workspace mapping) is found in the workspace that holds it: that
// workspace is the sample's WorkTenant (rdb 0229). An operator topic, no
// topic, no row or a topic no workspace holds leaves it "" (the operator's
// own work). A failed lookup never fails the push: the minute is stored as
// the operator's and the error logged.
//
// The read: the cost route (cost_read.go) adds the month's burn of the
// caller's workspace as parts, and the operator admin's estate answer lists
// every workspace's (costWorkspaces).

// topicWorkspaceTTL is how long a lookup that found no workspace is kept: a
// topic never moves workspace, so a found one is kept for the process.
const topicWorkspaceTTL = 10 * time.Minute

type topicWorkspaceHit struct {
	ws string
	at time.Time // zero: found, kept
}

// topicWorkspaces is each Server's topic -> workspace cache, beside the
// Server like fleetSurges.
var topicWorkspaces = struct {
	mu sync.Mutex
	by map[*Server]map[string]topicWorkspaceHit
}{by: map[*Server]map[string]topicWorkspaceHit{}}

// stampWorkTenants sets each sample's WorkTenant from the lane map.
func (s *Server) stampWorkTenants(ctx context.Context, op, box string, samples []wire.FleetTokenSample) {
	fl, ok := s.o.Store.(store.FleetLanes)
	if !ok {
		return
	}
	lanes, err := fl.ListFleetLanes(ctx, op, fleetLanesFleet, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("box", box).Msg("fleet tokens work tenant: lane map")
		return
	}
	topic := map[string]string{}
	for _, l := range lanes {
		if l.AgentBox == box && uuidRe.MatchString(l.Topic) {
			topic[l.AgentID] = l.Topic
		}
	}
	for i := range samples {
		if t := topic[samples[i].AgentID]; t != "" {
			if ws := s.topicWorkspace(ctx, op, t); store.ValidWorkTenant(ws) {
				samples[i].WorkTenant = ws
			}
		}
	}
}

// topicWorkspace is the workspace other than op that holds topic, "" for op
// or none. Each workspace is read in its own scope (TopicsByPrefix).
func (s *Server) topicWorkspace(ctx context.Context, op, topic string) string {
	now := s.o.Now()
	topicWorkspaces.mu.Lock()
	hit, cached := topicWorkspaces.by[s][topic]
	topicWorkspaces.mu.Unlock()
	if cached && (hit.at.IsZero() || now.Sub(hit.at) < topicWorkspaceTTL) {
		return hit.ws
	}
	ws, found, err := s.findTopicWorkspace(ctx, op, topic)
	if err != nil {
		s.o.Log.Error().Err(err).Str("topic", topic).Msg("fleet tokens work tenant: topic")
		return ""
	}
	hit = topicWorkspaceHit{ws: ws}
	if !found {
		hit.at = now
	}
	topicWorkspaces.mu.Lock()
	if topicWorkspaces.by[s] == nil {
		topicWorkspaces.by[s] = map[string]topicWorkspaceHit{}
	}
	topicWorkspaces.by[s][topic] = hit
	topicWorkspaces.mu.Unlock()
	return ws
}

// findTopicWorkspace looks topic up in every workspace other than op
// (archived ones aside), then in op. found is false when none holds it.
func (s *Server) findTopicWorkspace(ctx context.Context, op, topic string) (ws string, found bool, err error) {
	d, ok := s.o.Store.(store.IssueDiscussions)
	wl, listed := s.o.Store.(store.OperatorWorkspaces)
	if !ok || !listed {
		return "", false, nil
	}
	holds := func(tenant string) (bool, error) {
		ids, err := d.TopicsByPrefix(ctx, tenant, topic[:8], 100)
		return slices.Contains(ids, topic), err
	}
	// The other workspaces first: a lane's relays to the operator land on its
	// topic there too (prd 2026-10-26: all 6 lane topics of two workspaces
	// had 1..72 t1 copies), so the operator holding it proves nothing.
	all, err := wl.ListWorkspaces(ctx)
	if err != nil {
		return "", false, err
	}
	for _, w := range all {
		if w.ID == op || !w.ArchivedAt.IsZero() {
			continue
		}
		if in, err := holds(w.ID); err != nil || in {
			return w.ID, in, err
		}
	}
	in, err := holds(op)
	return "", in, err
}

// costWorkspaceOut is one (workspace, vendor) of the estate answer's
// workspaces list: what the operator admin sees of every workspace.
type costWorkspaceOut struct {
	Workspace       string `json:"workspace"`
	Vendor          string `json:"vendor"`
	Tokens          int64  `json:"tokens"`
	ListValueMicros int64  `json:"list_value_micros"`
	Days            int    `json:"days"`
}

// workspaceTokenParts reads the month's burn: of workspace ("" = every
// one). No store half: none, no error.
func (s *Server) workspaceTokenParts(ctx context.Context, op, workspace string, win costMonthWindow) ([]store.WorkspaceTokenPart, error) {
	wt, ok := s.o.Store.(store.WorkspaceTokens)
	if !ok || op == "" {
		return nil, nil
	}
	return wt.WorkspaceTokenMonth(ctx, store.WorkspaceTokenQuery{Operator: op, Workspace: workspace,
		From: win.From, To: win.To, Now: s.o.Now()})
}

// tokenCostParts are a workspace's burn as cost parts: source fleet_tokens,
// one per vendor, the tokens as units and the list price beside a paid 0
// (spec 123 Q-4: a subscription's token volume is never a paid amount).
func tokenCostParts(ps []store.WorkspaceTokenPart) []store.CostPart {
	out := make([]store.CostPart, 0, len(ps))
	for _, p := range ps {
		list, zero := p.ListUSDMicros, int64(0)
		out = append(out, store.CostPart{Source: "fleet_tokens", ProjectOrVendor: p.Vendor, Kind: "tokens",
			Origin: "transcript", Units: float64(p.Tokens), ListValueMicros: &list, Days: p.Days, SecondMicros: &zero})
	}
	return out
}

// costWorkspaces is every workspace's burn for the estate answer.
func costWorkspaces(ps []store.WorkspaceTokenPart) []costWorkspaceOut {
	out := make([]costWorkspaceOut, 0, len(ps))
	for _, p := range ps {
		out = append(out, costWorkspaceOut{Workspace: p.Workspace, Vendor: p.Vendor, Tokens: p.Tokens,
			ListValueMicros: p.ListUSDMicros, Days: p.Days})
	}
	return out
}
