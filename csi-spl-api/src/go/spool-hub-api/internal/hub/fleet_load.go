package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The fleet load target (rdb 0118; owner HUM-10, t1 c13e8023 msg 5fa43972:
// "this setting should be configurable from the spool-hub instance only in
// every cloud instance"): the band a box's load should stay in (% of cores,
// load5 / cpus) and the order the boxes take new agent lanes. It is the
// instance's setting, kept on the operator workspace's row (rdb 0116), so
// the routes are the operator workspace routes' rule: a member SESSION
// whose active workspace is the operator workspace AND whose role there is
// admin (operatorActor); everyone else gets 403 operator.workspaces.
//
//	GET   /v1/operator/fleet-load   the target in force, what is stored, the defaults
//	PATCH /v1/operator/fleet-load   {low?, high?, box_order?, boxes?}; null resets one to the default
//
// boxes (rdb 0134, owner HUM-10 t1 29b19f85: "target hw load per box") is
// {"<box>": {"low": n, "high": n}}: that box's own band, overriding low /
// high for it only. A PATCH replaces the whole map; null or {} resets it.
//
// Box side, over the authenticated hello on a one-shot role=cli session (the
// `spool lane` path), any box of any workspace of the instance, read only:
//
//	lane_op fleet_load_get   the target in force (what `spool fleet-load get` prints)
//
// The hub stores the target and enforces nothing; the box's spawn gate
// (csi-spl-orc do_spl_box_pick) reads it and places or holds a new lane.

func (s *Server) routeFleetLoad(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/fleet-load", s.handleFleetLoad)
	mux.HandleFunc("PATCH /v1/operator/fleet-load", s.handlePatchFleetLoad)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-load", s.operatorWorkspacesPreflight)
}

// fleetLoadBody is the answer of every door. Source is "hub" when the
// operator workspace's row was read, "default" when this hub names none.
type fleetLoadBody struct {
	store.FleetLoad
	Source   string                 `json:"source"`
	Stored   *store.FleetLoadStored `json:"stored,omitempty"`
	Defaults *store.FleetLoad       `json:"defaults,omitempty"`
}

func (s *Server) fleetLoadStore(w http.ResponseWriter) (store.FleetLoadTarget, bool) {
	fl, ok := s.o.Store.(store.FleetLoadTarget)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no fleet load target")
	}
	return fl, ok
}

func adminFleetLoadBody(f store.FleetLoadStored) fleetLoadBody {
	d := store.DefaultFleetLoad()
	if f.BoxOrder == nil {
		f.BoxOrder = []string{}
	}
	if f.Boxes == nil {
		f.Boxes = map[string]store.BoxBand{}
	}
	return fleetLoadBody{FleetLoad: f.Effective(), Source: "hub", Stored: &f, Defaults: &d}
}

// GET /v1/operator/fleet-load
func (s *Server) handleFleetLoad(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	fl, ok := s.fleetLoadStore(w)
	if !ok {
		return
	}
	f, err := fl.FleetLoadOf(r.Context(), a.tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "fleet load target unavailable")
		return
	}
	writeJSON(w, http.StatusOK, adminFleetLoadBody(f))
}

// fleetLoadPatchReq is PATCH /v1/operator/fleet-load: an absent field is
// left, a JSON null resets it to the default.
type fleetLoadPatchReq struct {
	Low      json.RawMessage `json:"low"`
	High     json.RawMessage `json:"high"`
	BoxOrder json.RawMessage `json:"box_order"`
	Boxes    json.RawMessage `json:"boxes"`
}

const badFleetLoad = "low is 1..99 and high 2..100 (% of cores) with low < high; box_order is distinct box ids ([a-z0-9-], up to 32 each), at most 32; boxes maps up to 32 box ids to {low, high} with the same ranges"

