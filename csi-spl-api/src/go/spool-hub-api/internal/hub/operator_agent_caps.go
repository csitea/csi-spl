package hub

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Per-workspace agent caps, the spool-hub admin's side (spec 147 6.1, rdb
// 0212, SPL-2675). Owner HUM-10 t1 4ce4c8db msg 9c96ca9e: "the spool-hub
// admin should be able to define a max amount of agents and their kind per
// workspace". Only an admin of the operator workspace reaches these routes
// (operatorActor, the workspace CRUD rule); the store writes in the operator
// scope, the one scope rdb 0212 lets write, and audits every change.
//
//	GET    /v1/operator/workspaces/{id}/agent-caps           the caps
//	PUT    /v1/operator/workspaces/{id}/agent-caps           {"caps": {vendor: n | null}}
//	DELETE /v1/operator/workspaces/{id}/agent-caps/{vendor}  204, back to uncapped

// agentCapsBody is the operator's view of one workspace's caps.
type agentCapsBody struct {
	WorkspaceID string         `json:"workspace_id"`
	Caps        map[string]int `json:"caps"`
	UpdatedAt   *string        `json:"updated_at"`
	UpdatedBy   *string        `json:"updated_by"`
}

func agentCapsJSON(c store.AgentCaps) agentCapsBody {
	out := agentCapsBody{WorkspaceID: c.TenantID, Caps: c.Caps, UpdatedAt: rfcOrNil(c.UpdatedAt)}
	if out.Caps == nil {
		out.Caps = map[string]int{}
	}
	if c.UpdatedBy != "" {
		out.UpdatedBy = &c.UpdatedBy
	}
	return out
}

// agentCapsTarget authorises an operator caps route and resolves the
// workspace; false = answered.
func (s *Server) agentCapsTarget(w http.ResponseWriter, r *http.Request) (opActor, store.AgentCapStore, string, bool) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return opActor{}, nil, "", false
	}
	cs, ok := s.o.Store.(store.AgentCapStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no agent caps")
		return opActor{}, nil, "", false
	}
	ws, ok := s.workspaceTarget(w, r, a)
	if !ok {
		return opActor{}, nil, "", false
	}
	return a, cs, ws.ID, true
}

// writeAgentCapsErr answers a store error of the caps routes.
func writeAgentCapsErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrBadCapVendor):
		writeErr(w, http.StatusBadRequest, "bad_vendor", err.Error())
	case errors.Is(err, store.ErrBadCapValue):
		writeErr(w, http.StatusBadRequest, "bad_cap", "max_live must be a non-negative integer")
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such workspace")
	case errors.Is(err, store.ErrAgentCapsUnavailable):
		writeErr(w, http.StatusServiceUnavailable, "not_migrated", "agent caps need rdb 0212")
	default:
		writeErr(w, http.StatusInternalServerError, "internal", "agent caps not stored")
	}
}

// GET /v1/operator/workspaces/{id}/agent-caps
func (s *Server) handleOperatorAgentCaps(w http.ResponseWriter, r *http.Request) {
	_, cs, id, ok := s.agentCapsTarget(w, r)
	if !ok {
		return
	}
	c, err := cs.AgentCaps(r.Context(), id)
	if err != nil {
		writeAgentCapsErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, agentCapsJSON(c))
}

// parseAgentCaps reads {"caps": {vendor: n | null}}: null removes a cap; a
// value that is not a whole number >= 0 is bad_cap.
func parseAgentCaps(w http.ResponseWriter, r *http.Request) (map[string]*int, bool) {
	var req struct {
		Caps map[string]json.RawMessage `json:"caps"`
	}
	if !decodeMembers(w, r, &req) {
		return nil, false
	}
	if len(req.Caps) == 0 {
		writeErr(w, http.StatusBadRequest, "bad_json", `body must be {"caps": {vendor: max_live | null}}`)
		return nil, false
	}
	out := map[string]*int{}
	for v, raw := range req.Caps {
		if !store.IsAgentCapVendor(v) {
			writeErr(w, http.StatusBadRequest, "bad_vendor", "vendor '"+v+"' is not supported")
			return nil, false
		}
		if string(raw) == "null" {
			out[v] = nil
			continue
		}
		n, err := strconv.Atoi(string(raw))
		if err != nil || n < 0 {
			writeErr(w, http.StatusBadRequest, "bad_cap", "max_live must be a non-negative integer")
			return nil, false
		}
		out[v] = &n
	}
	return out, true
}

// PUT /v1/operator/workspaces/{id}/agent-caps
func (s *Server) handleOperatorAgentCapsPut(w http.ResponseWriter, r *http.Request) {
	a, cs, id, ok := s.agentCapsTarget(w, r)
	if !ok {
		return
	}
	caps, ok := parseAgentCaps(w, r)
	if !ok {
		return
	}
	s.setAgentCaps(w, r, a, cs, id, caps, http.StatusOK)
}

// DELETE /v1/operator/workspaces/{id}/agent-caps/{vendor}
func (s *Server) handleOperatorAgentCapDelete(w http.ResponseWriter, r *http.Request) {
	a, cs, id, ok := s.agentCapsTarget(w, r)
	if !ok {
		return
	}
	v := r.PathValue("vendor")
	if !store.IsAgentCapVendor(v) {
		writeErr(w, http.StatusBadRequest, "bad_vendor", "vendor '"+v+"' is not supported")
		return
	}
	s.setAgentCaps(w, r, a, cs, id, map[string]*int{v: nil}, http.StatusNoContent)
}

// setAgentCaps writes caps and answers status (200 with the caps, or 204).
func (s *Server) setAgentCaps(w http.ResponseWriter, r *http.Request, a opActor, cs store.AgentCapStore, id string, caps map[string]*int, status int) {
	c, err := cs.SetAgentCaps(r.Context(), id, caps, store.AgentCapActor{Tenant: a.tenant, Hum: a.hum}, s.o.Now())
	if err != nil {
		writeAgentCapsErr(w, err)
		return
	}
	s.o.Log.Info().Str("tenant", id).Str("by", a.hum).Interface("caps", c.Caps).Msg("operator.agent_caps")
	if status == http.StatusNoContent {
		w.WriteHeader(status)
		return
	}
	writeJSON(w, status, agentCapsJSON(c))
}

func (s *Server) operatorAgentCapsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// routeAgentCaps registers both doors of spec 147: the operator's
// (this file) and the workspace's read (tenant_agent_caps.go).
func (s *Server) routeAgentCaps(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/workspaces/{id}/agent-caps", s.handleOperatorAgentCaps)
	mux.HandleFunc("PUT /v1/operator/workspaces/{id}/agent-caps", s.handleOperatorAgentCapsPut)
	mux.HandleFunc("DELETE /v1/operator/workspaces/{id}/agent-caps/{vendor}", s.handleOperatorAgentCapDelete)
	mux.HandleFunc("OPTIONS /v1/operator/workspaces/{id}/agent-caps", s.operatorAgentCapsPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/workspaces/{id}/agent-caps/{vendor}", s.operatorAgentCapsPreflight)
	mux.HandleFunc("GET /v1/tenant/agent-caps", s.handleTenantAgentCaps)
	mux.HandleFunc("OPTIONS /v1/tenant/agent-caps", s.preflight)
}
