package auth

import (
	"context"
	"errors"
	"net/http"
	"time"
)

// Admin "act as a member" through a temporary clone (specs/054). The owner's
// decision: an admin does not view-as or overlay their own session; the hub
// mints a temporary technical human that is a snapshot of the target's role and
// channel memberships, and this browser is signed in AS that clone. Leaving is
// a plain sign-out — the clone session is cleared and the clone disabled; there
// is no admin token kept in the browser while acting.

// ProviderActAs marks a clone session's Provider claim (specs/054). It lets a
// read cheaply tell an act-as session from a normal one (the WUI banner gate)
// without a store lookup, and it is not a real IdP, so nothing can start such a
// session through the sign-in flow.
const ProviderActAs = "actas"

// ActAsResult is what StartActAs minted.
type ActAsResult struct {
	CloneHum  string
	TargetHum string
	ExpiresAt time.Time
}

// Errors StartActAs returns; the handler maps each to a distinct 403 so the
// caller learns why without leaking who exists in another tenant.
var (
	// ErrActAsForbidden: the admin lacks members.impersonate.
	ErrActAsForbidden = errors.New("auth: act-as not permitted")
	// ErrActAsNotMember: the target is not a member of the admin's tenant.
	ErrActAsNotMember = errors.New("auth: act-as target is not a member")
	// ErrActAsCeiling: the target is a peer admin, the owner, or the admin
	// itself — never a role at or above the admin's (the ceiling).
	ErrActAsCeiling = errors.New("auth: act-as target is not below the admin")
)

// Impersonation backs the act-as routes (specs/054). It encapsulates the
// members.impersonate permission AND the role ceiling AND the clone store, all
// server-side. nil in Options = the act-as routes are not mounted. It is
// defined here with auth-local types on purpose: store imports auth, so auth
// must not import store; the hub supplies the concrete adapter.
type Impersonation interface {
	// StartActAs enforces the permission and ceiling, then mints the clone.
	StartActAs(ctx context.Context, tenant, admin, adminName, target string) (ActAsResult, error)
	// StopActAs ends the clone (the sign-out); ErrNotFound-equivalent is nil
	// (already ended is fine).
	StopActAs(ctx context.Context, tenant, clone string) error
	// IsClone reports whether human is a LIVE clone of tenant.
	IsClone(ctx context.Context, tenant, human string) (bool, error)
}

type actAsReq struct {
	HumanID string `json:"human_id"`
}

type actAsResp struct {
	CloneHum  string `json:"clone_hum"`
	TargetHum string `json:"target"`
	ExpiresAt string `json:"expires_at"`
}

// startActAs is POST /api/v1/auth/act-as {"human_id":"HUM-…"} — the admin
// starts acting as a member. It re-issues THIS browser's session cookie as the
// freshly-minted clone, replacing the admin's own (no admin token is kept).
func (h *Handler) startActAs(w http.ResponseWriter, r *http.Request) {
	if h.imp == nil {
		writeErr(w, http.StatusNotFound, "not_found", "act-as is not enabled")
		return
	}
	s, tenant, err := h.ActiveTenant(r, "")
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no active tenant")
		return
	}
	if s.HumanID == "" {
		writeErr(w, http.StatusConflict, "no_human", "this session has no registered human")
		return
	}
	var req actAsReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	if req.HumanID == "" {
		writeErr(w, http.StatusBadRequest, "bad_target", "human_id is required")
		return
	}
	res, err := h.imp.StartActAs(r.Context(), tenant, s.HumanID, s.Name, req.HumanID)
	switch {
	case errors.Is(err, ErrActAsForbidden):
		writeErr(w, http.StatusForbidden, "forbidden", "your role does not grant members.impersonate")
		return
	case errors.Is(err, ErrActAsNotMember):
		writeErr(w, http.StatusForbidden, "not_member", "not a member of this tenant")
		return
	case errors.Is(err, ErrActAsCeiling):
		writeErr(w, http.StatusForbidden, "forbidden", "you may only act as a member below your own role")
		return
	case err != nil:
		h.log.Error().Err(err).Str("admin", s.HumanID).Str("tenant", tenant).Msg("auth.act_as_start")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "act-as")
		return
	}
	clone := Session{V: 1, Provider: ProviderActAs, Subject: res.CloneHum, HumanID: res.CloneHum, Tenant: tenant,
		IssuedAt: h.now().Unix(), Exp: res.ExpiresAt.Unix()}
	tok, err := signToken(h.sessionKey, clone)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "sign session")
		return
	}
	maxAge := max(int(res.ExpiresAt.Sub(h.now()).Seconds()), 1)
	http.SetCookie(w, h.sessionCookie(tok, maxAge))
	h.log.Info().Str("admin", s.HumanID).Str("target", res.TargetHum).Str("clone", res.CloneHum).
		Str("tenant", tenant).Msg("auth.act_as_start")
	writeJSON(w, http.StatusOK, actAsResp{CloneHum: res.CloneHum, TargetHum: res.TargetHum,
		ExpiresAt: res.ExpiresAt.UTC().Format(time.RFC3339)})
}

// stopActAs is POST /api/v1/auth/act-as/exit — "Stop acting as X". It is a
// SIGN-OUT (owner's rule): it ends the clone, clears the session cookie, and
// the WUI then lands on the regular login page. It refuses a non-clone session
// so a normal user's stray call cannot silently log them out.
func (h *Handler) stopActAs(w http.ResponseWriter, r *http.Request) {
	if h.imp == nil {
		writeErr(w, http.StatusNotFound, "not_found", "act-as is not enabled")
		return
	}
	s, ok := h.SessionFromRequest(r)
	if !ok || s.HumanID == "" {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no valid session")
		return
	}
	tenant := s.Tenant
	isClone, err := h.imp.IsClone(r.Context(), tenant, s.HumanID)
	if err != nil {
		h.log.Error().Err(err).Str("clone", s.HumanID).Msg("auth.act_as_stop is_clone")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "act-as")
		return
	}
	if !isClone {
		writeErr(w, http.StatusConflict, "not_acting", "this session is not acting as a member")
		return
	}
	if err := h.imp.StopActAs(r.Context(), tenant, s.HumanID); err != nil {
		h.log.Error().Err(err).Str("clone", s.HumanID).Msg("auth.act_as_stop")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "act-as")
		return
	}
	http.SetCookie(w, h.sessionCookie("", -1))
	h.log.Info().Str("clone", s.HumanID).Str("tenant", tenant).Msg("auth.act_as_stop")
	w.WriteHeader(http.StatusNoContent)
}
