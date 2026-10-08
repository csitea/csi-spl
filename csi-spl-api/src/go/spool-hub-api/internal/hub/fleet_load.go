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
	"time"

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
// admin (operatorActor); everyone else gets 403 operator.workspaces. The
// same two doors also take the instance's operator service account (a Bearer
// id token, operatorAuth, as POST /v1/operator/invites), so a named action
// (csi-spl-orc do_spl_hub_agent_kinds) sets it with no member session.
//
//	GET   /v1/operator/fleet-load   the target in force, what is stored, the defaults
//	PATCH /v1/operator/fleet-load   {low?, high?, box_order?, boxes?, agent_kinds_off?, agent_kinds_paused?,
//	                                 runner_cpu_pct?, ordered_by?, ordered_via?}; null resets one to the default
//
// boxes (rdb 0134, owner HUM-10 t1 29b19f85: "target hw load per box") is
// {"<box>": {"low": n, "high": n}}: that box's own band, overriding low /
// high for it only. A PATCH replaces the whole map; null or {} resets it.
//
// agent_kinds_off (rdb 0149, owner HUM-10 t1 41fa1f2d: "a setting to disable
// certain type of ai agents") is the kinds no box starts a new lane of
// (claude, grok, agy, qwen, mistral); a PATCH replaces the set, never with every kind.
// agent_kinds_paused is {"<kind>": {until, reason, box}}: a timed pause a box
// reported (lane_op fleet_load_pause) when a lane of that kind hit its usage
// limit; a PATCH {"agent_kinds_paused": {"<kind>": null}} lifts one. Every
// answer carries only the pauses still running.
//
// runner_cpu_pct (rdb 0152, owner HUM-10 t1 338e5258 b3573121: "there will
// be always some 20% extra capacity") is the % of a box's cores CI runners
// plus agents may use, 1..100, default 80; a box's band may carry its own
// (boxes.<box>.runner_cpu_pct), read by csi-spl-orc
// do_apply_gh_runner_cpu_budget as .boxes[<box>].runner_cpu_pct // .runner_cpu_pct.
//
// Box side, over the authenticated hello on a one-shot role=cli session (the
// `spool lane` path), any box of any workspace of the instance, read only:
//
//	lane_op fleet_load_get     the target in force (what `spool fleet-load get` prints)
//	lane_op fleet_load_pause   {kind, until, reason}: pause that kind for every box until
//	                           then (at most store.MaxKindPause ahead); answers the target
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

// live is b with only the pauses still running at now, in force and stored.
func (b fleetLoadBody) live(now time.Time) fleetLoadBody {
	b.FleetLoad = b.FleetLoad.LivePauses(now)
	if b.Stored != nil {
		st := *b.Stored
		st.Paused = b.FleetLoad.Paused
		b.Stored = &st
	}
	return b
}

// fleetLoadCaller is who may use the doors: the operator service account
// (a Bearer id token: operatorAuth) or the operator workspace's admin (a
// member session: operatorActor). It answers the operator workspace, the
// admin (nil for the service account) and who called; it writes the refusal.
func (s *Server) fleetLoadCaller(w http.ResponseWriter, r *http.Request) (string, *opActor, string, bool) {
	if !strings.HasPrefix(strings.TrimSpace(r.Header.Get("Authorization")), "Bearer ") {
		a, ok := s.operatorActor(w, r)
		return a.tenant, &a, a.hum, ok
	}
	email, ok := s.operatorAuth(w, r)
	if !ok {
		return "", nil, "", false
	}
	op, err := s.operatorTenant(r.Context())
	switch {
	case err != nil:
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return "", nil, "", false
	case op == "":
		writeErr(w, http.StatusNotFound, "not_found", "this hub names no operator workspace")
		return "", nil, "", false
	}
	return op, nil, email, true
}

// GET /v1/operator/fleet-load
func (s *Server) handleFleetLoad(w http.ResponseWriter, r *http.Request) {
	tenant, _, _, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return
	}
	fl, ok := s.fleetLoadStore(w)
	if !ok {
		return
	}
	f, err := fl.FleetLoadOf(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "fleet load target unavailable")
		return
	}
	writeJSON(w, http.StatusOK, adminFleetLoadBody(f).live(s.o.Now()))
}

