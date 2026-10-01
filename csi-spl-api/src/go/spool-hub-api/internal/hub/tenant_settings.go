package hub

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Tenant settings area (SPL-1037, specs/046): General (display name,
// default locale), the fallback responder list (SPL-997), every channel of
// the tenant with its no-fallback flag and an admin archive, and the member
// edits the Users page lacked (name, locale, suspension). Every route checks
// its permission per request (046 §3); the WUI hiding the entry is
// convenience only.

func (s *Server) tenantSettingsStore(w http.ResponseWriter) (store.TenantSettings, store.Fallbacks, bool) {
	ts, ok1 := s.o.Store.(store.TenantSettings)
	fb, ok2 := s.o.Store.(store.Fallbacks)
	if !ok1 || !ok2 {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no tenant settings")
		return nil, nil, false
	}
	return ts, fb, true
}

type tenantSettingsBody struct {
	TenantID      string `json:"tenant_id"`
	DisplayName   string `json:"display_name"`
	DefaultLocale string `json:"default_locale"`
	// TopicArchivePolicy is "Who can archive topics" (CLE-77819): the value in
	// force (everyone | admins | starter), never "".
	TopicArchivePolicy string   `json:"topic_archive_policy"`
	Responders         []string `json:"responders"`
	MaxResponders      int      `json:"max_responders"`
	// IssuePrefix is the key prefix of the tenant's issues (W16, spec 047);
	// "" when this hub's store keeps no issues.
	IssuePrefix string `json:"issue_prefix"`
}

func (s *Server) writeTenantSettings(w http.ResponseWriter, r *http.Request, t store.Tenant, ts store.TenantSettings, fb store.Fallbacks) {
	cfg, err := ts.TenantConfig(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "tenant settings unavailable")
		return
	}
	resp, err := fb.TenantResponders(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "tenant settings unavailable")
		return
	}
	if resp == nil {
		resp = []string{}
	}
	var prefix string
	if is, ok := s.o.Store.(store.Issues); ok {
		if prefix, err = is.IssuePrefix(r.Context(), t.ID); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "tenant settings unavailable")
			return
		}
	}
	writeJSON(w, http.StatusOK, tenantSettingsBody{TenantID: t.ID, DisplayName: cfg.DisplayName,
		DefaultLocale: cfg.DefaultLocale, TopicArchivePolicy: store.EffectiveArchivePolicy(cfg.TopicArchivePolicy),
		Responders: resp, MaxResponders: store.MaxResponders, IssuePrefix: prefix})
}

// GET /v1/tenant/settings
func (s *Server) handleTenantSettings(w http.ResponseWriter, r *http.Request) {
	t, _, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	ts, fb, ok := s.tenantSettingsStore(w)
	if !ok {
		return
	}
	s.writeTenantSettings(w, r, t, ts, fb)
}

