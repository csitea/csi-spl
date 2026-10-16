package hub

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The takeover ladder (SPL-2115): per task kind, the vendor order that takes
// over a failed task on the same branch and the failures each vendor is
// allowed. Workspace settings -> Agent takeover reads and edits it; the
// takeover engine (M1b) reads the same body. Stored as registered keys of
// tenants.settings (store/takeover_ladder.go), so it needs no migration.
//
//	GET /v1/takeover-ladder -> {tenant_id, vendors, max_failures_max,
//	    kinds: [{kind, order: ["mistral","agy","claude"], max_failures, set}]}
//	PUT /v1/takeover-ladder {kinds: {"<kind>": {order, max_failures} | null}}
//
// GET: any member (topics.read). PUT: tenant.settings. A kind in the PUT
// replaces that kind whole; null resets it to the default; a kind left out is
// unchanged. A bad kind, vendor, repeat, max_failures out of range or agy /
// qwen in secret is 400 bad_ladder naming the rule, and nothing is written.

type takeoverRungJSON struct {
	Kind        string   `json:"kind"`
	Order       []string `json:"order"`
	MaxFailures int      `json:"max_failures"`
	Set         bool     `json:"set"`
}

type takeoverLadderBody struct {
	TenantID       string             `json:"tenant_id"`
	Vendors        []string           `json:"vendors"`
	MaxFailuresMax int                `json:"max_failures_max"`
	Kinds          []takeoverRungJSON `json:"kinds"`
}

type takeoverRungPatchJSON struct {
	Order       []string `json:"order"`
	MaxFailures *int     `json:"max_failures"`
}

func writeTakeoverLadder(w http.ResponseWriter, tenant string, v store.TenantSettingValues) {
	rungs := store.TakeoverLadderOf(v)
	out := takeoverLadderBody{TenantID: tenant, Vendors: store.AgentKinds, MaxFailuresMax: store.TakeoverMaxFailuresMax,
		Kinds: make([]takeoverRungJSON, 0, len(rungs))}
	for _, r := range rungs {
		out.Kinds = append(out.Kinds, takeoverRungJSON{Kind: r.Kind, Order: r.Order, MaxFailures: r.MaxFailures, Set: r.Set})
	}
	writeJSON(w, http.StatusOK, out)
}

// GET /v1/takeover-ladder
func (s *Server) handleTakeoverLadder(w http.ResponseWriter, r *http.Request) {
	t, _, _, _, ok := s.membersActor(w, r, rbac.TopicsRead)
	if !ok {
		return
	}
	ts, ok := s.o.Store.(store.TenantSettings)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no workspace settings")
		return
	}
	cfg, err := ts.TenantConfig(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "takeover ladder unavailable")
		return
	}
	writeTakeoverLadder(w, t.ID, cfg.Settings)
}

// PUT /v1/takeover-ladder {kinds: {"<kind>": {order, max_failures} | null}}
func (s *Server) handlePutTakeoverLadder(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	kv, ok := s.o.Store.(store.TenantKV)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no workspace settings")
		return
	}
	var body struct {
		Kinds map[string]json.RawMessage `json:"kinds"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	set, reset, ok := takeoverLadderKinds(w, body.Kinds)
	if !ok {
		return
	}
	p, err := store.TakeoverLadderPatch(set, reset)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_ladder", badSettingDetail(err))
		return
	}
	v, err := kv.SetTenantSettings(r.Context(), t.ID, p)
	switch {
	case errors.Is(err, store.ErrBadTenantSetting):
		writeErr(w, http.StatusBadRequest, "bad_ladder", badSettingDetail(err))
		return
	case errors.Is(err, store.ErrTenantSettingsUnavailable):
		writeErr(w, http.StatusServiceUnavailable, "settings_unavailable", "workspace settings are not available until the database is migrated")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "takeover ladder not saved")
		return
	}
	logSet := make([]string, 0, len(set))
	for _, k := range set {
		logSet = append(logSet, k.Kind+"="+strings.Join(k.Order, ">"))
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Strs("set", logSet).Strs("reset", reset).
		Msg("tenant.takeover_ladder_changed")
	writeTakeoverLadder(w, t.ID, v)
}

// takeoverLadderKinds reads the kinds object: null resets a kind, an object
// sets it (unknown fields refused). The store checks the rules. ok=false: it
// already answered.
func takeoverLadderKinds(w http.ResponseWriter, in map[string]json.RawMessage) ([]store.TakeoverRung, []string, bool) {
	var set []store.TakeoverRung
	var reset []string
	for kind, raw := range in {
		if string(bytes.TrimSpace(raw)) == "null" {
			reset = append(reset, kind)
			continue
		}
		var k takeoverRungPatchJSON
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&k); err != nil || k.Order == nil || k.MaxFailures == nil {
			writeErr(w, http.StatusBadRequest, "bad_ladder", "kinds."+kind+" is {order: [<vendor>, ...], max_failures: whole number} or null")
			return nil, nil, false
		}
		set = append(set, store.TakeoverRung{Kind: kind, Order: k.Order, MaxFailures: *k.MaxFailures})
	}
	return set, reset, true
}

func (s *Server) takeoverLadderPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeTakeoverLadder(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/takeover-ladder", s.handleTakeoverLadder)
	mux.HandleFunc("PUT /v1/takeover-ladder", s.handlePutTakeoverLadder)
	mux.HandleFunc("OPTIONS /v1/takeover-ladder", s.takeoverLadderPreflight)
}