// patch turns the request into a store patch; ok=false: a field is not
// its JSON type.
func (q fleetLoadPatchReq) patch() (store.FleetLoadPatch, bool) {
	var p store.FleetLoadPatch
	isNull := func(m json.RawMessage) bool { return string(bytes.TrimSpace(m)) == "null" }
	if q.Low != nil {
		p.LowSet = true
		if !isNull(q.Low) && json.Unmarshal(q.Low, &p.Low) != nil {
			return p, false
		}
	}
	if q.High != nil {
		p.HighSet = true
		if !isNull(q.High) && json.Unmarshal(q.High, &p.High) != nil {
			return p, false
		}
	}
	if q.BoxOrder != nil {
		p.OrderSet = true
		if !isNull(q.BoxOrder) && json.Unmarshal(q.BoxOrder, &p.BoxOrder) != nil {
			return p, false
		}
	}
	if q.Boxes != nil {
		p.BoxesSet = true
		if !isNull(q.Boxes) && !decodeBoxBands(q.Boxes, &p.Boxes) {
			return p, false
		}
	}
	return p, true
}

// decodeBoxBands is a strict read of the boxes map: each band carries both
// marks as integers and nothing else, so a typo is a 400, not a 0.
func decodeBoxBands(raw json.RawMessage, out *map[string]store.BoxBand) bool {
	var m map[string]map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return false
	}
	*out = make(map[string]store.BoxBand, len(m))
	for box, f := range m {
		var b store.BoxBand
		if len(f) != 2 || json.Unmarshal(f["low"], &b.Low) != nil || json.Unmarshal(f["high"], &b.High) != nil {
			return false
		}
		(*out)[box] = b
	}
	return true
}

// boxBandsAudit is the boxes map as one sorted "box=low..high" string.
func boxBandsAudit(m map[string]store.BoxBand) string {
	parts := make([]string, 0, len(m))
	for box, b := range m {
		parts = append(parts, box+"="+strconv.Itoa(b.Low)+".."+strconv.Itoa(b.High))
	}
	slices.Sort(parts)
	return strings.Join(parts, ",")
}

// PATCH /v1/operator/fleet-load
func (s *Server) handlePatchFleetLoad(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	fl, ok := s.fleetLoadStore(w)
	if !ok {
		return
	}
	var q fleetLoadPatchReq
	if !decodeMembers(w, r, &q) {
		return
	}
	p, ok := q.patch()
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_setting", badFleetLoad)
		return
	}
	f, err := fl.SetFleetLoad(r.Context(), a.tenant, p)
	switch {
	case errors.Is(err, store.ErrBadFleetLoad):
		writeErr(w, http.StatusBadRequest, "bad_setting", badFleetLoad)
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "fleet load target not saved")
		return
	}
	e := f.Effective()
	s.opAudit(r, a, a.tenant, store.AuditUpdate, map[string]any{"setting": "fleet_load",
		"low": e.Low, "high": e.High, "box_order": strings.Join(e.BoxOrder, ","), "boxes": boxBandsAudit(e.Boxes)})
	writeJSON(w, http.StatusOK, adminFleetLoadBody(f))
}

// isFleetLoadLaneOp routes a lane frame to onFleetLoadLane.
func isFleetLoadLaneOp(op string) bool { return strings.HasPrefix(op, "fleet_load_") }

// onFleetLoadLane answers a fleet_load lane frame; the reply rides the lane
// field of a lane frame, as the lane map's does.
func (s *Server) onFleetLoadLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	if f.LaneOp != "fleet_load_get" {
		x.fail(ctx, id, "bad_frame", http.StatusBadRequest, "lane_op must be fleet_load_get")
		return
	}
	out, ae := s.fleetLoadInForce(ctx)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: f.LaneOp, Fleet: f.Fleet, Lane: raw}) //nolint:errcheck
}

// fleetLoadInForce is the instance's target: the operator workspace's row,
// or the defaults (source "default") when this hub names no operator
// workspace or its store keeps no target.
func (s *Server) fleetLoadInForce(ctx context.Context) (fleetLoadBody, *issueErr) {
	def := fleetLoadBody{FleetLoad: store.DefaultFleetLoad(), Source: "default"}
	fl, ok := s.o.Store.(store.FleetLoadTarget)
	if !ok {
		return def, nil
	}
	op, err := s.operatorTenant(ctx)
	if err != nil {
		return fleetLoadBody{}, &issueErr{http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read"}
	}
	if op == "" {
		return def, nil
	}
	f, err := fl.FleetLoadOf(ctx, op)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", op).Msg("fleet load target (box)")
		return fleetLoadBody{}, &issueErr{http.StatusInternalServerError, "internal", "fleet load target unavailable"}
	}
	return fleetLoadBody{FleetLoad: f.Effective(), Source: "hub"}, nil
}