// PATCH /v1/tenant/settings {display_name?, default_locale?, responders?, issue_prefix?}
func (s *Server) handlePatchTenantSettings(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	ts, fb, ok := s.tenantSettingsStore(w)
	if !ok {
		return
	}
	var body struct {
		DisplayName        *string   `json:"display_name"`
		DefaultLocale      *string   `json:"default_locale"`
		TopicArchivePolicy *string   `json:"topic_archive_policy"`
		Responders         *[]string `json:"responders"`
		IssuePrefix        *string   `json:"issue_prefix"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	var list []string
	if body.Responders != nil {
		if list, ok = responderList(w, *body.Responders); !ok {
			return
		}
	}
	is, hasIssues := s.o.Store.(store.Issues)
	if body.IssuePrefix != nil {
		if !hasIssues {
			writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no issues")
			return
		}
		if _, err := store.CheckIssuePrefix(*body.IssuePrefix); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_setting", "issue_prefix is 1..10 of A-Z and 0-9, starting with a letter")
			return
		}
	}
	if body.DisplayName != nil || body.DefaultLocale != nil || body.TopicArchivePolicy != nil {
		err := ts.SetTenantConfig(r.Context(), t.ID, store.TenantConfigPatch{DisplayName: body.DisplayName,
			DefaultLocale: body.DefaultLocale, TopicArchivePolicy: body.TopicArchivePolicy})
		switch {
		case errors.Is(err, store.ErrBadTenantConfig):
			writeErr(w, http.StatusBadRequest, "bad_setting", "display_name is one line of at most 200 characters; default_locale is a supported locale or empty; topic_archive_policy is everyone, admins or starter")
			return
		case err != nil:
			writeErr(w, http.StatusInternalServerError, "internal", "tenant settings not saved")
			return
		}
	}
	if body.Responders != nil {
		if err := fb.SetTenantResponders(r.Context(), t.ID, list); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "responders not saved")
			return
		}
	}
	if body.IssuePrefix != nil {
		if _, err := is.SetIssuePrefix(r.Context(), t.ID, *body.IssuePrefix); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "issue prefix not saved")
			return
		}
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Bool("name", body.DisplayName != nil).
		Bool("locale", body.DefaultLocale != nil).Bool("archive_policy", body.TopicArchivePolicy != nil).
		Bool("responders", body.Responders != nil).
		Bool("issue_prefix", body.IssuePrefix != nil).Msg("tenant.settings_changed")
	s.writeTenantSettings(w, r, t, ts, fb)
}

// responderList dedupes the PATCH responder ids in order and checks each is
// an agent id (never a HUM-*), at most MaxResponders. ok=false: it answered.
func responderList(w http.ResponseWriter, ids []string) ([]string, bool) {
	var list []string
	seen := map[string]bool{}
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if !agentIDRe.MatchString(id) || strings.HasPrefix(id, "HUM-") {
			writeErr(w, http.StatusBadRequest, "bad_responder", "responders must be agent ids (CLE-01, GRK-03)")
			return nil, false
		}
		if !seen[id] {
			seen[id] = true
			list = append(list, id)
		}
	}
	if len(list) > store.MaxResponders {
		writeErr(w, http.StatusBadRequest, "bad_responder", "at most 20 responders")
		return nil, false
	}
	return list, true
}

type tenantChannelRow struct {
	Channel     string  `json:"channel"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Visibility  string  `json:"visibility"` // "default" (every member) | "members"
	Members     int     `json:"members"`    // human members; 0 for a default channel (no rows)
	Agents      int     `json:"agents"`
	Messages    int     `json:"messages"`
	NoFallback  bool    `json:"no_fallback"`
	CreatedBy   string  `json:"created_by"`
	CreatedAt   *string `json:"created_at"`
	LastTS      *string `json:"last_ts"`
	Archivable  bool    `json:"archivable"`
}

// GET /v1/tenant/channels: every channel, the private ones the caller is
// not in too (names and counts only, never a message).
func (s *Server) handleTenantChannels(w http.ResponseWriter, r *http.Request) {
	t, _, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	_, fb, ok := s.tenantSettingsStore(w)
	if !ok {
		return
	}
	rows, err := s.o.Store.ViewChannelStats(r.Context(), t.ID, s.o.Now(), nil)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "channels unavailable")
		return
	}
	out := []tenantChannelRow{}
	for _, c := range rows {
		v := tenantChannelRow{Channel: c.ChannelID, Name: c.Name, Description: c.Description, Visibility: "members",
			Agents: c.Agents, Messages: c.Count, CreatedBy: c.CreatedBy, Archivable: !store.ChannelPublic(c.ChannelID)}
		if store.ChannelPublic(c.ChannelID) {
			v.Visibility = "default"
		} else if ms, err := s.o.Store.ChannelHumanMembers(r.Context(), t.ID, c.ChannelID); err == nil {
			v.Members = len(ms)
		}
		if off, err := fb.ChannelNoFallback(r.Context(), t.ID, c.ChannelID); err == nil {
			v.NoFallback = off
		}
		if !c.CreatedAt.IsZero() {
			at := rfc(c.CreatedAt)
			v.CreatedAt = &at
		}
		if !c.LastAt.IsZero() {
			at := rfc(c.LastAt)
			v.LastTS = &at
		}
		out = append(out, v)
	}
	writeJSON(w, http.StatusOK, map[string]any{"tenant_id": t.ID, "channels": out})
}

