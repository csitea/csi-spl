package hub

import (
	"encoding/json"
	"errors"
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
//
// A member's own norm (SPL-5558; owner HUM-10 t1 59a7062f msg d26fd5e6:
// "settable per person via the persons section"), on the People card:
//
//	GET /v1/members/{human_id}/hours/norm  {member_id, norm_day_minutes,
//	    workspace_norm_day_minutes, effective_norm_day_minutes, max_minutes}
//	PUT /v1/members/{human_id}/hours/norm  {norm_day_minutes: 0..1440 | null}
//
// Same permission, hours.norm. norm_day_minutes null = no override, the
// workspace's value is in force. It is kept in the membership settings
// (rdb 0078, store.HoursMemberNormKey); the member's own settings never
// write it. GET /v1/me/hours and GET /v1/hours answer the effective norm.

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

type hoursMemberNormBody struct {
	Member    string `json:"member_id"`
	Own       *int   `json:"norm_day_minutes"`
	Workspace int    `json:"workspace_norm_day_minutes"`
	Effective int    `json:"effective_norm_day_minutes"`
	Max       int    `json:"max_minutes"`
}

// hoursMemberNormTarget is the hours.norm caller and the member of this
// workspace the path names; 404 when it names none.
func (s *Server) hoursMemberNormTarget(w http.ResponseWriter, r *http.Request) (store.Tenant, string, string, store.Hours, bool) {
	t, hum, ok := s.hoursNormCaller(w, r)
	if !ok {
		return t, "", "", nil, false
	}
	target := r.PathValue("human_id")
	h, isH := s.o.Store.(store.Humans)
	hs, isHours := s.o.Store.(store.Hours)
	if !isH || !isHours || !humanIDRe.MatchString(target) {
		writeErr(w, http.StatusNotFound, "not_found", "no such member")
		return t, "", "", nil, false
	}
	if _, err := s.memberRoleAny(r.Context(), h, t.ID, target); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such member")
		return t, "", "", nil, false
	}
	return t, hum, target, hs, true
}

// writeHoursMemberNorm answers the member's norm as the store holds it.
func (s *Server) writeHoursMemberNorm(w http.ResponseWriter, r *http.Request, t store.Tenant, hs store.Hours, target string) {
	norms, err := hs.HoursMemberNorms(r.Context(), t.ID, []string{target})
	if err != nil {
		s.hoursFail(w, t.ID, "member norm", err)
		return
	}
	n := norms[target]
	writeJSON(w, http.StatusOK, hoursMemberNormBody{Member: target, Own: n.Own, Workspace: n.Workspace,
		Effective: n.Effective, Max: store.HoursNormDayMax})
}

// GET /v1/members/{human_id}/hours/norm
func (s *Server) handleGetHoursMemberNorm(w http.ResponseWriter, r *http.Request) {
	t, _, target, hs, ok := s.hoursMemberNormTarget(w, r)
	if ok {
		s.writeHoursMemberNorm(w, r, t, hs, target)
	}
}

// PUT /v1/members/{human_id}/hours/norm {norm_day_minutes: 0..1440 | null}
func (s *Server) handlePutHoursMemberNorm(w http.ResponseWriter, r *http.Request) {
	t, hum, target, hs, ok := s.hoursMemberNormTarget(w, r)
	if !ok {
		return
	}
	var body struct {
		NormDayMinutes json.RawMessage `json:"norm_day_minutes"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	var own *int
	if len(body.NormDayMinutes) == 0 || (string(body.NormDayMinutes) != "null" && json.Unmarshal(body.NormDayMinutes, &own) != nil) {
		writeErr(w, http.StatusBadRequest, "bad_setting", "norm_day_minutes is required: 0..1440 minutes, or null for the workspace's")
		return
	}
	if err := hs.SetHoursMemberNorm(r.Context(), t.ID, target, own); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "not_found", "no such member")
			return
		}
		s.hoursFail(w, t.ID, "member norm", err)
		return
	}
	ev := s.o.Log.Info().Str("tenant", t.ID).Str("by", hum).Str("member", target)
	if own != nil {
		ev = ev.Int("norm_day_minutes", *own)
	}
	ev.Msg("hours.member_norm_changed")
	s.writeHoursMemberNorm(w, r, t, hs, target)
}

func (s *Server) routeHoursNorm(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/hours/norm", s.handleGetHoursNorm)
	mux.HandleFunc("PUT /v1/hours/norm", s.handlePutHoursNorm)
	mux.HandleFunc("OPTIONS /v1/hours/norm", s.hoursPreflight)
	mux.HandleFunc("GET /v1/members/{human_id}/hours/norm", s.handleGetHoursMemberNorm)
	mux.HandleFunc("PUT /v1/members/{human_id}/hours/norm", s.handlePutHoursMemberNorm)
	mux.HandleFunc("OPTIONS /v1/members/{human_id}/hours/norm", s.hoursPreflight)
}
