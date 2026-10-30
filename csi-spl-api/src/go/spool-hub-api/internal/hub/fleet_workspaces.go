package hub

import (
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Fleet seating, the box's doors (spec 158 section 4.2 items 3 and 4, build
// row T7). A fleet desk box (rdb 0230 fleet_desk_boxes, listed by the
// operator through PUT /v1/operator/fleet-desks/{box}) proves itself with
// the key it holds in the operator workspace; no session, no member, no
// root key:
//
//	GET  /v1/fleet/workspaces  {items: [{tenant, pinned}]}, signed in the
//	                           wire.FleetBoxHeader / FleetTSHeader / FleetSigHeader
//	                           headers over wire.FleetWorkspacesPayload
//	POST /v1/fleet/enrol       fleet_enrol.go
//
// The box checks, in this order, for both doors: 404 no operator workspace
// on this hub; 400 a malformed box id; 401 bad_sig (ts outside the hello
// skew, no live pin of the box in the operator workspace, or a signature that
// does not verify, one answer for all three); 403 fleet_box_not_listed. A
// revoked operator pin or an unlisted box stops every new call (4.2.5).

const (
	codeFleetBoxNotListed = "fleet_box_not_listed"
	codeFleetSeatingOff   = "fleet_seating_off"
	codeFleetPinRevoked   = "fleet_pin_revoked"
)

func (s *Server) routeFleet(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/fleet/workspaces", s.handleFleetWorkspaces)
	mux.HandleFunc("POST /v1/fleet/enrol", s.handleFleetEnrol)
}

// fleetStores is the stores both doors need; false = answered 501.
func (s *Server) fleetStores(w http.ResponseWriter) (store.FleetEnrol, store.FleetDeskBoxes, bool) {
	fe, ok := s.o.Store.(store.FleetEnrol)
	fd, ok2 := s.o.Store.(store.FleetDeskBoxes)
	if !ok || !ok2 {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no fleet seating")
		return nil, nil, false
	}
	return fe, fd, true
}

// fleetProof is what a box signed with its operator-workspace key.
type fleetProof struct {
	box, ts, sig string
	payload      []byte
}

// fleetBoxAdmit runs the box checks above; it answers the operator
// workspace and the box's listing time, false = answered.
func (s *Server) fleetBoxAdmit(w http.ResponseWriter, r *http.Request, fd store.FleetDeskBoxes, p fleetProof) (string, time.Time, bool) {
	op, err := s.operatorTenant(r.Context())
	switch {
	case err != nil:
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return "", time.Time{}, false
	case op == "":
		writeErr(w, http.StatusNotFound, "not_found", "this hub names no operator workspace")
		return "", time.Time{}, false
	case !store.FleetDeskBoxRx.MatchString(p.box):
		writeErr(w, http.StatusBadRequest, "bad_box", "box_id must match ^[a-z0-9][a-z0-9-]{0,31}$")
		return "", time.Time{}, false
	}
	pub, err := s.o.Store.GetPin(r.Context(), op, p.box)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace's pins were not read")
		return "", time.Time{}, false
	}
	if err != nil || p.payload == nil || !s.skewOK(p.ts) || verify(pub, p.payload, p.sig) != nil {
		writeErr(w, http.StatusUnauthorized, "bad_sig", "the operator-workspace box key signature does not verify")
		return "", time.Time{}, false
	}
	boxes, err := fd.ListFleetDeskBoxes(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the fleet desk boxes were not read")
		return "", time.Time{}, false
	}
	for _, b := range boxes {
		if b.BoxID == p.box {
			return op, b.AddedAt, true
		}
	}
	writeErr(w, http.StatusForbidden, codeFleetBoxNotListed, "box "+p.box+" is not a fleet desk box: the operator lists it first")
	return "", time.Time{}, false
}

// GET /v1/fleet/workspaces
func (s *Server) handleFleetWorkspaces(w http.ResponseWriter, r *http.Request) {
	fe, fd, ok := s.fleetStores(w)
	if !ok {
		return
	}
	p := fleetProof{box: r.Header.Get(wire.FleetBoxHeader), ts: r.Header.Get(wire.FleetTSHeader),
		sig: r.Header.Get(wire.FleetSigHeader)}
	p.payload, _ = wire.FleetWorkspacesPayload(p.box, p.ts)
	if _, _, ok := s.fleetBoxAdmit(w, r, fd, p); !ok {
		return
	}
	items, err := fe.ListFleetWorkspaces(r.Context(), p.box)
	if err != nil {
		s.o.Log.Error().Err(err).Str("box_id", p.box).Msg("fleet workspaces")
		writeErr(w, http.StatusInternalServerError, "internal", "fleet workspaces unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