// tenantChannel resolves {channel} for an admin route: any channel of the
// tenant, membership or not. ok=false means it already answered.
func (s *Server) tenantChannel(w http.ResponseWriter, r *http.Request, tenant string) (string, bool) {
	ch := store.NormalizeChannel(r.PathValue("channel"))
	if !store.ValidChannelID(ch) {
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+r.PathValue("channel")+" in this tenant")
		return "", false
	}
	switch known, err := s.o.Store.ChannelKnown(r.Context(), tenant, ch); {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel lookup failed")
		return "", false
	case !known:
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+r.PathValue("channel")+" in this tenant")
		return "", false
	}
	return ch, true
}

// PATCH /v1/tenant/channels/{channel} {no_fallback}
func (s *Server) handlePatchTenantChannel(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	_, fb, ok := s.tenantSettingsStore(w)
	if !ok {
		return
	}
	ch, ok := s.tenantChannel(w, r, t.ID)
	if !ok {
		return
	}
	var body struct {
		NoFallback *bool `json:"no_fallback"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if body.NoFallback == nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "no_fallback is required")
		return
	}
	switch err := fb.SetChannelNoFallback(r.Context(), t.ID, ch, *body.NoFallback); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+ch+" in this tenant")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel not changed")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("by", a.HumanID).Bool("no_fallback", *body.NoFallback).Msg("tenant.channel_fallback")
	writeJSON(w, http.StatusOK, map[string]any{"channel": ch, "no_fallback": *body.NoFallback})
}

// DELETE /v1/tenant/channels/{channel}: an admin archives a channel without
// being its creator (rdb 0092). It is hidden and its slug reserved, and its
// topics and messages move to the Archive view; PUT /v1/channels/{channel}/
// unarchive brings it back. (A hard delete that frees the name is the
// creator's DELETE /v1/channels/{channel}.)
func (s *Server) handleArchiveTenantChannel(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	ch, ok := s.tenantChannel(w, r, t.ID)
	if !ok {
		return
	}
	if store.ChannelPublic(ch) {
		writeErr(w, http.StatusConflict, "channel_public", "#"+ch+" is a default channel: it cannot be archived")
		return
	}
	members := s.channelMemberSet(r.Context(), t.ID, ch)
	switch err := s.o.Store.ArchiveChannel(r.Context(), t.ID, ch, a.HumanID, s.o.Now().UTC()); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+ch+" in this tenant")
		return
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "channel_public", "#"+ch+" cannot be archived")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel not archived")
		return
	}
	s.fanoutChannelFrame(r.Context(), t.ID, members, map[string]any{"type": "channel_deleted", "channel": ch})
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("by", a.HumanID).Msg("tenant.channel_archived")
	w.WriteHeader(http.StatusNoContent)
}

// memberRoleAny is the member's role, a suspended membership included (an
// admin restores or removes it); ErrNotFound when not a member.
func (s *Server) memberRoleAny(ctx context.Context, h store.Humans, tenant, humanID string) (string, error) {
	if ts, ok := s.o.Store.(store.TenantSettings); ok {
		role, _, err := ts.MemberState(ctx, tenant, humanID)
		return role, err
	}
	return h.MemberRole(ctx, humanID, tenant)
}

// PATCH /v1/members/{human_id} {display_name?, locale?, disabled?}
func (s *Server) handleMemberPatch(w http.ResponseWriter, r *http.Request) {
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersInvite)
	if !ok {
		return
	}
	ts, _, ok := s.tenantSettingsStore(w)
	if !ok {
		return
	}
	var body struct {
		DisplayName *string `json:"display_name"`
		Locale      *string `json:"locale"`
		Disabled    *bool   `json:"disabled"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if body.DisplayName == nil && body.Locale == nil && body.Disabled == nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "nothing to change")
		return
	}
	target, _, ok := s.targetRole(w, r, h, t, a, roles)
	if !ok {
		return
	}
	var name string
	if body.DisplayName != nil {
		n, valid := auth.ValidDisplayName(*body.DisplayName)
		if !valid {
			writeErr(w, http.StatusBadRequest, "bad_name", "display_name must be 1..200 characters")
			return
		}
		name = n
	}
	loc := ""
	if body.Locale != nil {
		loc = strings.TrimSpace(*body.Locale)
	}
	if body.Disabled != nil && *body.Disabled && !notSelf(w, a, target) {
		return
	}
	// The profile (name, locale) is the person's own across every tenant:
	// a tenant admin edits it only for an account that is in this tenant
	// alone (046 §3).
	if body.DisplayName != nil || body.Locale != nil {
		shared, err := s.sharedAccount(r.Context(), target, t.ID)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "member lookup failed")
			return
		}
		if shared {
			writeErr(w, http.StatusConflict, "shared_account", "this person is in other tenants too: only they can change their name and language")
			return
		}
	}
	if body.Disabled != nil {
		if err := ts.SetMemberDisabled(r.Context(), t.ID, target, *body.Disabled, s.o.Now()); err != nil {
			writeMemberErr(w, err)
			return
		}
	}
	if body.DisplayName != nil {
		if err := h.SetDisplayName(r.Context(), target, name); err != nil {
			writeMemberErr(w, err)
			return
		}
	}
	if body.Locale != nil {
		if err := h.SetPreferredLocale(r.Context(), target, loc); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_locale", "locale must be a supported locale or empty")
			return
		}
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Str("member", target).Bool("name", body.DisplayName != nil).
		Bool("locale", body.Locale != nil).Bool("disabled_set", body.Disabled != nil).Msg("member.updated")
	w.WriteHeader(http.StatusNoContent)
}

