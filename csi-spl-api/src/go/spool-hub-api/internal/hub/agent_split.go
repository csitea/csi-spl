package hub

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The vendor split per task kind (spec 115 HUB-1, rdb 0163): Workspace
// settings -> Vendor split reads and edits it, and do_spl_agent_split_show
// --kind prints one kind's row for the picker. tenant.settings, like the
// five-column split of PATCH /v1/tenant/settings that it replaces.
//
//	GET   /v1/agent-split -> {tenant_id, vendors, kinds: [{kind, weights, backup, main, set, updated_by, updated_at}]}
//	PATCH /v1/agent-split {kinds: {"<kind>": {weights: {"<vendor>": n}, backup} | null}}
//
// A kind in the PATCH replaces that kind's row whole (a vendor left out is
// 0); null drops the workspace's row, so the kind reads as the spec 115
// section 2 default again. A row outside the section 2 rules (sum 100, one
// main, the backup not the main, agy 0 in a coding kind, secret on claude or
// mistral only) is 400 bad_split naming the rule, and nothing is written.

type splitKindJSON struct {
	Kind      string         `json:"kind"`
	Weights   map[string]int `json:"weights"`
	Backup    string         `json:"backup"`
	Main      string         `json:"main"`
	Set       bool           `json:"set"`
	UpdatedBy string         `json:"updated_by,omitempty"`
	UpdatedAt *time.Time     `json:"updated_at,omitempty"`
}

type agentSplitKindsBody struct {
	TenantID string          `json:"tenant_id"`
	Vendors  []string        `json:"vendors"`
	Kinds    []splitKindJSON `json:"kinds"`
}

// splitKindPatchJSON is one kind of the PATCH.
type splitKindPatchJSON struct {
	Weights map[string]int `json:"weights"`
	Backup  string         `json:"backup"`
}

func (s *Server) splitKindsStore(w http.ResponseWriter) (store.SplitKinds, bool) {
	sk, ok := s.o.Store.(store.SplitKinds)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no agent split per kind")
	}
	return sk, ok
}

func (s *Server) writeSplitKinds(w http.ResponseWriter, r *http.Request, tenant string, sk store.SplitKinds) {
	rows, err := sk.SplitKinds(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "agent split unavailable")
		return
	}
	out := agentSplitKindsBody{TenantID: tenant, Vendors: store.AgentKinds, Kinds: make([]splitKindJSON, 0, len(rows))}
	for _, k := range rows {
		j := splitKindJSON{Kind: k.Kind, Weights: k.Weights, Backup: k.Backup, Main: k.Main(), Set: k.Set, UpdatedBy: k.UpdatedBy}
		if !k.UpdatedAt.IsZero() {
			at := k.UpdatedAt
			j.UpdatedAt = &at
		}
		out.Kinds = append(out.Kinds, j)
	}
	writeJSON(w, http.StatusOK, out)
}

// GET /v1/agent-split
func (s *Server) handleAgentSplit(w http.ResponseWriter, r *http.Request) {
	t, _, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	sk, ok := s.splitKindsStore(w)
	if !ok {
		return
	}
	s.writeSplitKinds(w, r, t.ID, sk)
}

// PATCH /v1/agent-split {kinds: {"<kind>": {weights, backup} | null}}
func (s *Server) handlePatchAgentSplit(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	sk, ok := s.splitKindsStore(w)
	if !ok {
		return
	}
	var body struct {
		Kinds map[string]json.RawMessage `json:"kinds"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	p, ok := splitKindPatch(w, body.Kinds)
	if !ok {
		return
	}
	p.By = a.HumanID
	err := sk.SetSplitKinds(r.Context(), t.ID, p, s.o.Now())
	switch {
	case errors.Is(err, store.ErrBadSplitKind):
		writeErr(w, http.StatusBadRequest, "bad_split", strings.TrimPrefix(err.Error(), store.ErrBadSplitKind.Error()+": "))
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "agent split not saved")
		return
	}
	set := make([]string, 0, len(p.Set))
	for _, k := range p.Set {
		set = append(set, k.Kind+"="+k.Main()+"/"+k.Backup)
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Strs("set", set).Strs("reset", p.Reset).
		Msg("tenant.agent_split_changed")
	s.writeSplitKinds(w, r, t.ID, sk)
}

// splitKindPatch reads the kinds object: null resets a kind, an object sets
// it (unknown fields refused). The store checks the rules. ok=false: it
// already answered.
func splitKindPatch(w http.ResponseWriter, in map[string]json.RawMessage) (store.SplitKindPatch, bool) {
	var p store.SplitKindPatch
	if len(in) == 0 {
		writeErr(w, http.StatusBadRequest, "bad_split", "kinds names at least one of "+strings.Join(store.SplitTaskKinds, ", "))
		return p, false
	}
	for kind, raw := range in {
		if string(bytes.TrimSpace(raw)) == "null" {
			p.Reset = append(p.Reset, kind)
			continue
		}
		var k splitKindPatchJSON
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&k); err != nil || k.Weights == nil {
			writeErr(w, http.StatusBadRequest, "bad_split", "kinds."+kind+" is {weights: {<vendor>: whole number 0..100}, backup: <vendor>} or null")
			return p, false
		}
		p.Set = append(p.Set, store.SplitKind{Kind: kind, Weights: k.Weights, Backup: k.Backup})
	}
	return p, true
}

func (s *Server) agentSplitPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PATCH")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeAgentSplit(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/agent-split", s.handleAgentSplit)
	mux.HandleFunc("PATCH /v1/agent-split", s.handlePatchAgentSplit)
	mux.HandleFunc("OPTIONS /v1/agent-split", s.agentSplitPreflight)
}
