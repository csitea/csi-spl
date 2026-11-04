package hub

import (
	"cmp"
	"context"
	"net/http"
	"slices"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator's cross-workspace roster (spec 153 section 3.17, SPL-4786;
// owner HUM-10, a customer workspace topic d60646d9, msgs 34c50576 "but why the newly
// registered agent cannot be seen", 0443824f "it must be seen too .. as part
// of the cluster"): the boxes and agents the other workspaces have on their
// own, each row named by its workspace, for Monitoring -> Agents and Boxes of
// the operator workspace.
//
//	GET /v1/operator/fleet-roster  {boxes: [{workspace, workspace_name, box_id,
//	                               revoked, last_hello_at, online, agents,
//	                               agent_presence}],
//	                               also_seated: {<box_id>: [{workspace, workspace_name}]}}
//
// Who may: the fleet load doors (fleetLoadCaller), as fleet-lanes: the
// operator workspace's admin or the operator service account. Each
// non-archived workspace is read in its own tenant scope (ViewBoxes); a box
// locked to someone in its workspace is left out, as for a token-door read.
//
// One row per box (dispatch c-002, msg a3d9b5c9): a box the operator
// workspace already has (pinned there, or listed as a fleet desk box, spec
// 158: its fleet-mode pins are seated from that list) is no row of another
// workspace; also_seated names the other workspaces it is seated in. Only a
// box pinned in a customer workspace and not in the operator one is a row,
// under that workspace.
//
// A row carries no key, no host facts and no topic, issue or message of the
// workspace: what the operator may see of a customer's box is that it is
// there and live.

type fleetRosterBox struct {
	Workspace     string                   `json:"workspace"`
	WorkspaceName string                   `json:"workspace_name"`
	BoxID         string                   `json:"box_id"`
	Revoked       bool                     `json:"revoked"`
	LastHelloAt   *string                  `json:"last_hello_at"`
	Online        bool                     `json:"online"`
	Agents        []string                 `json:"agents"`
	AgentPresence map[string]agentPresence `json:"agent_presence,omitempty"`
}

type fleetRosterSeat struct {
	Workspace     string `json:"workspace"`
	WorkspaceName string `json:"workspace_name"`
}

type fleetRosterBody struct {
	Boxes      []fleetRosterBox             `json:"boxes"`
	AlsoSeated map[string][]fleetRosterSeat `json:"also_seated"`
}

func (s *Server) routeFleetRoster(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/fleet-roster", s.handleFleetRoster)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-roster", s.operatorWorkspacesPreflight)
}

// GET /v1/operator/fleet-roster
func (s *Server) handleFleetRoster(w http.ResponseWriter, r *http.Request) {
	op, _, _, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return
	}
	ws, ok := s.o.Store.(store.OperatorWorkspaces)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store lists no workspaces")
		return
	}
	out, err := s.fleetRoster(r.Context(), op, ws)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet roster")
		writeErr(w, http.StatusInternalServerError, "internal", "fleet roster unavailable")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// fleetRoster reads every other non-archived workspace's boxes, by workspace
// id, then box id; a box the operator workspace has goes to also_seated.
func (s *Server) fleetRoster(ctx context.Context, op string, ws store.OperatorWorkspaces) (fleetRosterBody, error) {
	out := fleetRosterBody{Boxes: []fleetRosterBox{}, AlsoSeated: map[string][]fleetRosterSeat{}}
	own, err := s.operatorBoxIDs(ctx, op)
	if err != nil {
		return out, err
	}
	all, err := ws.ListWorkspaces(ctx)
	if err != nil {
		return out, err
	}
	slices.SortFunc(all, func(a, b store.Workspace) int { return cmp.Compare(a.ID, b.ID) })
	for _, w := range all {
		if w.ID == op || !w.ArchivedAt.IsZero() {
			continue
		}
		rows, err := s.workspaceRoster(ctx, w)
		if err != nil {
			return out, err
		}
		for _, b := range rows {
			if own[b.BoxID] {
				out.AlsoSeated[b.BoxID] = append(out.AlsoSeated[b.BoxID], fleetRosterSeat{b.Workspace, b.WorkspaceName})
				continue
			}
			out.Boxes = append(out.Boxes, b)
		}
	}
	return out, nil
}

// operatorBoxIDs is the boxes the operator workspace has: its pins and its
// fleet desk boxes.
func (s *Server) operatorBoxIDs(ctx context.Context, op string) (map[string]bool, error) {
	own := map[string]bool{}
	boxes, err := s.o.Store.ViewBoxes(ctx, op)
	if err != nil {
		return nil, err
	}
	for _, b := range boxes {
		own[b.BoxID] = true
	}
	if fd, ok := s.o.Store.(store.FleetDeskBoxes); ok {
		desks, err := fd.ListFleetDeskBoxes(ctx)
		if err != nil {
			return nil, err
		}
		for _, d := range desks {
			own[d.BoxID] = true
		}
	}
	return own, nil
}

// workspaceRoster is one workspace's rows: its boxes in its own scope, the
// locked ones left out, each with its presence.
func (s *Server) workspaceRoster(ctx context.Context, w store.Workspace) ([]fleetRosterBox, error) {
	boxes, err := s.o.Store.ViewBoxes(ctx, w.ID)
	if err != nil {
		return nil, err
	}
	lv, err := s.lockViewFor(ctx, w.ID, "")
	if err != nil {
		return nil, err
	}
	boxes = slices.DeleteFunc(boxes, func(b store.ViewBox) bool { return lv.hides(b.BoxID) })
	slices.SortFunc(boxes, func(a, b store.ViewBox) int { return cmp.Compare(a.BoxID, b.BoxID) })
	now := s.o.Now()
	online := make([]bool, len(boxes))
	s.mu.Lock()
	for i, b := range boxes {
		online[i] = s.boxOnlineLocked(w.ID, b, now)
	}
	s.mu.Unlock()
	out := make([]fleetRosterBox, 0, len(boxes))
	for i, b := range boxes {
		v := fleetRosterBox{Workspace: w.ID, WorkspaceName: cmp.Or(w.DisplayName, w.ID), BoxID: b.BoxID,
			Revoked: b.Revoked, Online: online[i], Agents: b.Agents}
		if v.Agents == nil {
			v.Agents = []string{}
		}
		if !b.LastHelloAt.IsZero() {
			at := rfc(b.LastHelloAt)
			v.LastHelloAt = &at
		}
		if len(v.Agents) > 0 {
			v.AgentPresence = make(map[string]agentPresence, len(v.Agents))
			for _, id := range v.Agents {
				v.AgentPresence[id] = agentPresence{State: agentState(v.Online, b.Running, id), LastSeen: v.LastHelloAt}
			}
		}
		out = append(out, v)
	}
	return out, nil
}
