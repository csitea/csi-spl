package hub

import (
	"cmp"
	"context"
	"slices"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A workspace's own lanes (spec 153 section 3.17, SPL-4778; owner HUM-10,
// t1 dc2d6c40): the lanes of the boxes a workspace W runs itself, such as a
// box joined to W (spec 108), on W's GET /v1/view/lanes beside the
// operator's lanes on W's topics.
//
// W's own box = a box pinned in W that is not also pinned in the operator
// workspace: the fleet's boxes are pinned in many workspaces (their desks),
// and their lanes are the operator's (3.6 shows those on W's topics only,
// without the box). Two sources, both read in W's own scope:
//
//   - fleet_lanes rows of W (a `spool lane` put by W's box lands in the
//     tenant of its pin, box_lane.go), by 3.3's active rule;
//   - roster agents of W's online boxes that the box does not report as not
//     running (running true or unreported: an older spool client reports
//     nothing), with no fleet_lanes row of the same <agent>@<box>: the agent
//     the box's `spool hub-run` announces is live work even when nothing on
//     the box puts a lane. Such a row has no topic, scope or issue (the
//     roster carries none); its updated_at is the box's last presence stamp.
//
// A row is keyed by <agent>@<box>, never by the agent id alone: a W box's
// c-001 and the fleet's c-001 are two lanes.
//
// The operator view (3.3, GET /v1/operator/fleet-lanes; owner HUM-10 on
// F2: "it must be seen too .. as part of the cluster") lists every other
// workspace's own lanes and announced agents too, named by workspace,
// without that workspace's topic title or issues.

// ownLanes is W's own active lanes, with the burn their rule read, and the
// roster agents that have no lane row (rows ready but for the workspace).
type ownLanes struct {
	lanes  []store.FleetLane
	burn   map[[2]string]store.FleetTokenBucket
	roster []fleetLaneViewJSON
}

// ownWorkspaceLanes reads tenant's own lanes of fleet; none for the
// operator workspace (its rows are the fleet's, kept to its topics by 3.6).
func (s *Server) ownWorkspaceLanes(ctx context.Context, tenant, op, fleet string) (ownLanes, error) {
	if tenant == op {
		return ownLanes{}, nil
	}
	fleetBoxes, err := s.pinnedBoxes(ctx, op)
	if err != nil {
		return ownLanes{}, err
	}
	burn, err := s.fleetLaneBurn(ctx, s.o.Now())
	if err != nil {
		return ownLanes{}, err
	}
	return s.ownLanesOf(ctx, tenant, fleet, fleetBoxes, burn)
}

// ownLanesOf is tenant's own lanes and announced agents, the fleet's boxes
// (fleetBoxes) left out, on a token burn already read.
func (s *Server) ownLanesOf(ctx context.Context, tenant, fleet string, fleetBoxes map[string]bool,
	burn map[[2]string]store.FleetTokenBucket) (ownLanes, error) {
	active, err := s.activeLanesBurnt(ctx, tenant, fleet, burn)
	if err != nil {
		return ownLanes{}, err
	}
	out := ownLanes{burn: burn}
	have := map[string]bool{}
	for _, l := range active {
		if !fleetBoxes[l.AgentBox] && !fleetBoxes[l.WriterBox] {
			out.lanes = append(out.lanes, l)
			have[l.AgentID+"@"+l.AgentBox] = true
		}
	}
	boxes, err := s.o.Store.ViewBoxes(ctx, tenant)
	if err != nil {
		return ownLanes{}, err
	}
	out.roster = s.rosterLanes(tenant, boxes, fleetBoxes, have)
	return out, nil
}

// otherWorkspacesOwnLanes is, for the operator view (3.3, owner F2 = A), the
// own lanes and announced agents of every other non-archived workspace,
// each named by its workspace (names, else its display name, else its id).
// 3.3's rule for another workspace's topic holds: its id as text, no title,
// no issue and no origin issue (its keys number that workspace's issues),
// and no scope (that workspace's text; R7 W1). An announced agent shows once:
// a box pinned in two workspaces announces it in each, and a lane row of it
// in any workspace stands for it (R7 N1).
func (s *Server) otherWorkspacesOwnLanes(ctx context.Context, op, fleet string,
	burn map[[2]string]store.FleetTokenBucket, names map[string]string) ([]fleetLaneViewJSON, error) {
	out := []fleetLaneViewJSON{}
	ws, listed := s.o.Store.(store.OperatorWorkspaces)
	if !listed {
		return out, nil
	}
	all, err := ws.ListWorkspaces(ctx)
	if err != nil {
		return nil, err
	}
	fleetBoxes, err := s.pinnedBoxes(ctx, op)
	if err != nil {
		return nil, err
	}
	type named struct {
		w   store.Workspace
		own ownLanes
	}
	owns, shown := []named{}, map[string]bool{} // shown: <agent>@<box> of a lane row
	for _, w := range all {
		if w.ID == op || !w.ArchivedAt.IsZero() {
			continue
		}
		own, err := s.ownLanesOf(ctx, w.ID, fleet, fleetBoxes, burn)
		if err != nil {
			return nil, err
		}
		for _, l := range own.lanes {
			shown[l.AgentID+"@"+l.AgentBox] = true
		}
		owns = append(owns, named{w, own})
	}
	for _, n := range owns {
		rows := []fleetLaneViewJSON{}
		for _, l := range n.own.lanes { // newest write first, then the announced agents
			rows = append(rows, fleetLaneRow(l, burn))
		}
		for _, a := range n.own.roster {
			if k := a.AgentID + "@" + a.AgentBox; !shown[k] {
				shown[k] = true
				rows = append(rows, a)
			}
		}
		for _, v := range rows {
			v.Scope = ""
			v.Workspace, v.WorkspaceName = n.w.ID, cmp.Or(names[n.w.ID], n.w.DisplayName, n.w.ID)
			out = append(out, v)
		}
	}
	return out, nil
}

// rosterLanes is one row per roster agent of tenant's online own boxes that
// may run and has no lane row (have, by <agent>@<box>), box then agent order.
func (s *Server) rosterLanes(tenant string, boxes []store.ViewBox, fleetBoxes, have map[string]bool) []fleetLaneViewJSON {
	now := s.o.Now()
	out := []fleetLaneViewJSON{}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, b := range boxes {
		if fleetBoxes[b.BoxID] || !s.boxOnlineLocked(tenant, b, now) {
			continue
		}
		for _, a := range slices.Sorted(slices.Values(b.Agents)) {
			if run, told := b.Running[a]; (told && !run) || have[a+"@"+b.BoxID] || !laneIDRe.MatchString(a) {
				continue
			}
			out = append(out, fleetLaneViewJSON{AgentID: a, AgentBox: b.BoxID, Vendor: agentid.Kind(a), State: "live",
				Issues: []fleetLaneIssueJSON{}, UpdatedAt: b.LastHelloAt.UTC().Format(time.RFC3339),
				AgeS: int64(now.Sub(b.LastHelloAt).Seconds())})
		}
	}
	return out
}

// pinnedBoxes is the set of box ids pinned in tenant ("" tenant: none).
func (s *Server) pinnedBoxes(ctx context.Context, tenant string) (map[string]bool, error) {
	out := map[string]bool{}
	if tenant == "" {
		return out, nil
	}
	pins, err := s.o.Store.ListPins(ctx, tenant)
	for _, p := range pins {
		out[p.BoxID] = true
	}
	return out, err
}
