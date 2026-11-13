package hub

import (
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The workspace's average hours per day (spec 107 FR-41, SPL-5440; owner
// HUM-10 t1 59a7062f msg df038453: per day, a soft norm, set by the biz
// owner, the product owner and the workspace admin):
//
//	GET /v1/hours/norm  {norm_day_minutes, max_minutes}
//	PUT /v1/hours/norm  {norm_day_minutes: 0..1440}; 0 = no norm
//
// Both need hours.norm (rdb 0279). The value is the registered workspace
// key hours.norm_day_minutes (store/hours.go), so a tenant.settings holder
// may also set it through PATCH /v1/tenant/settings. A soft norm: nothing
// refuses an entry for it; a member reads it on GET /v1/me/hours.

type hoursNormBody struct {
	NormDayMinutes int `json:"norm_day_minutes"`
	MaxMinutes     int `json:"max_minutes"`
}

// hoursNormCaller is the signed-in member holding hours.norm.
func (s *Server) hoursNormCaller(w http.ResponseWriter, r *http.Request) (store.Tenant, string, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return store.Tenant{}, "", false
	}
	if hum == "" {
		writeForbidden(w, rbac.HoursNorm, "the average hours need a signed-in member session")
		return store.Tenant{}, "", false
	}
	if !s.permit(w, r, t.ID, hum, rbac.HoursNorm) {
		return store.Tenant{}, "", false
	}
	return t, hum, true
}

// GET /v1/hours/norm
func (s *Server) handleGetHoursNorm(w http.ResponseWriter, r *http.Request) {
	t, _, ok := s.hoursNormCaller(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, hoursNormBody{NormDayMinutes: store.HoursSettingsOf(t.Settings).NormDayMinutes,
		MaxMinutes: store.HoursNormDayMax})
}

// PUT /v1/hours/norm {norm_day_minutes}
func (s *Server) handlePutHoursNorm(w http.ResponseWriter, r *http.Request) {
	t, hum, ok := s.hoursNormCaller(w, r)
	if !ok {
		return
	}
	var body struct {
		NormDayMinutes *int `json:"norm_day_minutes"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if body.NormDayMinutes == nil {
		writeErr(w, http.StatusBadRequest, "bad_setting", "norm_day_minutes is required: 0..1440 minutes, 0 = no norm")
		return
	}
	n := *body.NormDayMinutes
	if !s.saveSettings(w, r, t.ID, store.TenantSettingsPatch{Set: map[string]any{store.HoursKeyNormDay: n}}) {
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", hum).Int("norm_day_minutes", n).Msg("hours.norm_changed")
	writeJSON(w, http.StatusOK, hoursNormBody{NormDayMinutes: n, MaxMinutes: store.HoursNormDayMax})
}

func (s *Server) routeHoursNorm(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/hours/norm", s.handleGetHoursNorm)
	mux.HandleFunc("PUT /v1/hours/norm", s.handlePutHoursNorm)
	mux.HandleFunc("OPTIONS /v1/hours/norm", s.hoursPreflight)
}
