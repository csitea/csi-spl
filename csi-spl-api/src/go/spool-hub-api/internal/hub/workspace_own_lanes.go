package hub

import (
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
	_, active, burn, err := s.activeFleetLanes(ctx, tenant, fleet)
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
