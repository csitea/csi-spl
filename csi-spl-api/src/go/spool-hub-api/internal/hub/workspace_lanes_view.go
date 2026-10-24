package hub

import (
	"context"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A workspace's own lanes (spec 153 v1.1 section 3.6, build row B6, SPL-3229;
// owner HUM-10, prd t1 5e7b15c9, O1 = B): the operator workspace's active
// lanes that work on a topic of the caller's workspace W, for the Lanes tab of
// W's owners and admins.
//
//	GET /v1/view/lanes?fleet=<fleet, default main>
//
// Who may: a member session of W whose role set makes it W's owner or an
// admin (TenantOwner || Has(rbac.Admin)), else 403; the operator service
// account keeps GET /v1/operator/fleet-lanes (3.3) and gets none here.
//
// The rows: 3.3's active rule (activeFleetLanes), then only the lanes whose
// topic is a topic of W the caller may open (DiscussionStates + canReadTopic
// in W). A lane failing either is absent, never shown with a blank cell. The
// answer has 3.3's shape with agent_box "" (a fleet box name is the
// operator's) and issues = W's issues that issue_discussions links to the
// topic, with their status; the lane's own key is an operator workspace issue
// and is left out.

const permWorkspaceLanes = "workspace.lanes"

func (s *Server) routeLanesView(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/lanes", s.viewHandler(s.handleWorkspaceLanesView))
}

// GET /v1/view/lanes?fleet=
func (s *Server) handleWorkspaceLanesView(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	w.Header().Set("Cache-Control", "no-store")
	hum, _ := s.memberID(r, t.ID)
	if hum == "" {
		writeForbidden(w, permWorkspaceLanes, "the lanes view needs a member session")
		return
	}
	if a, err := s.access(r.Context(), hum, t.ID); err != nil || !(a.TenantOwner || a.Has(rbac.Admin)) {
		writeForbidden(w, permWorkspaceLanes, "only the workspace owner or an admin sees its lanes")
		return
	}
	fleet := r.URL.Query().Get("fleet")
	if fleet == "" {
		fleet = fleetLanesFleet
	}
	if !store.FleetNameRe.MatchString(fleet) {
		writeErr(w, http.StatusBadRequest, "bad_query", "fleet must be a lowercase slug ([a-z0-9-], up to 32)")
		return
	}
	out, err := s.workspaceLanesView(r.Context(), t.ID, fleet, hum)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Str("fleet", fleet).Msg("workspace lanes view")
		writeErr(w, http.StatusInternalServerError, "internal", "lane map unavailable")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// workspaceLanesView is the operator workspace's active lanes on topics of
// tenant that reader may open. No operator workspace: no lanes.
func (s *Server) workspaceLanesView(ctx context.Context, tenant, fleet, reader string) (fleetLanesViewJSON, error) {
	op, err := s.operatorTenant(ctx)
	if err != nil {
		return fleetLanesViewJSON{}, err
	}
	if op == "" {
		return fleetLanesViewJSON{AsOf: s.o.Now().UTC().Format(time.RFC3339), Fleet: fleet, Lanes: []fleetLaneViewJSON{}}, nil
	}
	out, active, burn, err := s.activeFleetLanes(ctx, op, fleet)
	if err != nil {
		return out, err
	}
	// The links are read in tenant: the own keys stay out (they number
	// operator issues, and the same number in tenant is another issue).
	onTopic := make([]store.FleetLane, 0, len(active))
	for _, l := range active {
		if l.Topic != "" {
			l.IssueKey = ""
			onTopic = append(onTopic, l)
		}
	}
	titles, byTopic, status, prefix, err := s.fleetLaneLinks(ctx, tenant, reader, onTopic)
	if err != nil {
		return out, err
	}
	for _, l := range onTopic { // ListFleetLanes order: newest write first
		title, mine := titles[l.Topic]
		if !mine {
			continue
		}
		v := fleetLaneRow(l, burn)
		v.AgentBox, v.TopicTitle = "", title
		v.Issues = laneIssues("", prefix, true, byTopic[l.Topic], status)
		out.Lanes = append(out.Lanes, v)
	}
	return out, nil
}