// fleetLoadPatchReq is PATCH /v1/operator/fleet-load: an absent field is
// left, a JSON null resets it to the default.
type fleetLoadPatchReq struct {
	Low      json.RawMessage `json:"low"`
	High     json.RawMessage `json:"high"`
	BoxOrder json.RawMessage `json:"box_order"`
	Boxes    json.RawMessage `json:"boxes"`
	KindsOff json.RawMessage `json:"agent_kinds_off"`
	Paused   json.RawMessage `json:"agent_kinds_paused"`
	CPUPct   json.RawMessage `json:"runner_cpu_pct"`
	// OrderedBy / OrderedVia: who ordered a change and who carried it, for
	// the record (a HUM-* id; an agent or channel, at most 64 characters).
	OrderedBy  string `json:"ordered_by"`
	OrderedVia string `json:"ordered_via"`
}

const badFleetLoad = "low is 1..99 and high 2..100 (% of cores) with low < high; box_order is distinct box ids ([a-z0-9-], up to 32 each), at most 32; boxes maps up to 32 box ids to {low, high} with the same ranges; agent_kinds_off is distinct kinds of claude, grok, agy, qwen, mistral, never all five; agent_kinds_paused maps a kind to null (lift its pause); runner_cpu_pct is 1..100 (% of cores), fleet-wide or per box in boxes"

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
	if q.KindsOff != nil {
		p.KindsOffSet = true
		if !isNull(q.KindsOff) && json.Unmarshal(q.KindsOff, &p.AgentKindsOff) != nil {
			return p, false
		}
	}
	if q.CPUPct != nil {
		p.RunnerCPUSet = true
		if !isNull(q.CPUPct) && json.Unmarshal(q.CPUPct, &p.RunnerCPUPct) != nil {
			return p, false
		}
	}
	if q.Paused != nil && !isNull(q.Paused) {
		// The admin only lifts a pause here; a box sets one (fleet_load_pause).
		var m map[string]json.RawMessage
		if json.Unmarshal(q.Paused, &m) != nil {
			return p, false
		}
		p.Pauses = map[string]*store.KindPause{}
		for k, v := range m {
			if !isNull(v) || !slices.Contains(store.AgentKinds, k) {
				return p, false
			}
			p.Pauses[k] = nil
		}
	}
	return p, true
}

// decodeBoxBands is a strict read of the boxes map: each band carries both
// marks as integers, an optional runner_cpu_pct 1..100 (rdb 0152) and
// nothing else, so a typo is a 400, not a 0.
func decodeBoxBands(raw json.RawMessage, out *map[string]store.BoxBand) bool {
	var m map[string]map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return false
	}
	*out = make(map[string]store.BoxBand, len(m))
	for box, f := range m {
		var b store.BoxBand
		n := 2
		if cpu, ok := f["runner_cpu_pct"]; ok {
			n = 3
			if json.Unmarshal(cpu, &b.RunnerCPUPct) != nil || b.RunnerCPUPct < 1 {
				return false
			}
		}
		if len(f) != n || json.Unmarshal(f["low"], &b.Low) != nil || json.Unmarshal(f["high"], &b.High) != nil {
			return false
		}
		(*out)[box] = b
	}
	return true
}

// boxBandsAudit is the boxes map as one sorted "box=low..high[/cpu]" string.
func boxBandsAudit(m map[string]store.BoxBand) string {
	parts := make([]string, 0, len(m))
	for box, b := range m {
		part := box + "=" + strconv.Itoa(b.Low) + ".." + strconv.Itoa(b.High)
		if b.RunnerCPUPct != 0 {
			part += "/" + strconv.Itoa(b.RunnerCPUPct)
		}
		parts = append(parts, part)
	}
	slices.Sort(parts)
	return strings.Join(parts, ",")
}

