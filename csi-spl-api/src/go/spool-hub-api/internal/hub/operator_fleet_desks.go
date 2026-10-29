package hub

import (
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The fleet desk boxes (spec 158 section 4.2 item 2, rdb 0230, build row T6):
// the desk boxes of the operator workspace that may self-enrol into every
// workspace marked for fleet seating (row T7). The doors are fleetLoadCaller's
// (the operator workspace's admin or the operator service account), the twin
// action is do_spl_fleet_desk_box:
//
//	GET    /v1/operator/fleet-desks        {items: [{box_id, added_by, added_at, live_pin}]}
//	PUT    /v1/operator/fleet-desks/{box}  201 listed, 200 already listed (the row kept);
//	                                       409 no_live_pin when box holds no live pin in
//	                                       the operator workspace (spec 158 4.2.2)
//	DELETE /v1/operator/fleet-desks/{box}  204; 404 when not listed
//
// A change writes one operator_audit row on the operator workspace (action
// update, detail {fleet_desk_box, op: add|remove}): rdb 0230 added no audit
// verb, and the list is a setting of the operator workspace. The live pin is
// checked on PUT only: removing a box always stands (spec 158 4.2.5), and an
// enrolment re-checks the pin itself (row T7).

func (s *Server) routeFleetDesks(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/fleet-desks", s.handleFleetDesksList)
	mux.HandleFunc("PUT /v1/operator/fleet-desks/{box}", s.handleFleetDeskPut)
	mux.HandleFunc("DELETE /v1/operator/fleet-desks/{box}", s.handleFleetDeskDelete)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-desks", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-desks/{box}", s.operatorWorkspacesPreflight)
}

// fleetDeskItem is one listed box and whether it still holds a live pin in
// the operator workspace.
type fleetDeskItem struct {
	store.FleetDeskBox
	LivePin bool `json:"live_pin"`
}

// fleetDeskCaller is fleetLoadCaller plus the stores; the actor is the admin
// or the service account's email; false = answered.
func (s *Server) fleetDeskCaller(w http.ResponseWriter, r *http.Request) (store.FleetDeskBoxes, opActor, bool) {
	op, _, who, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return nil, opActor{}, false
	}
	fd, ok := s.o.Store.(store.FleetDeskBoxes)
	ws, ok2 := s.o.Store.(store.OperatorWorkspaces)
	if !ok || !ok2 {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no fleet desk boxes")
		return nil, opActor{}, false
	}
	return fd, opActor{tenant: op, hum: who, ws: ws}, true
}

// livePin reports whether box holds a live pin in the operator workspace.
func (s *Server) livePin(r *http.Request, op, box string) (bool, error) {
	_, err := s.o.Store.GetPin(r.Context(), op, box)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	return err == nil, err
}

// GET /v1/operator/fleet-desks
func (s *Server) handleFleetDesksList(w http.ResponseWriter, r *http.Request) {
	fd, a, ok := s.fleetDeskCaller(w, r)
	if !ok {
		return
	}
	boxes, err := fd.ListFleetDeskBoxes(r.Context())
	items := make([]fleetDeskItem, 0, len(boxes))
	for _, b := range boxes {
		var live bool
		if err == nil {
			live, err = s.livePin(r, a.tenant, b.BoxID)
		}
		items = append(items, fleetDeskItem{FleetDeskBox: b, LivePin: live})
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet desks list")
		writeErr(w, http.StatusInternalServerError, "internal", "fleet desk boxes unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// fleetDeskBox is the path's box id; false = answered (400).
func fleetDeskBox(w http.ResponseWriter, r *http.Request) (string, bool) {
	box := r.PathValue("box")
	if !store.FleetDeskBoxRx.MatchString(box) {
		writeErr(w, http.StatusBadRequest, "bad_box", "box must match ^[a-z0-9][a-z0-9-]{0,31}$")
		return "", false
	}
	return box, true
}

// PUT /v1/operator/fleet-desks/{box}
func (s *Server) handleFleetDeskPut(w http.ResponseWriter, r *http.Request) {
	fd, a, ok := s.fleetDeskCaller(w, r)
	if !ok {
		return
	}
	box, ok := fleetDeskBox(w, r)
	if !ok {
		return
	}
	live, err := s.livePin(r, a.tenant, box)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Msg("fleet desk pin read")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace's pins were not read")
		return
	case !live:
		writeErr(w, http.StatusConflict, "no_live_pin", "box "+box+" holds no live pin in the operator workspace: pin it there first")
		return
	}
	by := a.hum
	if len(by) > store.FleetDeskAddedByMax {
		by = by[:store.FleetDeskAddedByMax]
	}
	b, created, err := fd.PutFleetDeskBox(r.Context(), box, by)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet desk put")
		writeErr(w, http.StatusInternalServerError, "internal", "fleet desk box not stored")
		return
	}
	code := http.StatusOK
	if created {
		code = http.StatusCreated
		s.opAudit(r, a, a.tenant, store.AuditUpdate, map[string]any{"fleet_desk_box": box, "op": "add"})
	}
	writeJSON(w, code, fleetDeskItem{FleetDeskBox: b, LivePin: true})
}

// DELETE /v1/operator/fleet-desks/{box}
func (s *Server) handleFleetDeskDelete(w http.ResponseWriter, r *http.Request) {
	fd, a, ok := s.fleetDeskCaller(w, r)
	if !ok {
		return
	}
	box, ok := fleetDeskBox(w, r)
	if !ok {
		return
	}
	err := fd.DeleteFleetDeskBox(r.Context(), box)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "box "+box+" is not a fleet desk box")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("fleet desk delete")
		writeErr(w, http.StatusInternalServerError, "internal", "fleet desk box not removed")
		return
	}
	s.opAudit(r, a, a.tenant, store.AuditUpdate, map[string]any{"fleet_desk_box": box, "op": "remove"})
	w.WriteHeader(http.StatusNoContent)
}
