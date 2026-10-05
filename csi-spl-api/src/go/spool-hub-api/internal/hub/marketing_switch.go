package hub

import (
	"context"
	"errors"
	"net/http"
	"slices"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Marketing is switchable per workspace (spec 090 §15; owner HUM-10, t1
// f0c3927e msg 37bcb88b item 4). Two halves, both must say yes:
//
//   - the OUTER allow-list, cnf marketing.workspaces (Options.MarketingWorkspaces):
//     workspace ids, or "all". A workspace outside it gets 404 on every
//     /v1/marketing route, the switch included, as if the feature did not exist.
//   - the INNER switch, tenants.marketing_enabled (rdb 0129): the workspace
//     admin turns it on or off at runtime. It starts OFF (owner, t1 f0c3927e
//     msg 5cd2e544: "nobody should be spamming LinkedIn"), so nothing posts
//     until an admin of an allow-listed workspace turns it on.
//
// The flag is never read outside the allow-list, so it cannot turn
// marketing on there. The demo workspace (specs/077) never gets marketing,
// even under "all": its visitors get 403 before the allow-list is read.
//
// Every marketing route but the switch itself is registered through
// marketingRoute, so it answers 404 unless both halves say yes.

// marketingListed reports whether the cnf allow-list admits tenant.
func (s *Server) marketingListed(tenant string) bool {
	l := s.o.MarketingWorkspaces
	return slices.Equal(l, []string{"all"}) || slices.Contains(l, tenant)
}

// marketingDemo writes 403 when tenant is the open demo workspace.
func (s *Server) marketingDemo(w http.ResponseWriter, tenant string) bool {
	if s.o.DemoWorkspace == "" || tenant != s.o.DemoWorkspace {
		return false
	}
	writeForbidden(w, rbac.TenantSettings, "marketing is never on in the demo workspace")
	return true
}

// marketingEnabled is the inner switch; false when the store keeps none.
func (s *Server) marketingEnabled(ctx context.Context, tenant string) (bool, error) {
	ms, ok := s.o.Store.(store.MarketingSwitch)
	if !ok {
		return false, nil
	}
	return ms.MarketingEnabled(ctx, tenant)
}

func writeMarketingOff(w http.ResponseWriter) {
	writeErr(w, http.StatusNotFound, "not_found", "marketing is not enabled in this workspace")
}

// marketingHandler is a marketing route's handler, given the caller's
// workspace, already proved allow-listed and switched on.
type marketingHandler func(w http.ResponseWriter, r *http.Request, tenant string)

// marketingRoute registers h behind the effective switch: the caller's
// workspace must be allow-listed AND switched on, else 404.
func (s *Server) marketingRoute(mux *http.ServeMux, pattern string, h marketingHandler) {
	mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
		s.allowOrigin(w, r)
		t, _, ok := s.humanTenant(w, r)
		if !ok || s.marketingDemo(w, t.ID) {
			return
		}
		if !s.marketingListed(t.ID) {
			writeMarketingOff(w)
			return
		}
		on, err := s.marketingEnabled(r.Context(), t.ID)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "marketing switch unavailable")
			return
		}
		if !on {
			writeMarketingOff(w)
			return
		}
		h(w, r, t.ID)
	})
}

type marketingSwitchBody struct {
	TenantID string `json:"tenant_id"`
	Enabled  bool   `json:"enabled"`
}

// marketingSwitchActor resolves the caller for the switch routes: 404 outside
// the allow-list (before any role check, so it reveals nothing), then 403
// unless the caller may change the workspace settings (an admin).
func (s *Server) marketingSwitchActor(w http.ResponseWriter, r *http.Request) (store.MarketingSwitch, string, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok || s.marketingDemo(w, t.ID) {
		return nil, "", false
	}
	if !s.marketingListed(t.ID) {
		writeMarketingOff(w)
		return nil, "", false
	}
	if hum == "" {
		writeForbidden(w, rbac.TenantSettings, "the marketing switch needs a member session")
		return nil, "", false
	}
	if !s.permit(w, r, t.ID, hum, rbac.TenantSettings) {
		return nil, "", false
	}
	ms, ok := s.o.Store.(store.MarketingSwitch)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no marketing switch")
		return nil, "", false
	}
	return ms, t.ID, true
}

func (s *Server) writeMarketingSwitch(w http.ResponseWriter, r *http.Request, ms store.MarketingSwitch, tenant string) {
	on, err := ms.MarketingEnabled(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "marketing switch unavailable")
		return
	}
	writeJSON(w, http.StatusOK, marketingSwitchBody{TenantID: tenant, Enabled: on})
}

// GET /v1/marketing/settings
func (s *Server) handleMarketingSwitch(w http.ResponseWriter, r *http.Request) {
	if ms, tenant, ok := s.marketingSwitchActor(w, r); ok {
		s.writeMarketingSwitch(w, r, ms, tenant)
	}
}

// PATCH /v1/marketing/settings {enabled}
func (s *Server) handlePatchMarketingSwitch(w http.ResponseWriter, r *http.Request) {
	ms, tenant, ok := s.marketingSwitchActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Enabled *bool `json:"enabled"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if body.Enabled == nil {
		writeErr(w, http.StatusBadRequest, "bad_setting", "enabled (true or false) is required")
		return
	}
	err := ms.SetMarketingEnabled(r.Context(), tenant, *body.Enabled)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such tenant")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "marketing switch unavailable")
		return
	}
	s.writeMarketingSwitch(w, r, ms, tenant)
}

func (s *Server) marketingPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PATCH")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/marketing: any member's probe, 200 only while marketing is on in
// the workspace (the WUI shows the section on it), else marketingRoute's 404.
func (s *Server) handleMarketingStatus(w http.ResponseWriter, _ *http.Request, tenant string) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, marketingSwitchBody{TenantID: tenant, Enabled: true})
}

// routeMarketing registers the switch and the probe. Every later
// /v1/marketing route (spec 090 T006..T010) goes through marketingRoute.
func (s *Server) routeMarketing(mux *http.ServeMux) {
	s.marketingRoute(mux, "GET /v1/marketing", s.handleMarketingStatus)
	mux.HandleFunc("GET /v1/marketing/settings", s.handleMarketingSwitch)
	mux.HandleFunc("PATCH /v1/marketing/settings", s.handlePatchMarketingSwitch)
	mux.HandleFunc("OPTIONS /v1/marketing/settings", s.marketingPreflight)
}