// sharedAccount reports whether humanID holds a membership in a tenant other
// than tenant (Memberships reads across tenants under the operator scope).
func (s *Server) sharedAccount(ctx context.Context, humanID, tenant string) (bool, error) {
	ml, ok := s.o.Store.(store.MembershipLister)
	if !ok {
		return true, nil // cannot tell: refuse the edit
	}
	ms, err := ml.Memberships(ctx, humanID)
	if err != nil {
		return false, err
	}
	for _, m := range ms {
		if m.TenantID != tenant {
			return true, nil
		}
	}
	return false, nil
}

func (s *Server) tenantSettingsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeTenantSettings(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/tenant/settings", s.handleTenantSettings)
	mux.HandleFunc("PATCH /v1/tenant/settings", s.handlePatchTenantSettings)
	mux.HandleFunc("GET /v1/tenant/channels", s.handleTenantChannels)
	mux.HandleFunc("PATCH /v1/tenant/channels/{channel}", s.handlePatchTenantChannel)
	mux.HandleFunc("DELETE /v1/tenant/channels/{channel}", s.handleArchiveTenantChannel)
	mux.HandleFunc("PATCH /v1/members/{human_id}", s.handleMemberPatch)
	mux.HandleFunc("OPTIONS /v1/tenant/settings", s.tenantSettingsPreflight)
	mux.HandleFunc("OPTIONS /v1/tenant/channels", s.tenantSettingsPreflight)
	mux.HandleFunc("OPTIONS /v1/tenant/channels/{channel}", s.tenantSettingsPreflight)
}