// PATCH /v1/operator/fleet-load
func (s *Server) handlePatchFleetLoad(w http.ResponseWriter, r *http.Request) {
	tenant, a, by, ok := s.fleetLoadCaller(w, r)
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
	if (q.OrderedBy != "" && !humanIDRe.MatchString(q.OrderedBy)) || len(q.OrderedVia) > 64 {
		writeErr(w, http.StatusBadRequest, "bad_setting", "ordered_by is a HUM-* id; ordered_via at most 64 characters")
		return
	}
	p.Now = s.o.Now()
	f, err := fl.SetFleetLoad(r.Context(), tenant, p)
	switch {
	case errors.Is(err, store.ErrBadFleetLoad):
		writeErr(w, http.StatusBadRequest, "bad_setting", badFleetLoad)
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "fleet load target not saved")
		return
	}
	out := adminFleetLoadBody(f).live(p.Now)
	e := out.FleetLoad
	detail := map[string]any{"setting": "fleet_load",
		"low": e.Low, "high": e.High, "box_order": strings.Join(e.BoxOrder, ","), "boxes": boxBandsAudit(e.Boxes),
		"agent_kinds_off": strings.Join(e.AgentKindsOff, ","), "agent_kinds_paused": pausesAudit(e.Paused), "runner_cpu_pct": e.RunnerCPUPct,
		"ordered_by": q.OrderedBy, "ordered_via": q.OrderedVia}
	if a != nil {
		s.opAudit(r, *a, tenant, store.AuditUpdate, detail)
	} else {
		s.o.Log.Info().Str("tenant", tenant).Str("operator", by).Interface("detail", detail).Msg("operator.fleet_load")
	}
	writeJSON(w, http.StatusOK, out)
}

// pausesAudit is the live pauses as one sorted "kind<until" string.
func pausesAudit(m map[string]store.KindPause) string {
	parts := make([]string, 0, len(m))
	for k, p := range m {
		parts = append(parts, k+"<"+p.Until.UTC().Format(time.RFC3339))
	}
	slices.Sort(parts)
	return strings.Join(parts, ",")
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
	var out fleetLoadBody
	var ae *issueErr
	switch f.LaneOp {
	case "fleet_load_get":
		out, ae = s.fleetLoadInForce(ctx)
	case "fleet_load_pause":
		out, ae = s.fleetLoadPause(ctx, x, f.Lane)
	default:
		x.fail(ctx, id, "bad_frame", http.StatusBadRequest, "lane_op must be fleet_load_get or fleet_load_pause")
		return
	}
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
	return fleetLoadBody{FleetLoad: f.Effective().LivePauses(s.o.Now()), Source: "hub"}, nil
}

// fleetLoadPause is lane_op fleet_load_pause: the box x reports that a lane
// of {kind} hit its usage limit; every box skips that kind until {until}
// (RFC 3339, in the future, at most store.MaxKindPause ahead). It writes the
// operator workspace's row, whatever the box's own workspace, and answers
// the target in force after it. A hub with no operator workspace keeps no
// pause: 409.
func (s *Server) fleetLoadPause(ctx context.Context, x *session, raw json.RawMessage) (fleetLoadBody, *issueErr) {
	var q struct {
		Kind   string    `json:"kind"`
		Until  time.Time `json:"until"`
		Reason string    `json:"reason"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	now := s.o.Now()
	if dec.Decode(&q) != nil || !slices.Contains(store.AgentKinds, q.Kind) || !q.Until.After(now) ||
		q.Until.After(now.Add(store.MaxKindPause)) {
		return fleetLoadBody{}, &issueErr{http.StatusBadRequest, "bad_frame",
			"lane must be {kind: claude|grok|agy|qwen|mistral, until: RFC 3339 within 8 days, reason}"}
	}
	fl, ok := s.o.Store.(store.FleetLoadTarget)
	if !ok {
		return fleetLoadBody{}, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no fleet load target"}
	}
	op, err := s.operatorTenant(ctx)
	if err != nil {
		return fleetLoadBody{}, &issueErr{http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read"}
	}
	if op == "" {
		return fleetLoadBody{}, &issueErr{http.StatusConflict, "conflict", "this hub names no operator workspace: no instance setting to pause in"}
	}
	pause := &store.KindPause{Until: q.Until.UTC(), Reason: q.Reason, Box: x.box}
	f, err := fl.SetFleetLoad(ctx, op, store.FleetLoadPatch{Now: now, Pauses: map[string]*store.KindPause{q.Kind: pause}})
	switch {
	case errors.Is(err, store.ErrBadFleetLoad):
		return fleetLoadBody{}, &issueErr{http.StatusBadRequest, "bad_frame", "the reason is at most 200 characters"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", op).Str("box", x.box).Msg("fleet load pause (box)")
		return fleetLoadBody{}, &issueErr{http.StatusInternalServerError, "internal", "the pause was not stored"}
	}
	s.o.Log.Info().Str("kind", q.Kind).Str("box", x.box).Time("until", pause.Until).Msg("agent kind paused for the instance")
	return fleetLoadBody{FleetLoad: f.Effective().LivePauses(now), Source: "hub"}, nil
}
