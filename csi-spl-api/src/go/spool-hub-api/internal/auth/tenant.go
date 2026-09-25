package auth

import (
	"context"
	"errors"
	"net/http"
	"time"
)

// The active tenant (specs/026 §3). The session's `t` claim is the tenant
// the human works in: bound at sign-in (the ?tenant= of the flow, else the
// only membership), re-checked against membership on every request. It is a
// selection, never an authorisation (010 SEC-001): Membership decides.

// TenantRole is one of a human's memberships.
type TenantRole struct {
	TenantID    string `json:"tenant_id"`
	Role        string `json:"role"`
	DisplayName string `json:"display_name,omitempty"`
	// LastActiveAt is when the human last switched into this tenant
	// (specs/026 §6); nil = never.
	LastActiveAt *time.Time `json:"last_active_at,omitempty"`
}

// TenantToucher records the tenant a human switched into (specs/026 §6,
// "last used"). Optional: without it the switch still re-issues the cookie,
// and an unbound session with several memberships stays 409.
type TenantToucher interface {
	TouchTenant(ctx context.Context, humanID, tenant string) error
}

// TenantLister lists every tenant a human belongs to. Optional: a Membership
// that also implements it lets a session without `t` resolve to the sole
// membership, and fills GET session's `tenants`.
type TenantLister interface {
	Tenants(ctx context.Context, humanID string) ([]TenantRole, error)
}

// Errors from ActiveTenant beyond the SessionForTenant ones.
var (
	// ErrTenantRequired: several memberships, no bound `t` and none ever
	// switched into (409; POST /api/v1/auth/tenant, specs/026 §6, resolves
	// it without a new sign-in).
	ErrTenantRequired = errors.New("auth: session has several tenants and none is active")
	// ErrTenantMismatch: a legacy tenant Host names another tenant than the
	// session resolves to (403).
	ErrTenantMismatch = errors.New("auth: host tenant differs from the session's tenant")
)

// ActiveTenant resolves the tenant of a human request: `t` while still a
// member, else the only membership, else hostTenant when the human is a member
// of it (a legacy tenant host, specs/026 §5), else the membership switched
// into most recently (§6), else ErrTenantRequired / ErrNotMember. A non-empty hostTenant must then EQUAL the result, or
// ErrTenantMismatch. Every lookup error fails closed.
func (h *Handler) ActiveTenant(r *http.Request, hostTenant string) (Session, string, error) {
	s, ok := h.SessionFromRequest(r)
	if !ok {
		return Session{}, "", ErrNoSession
	}
	if s.HumanID == "" {
		return Session{}, "", ErrNoHuman
	}
	if h.members == nil {
		return Session{}, "", ErrNoMembership
	}
	ctx := r.Context()
	active := ""
	if validTenant(s.Tenant) {
		ok, err := h.members.Member(ctx, s.HumanID, s.Tenant)
		if err != nil {
			return Session{}, "", err
		}
		if ok {
			active = s.Tenant
		}
	}
	if active == "" {
		var err error
		if active, err = h.fallbackTenant(ctx, s.HumanID, hostTenant); err != nil {
			return Session{}, "", err
		}
	}
	if hostTenant != "" && hostTenant != active {
		return Session{}, "", ErrTenantMismatch
	}
	s.Tenant = active
	return s, active, nil
}

// fallbackTenant is the tenant of a session with no live `t` (none, or a
// stale one). A legacy Host never grants a tenant: a non-member still cannot
// get in. It picks among several memberships that human already has. A member
// of two tenants, with a stale `t`, is placed in the tenant the Host names.
// When the session already proves a tenant, the caller requires the Host to
// EQUAL it.
func (h *Handler) fallbackTenant(ctx context.Context, humanID, hostTenant string) (string, error) {
	tl, _ := h.members.(TenantLister)
	if tl == nil { // no lister: only a legacy Host can name the tenant
		if hostTenant == "" {
			return "", ErrTenantRequired
		}
		ok, err := h.members.Member(ctx, humanID, hostTenant)
		if err != nil {
			return "", err
		}
		if !ok {
			return "", ErrNotMember
		}
		return hostTenant, nil
	}
	ts, err := tl.Tenants(ctx, humanID)
	if err != nil {
		return "", err
	}
	switch len(ts) {
	case 0:
		return "", ErrNotMember
	case 1:
		return ts[0].TenantID, nil
	}
	for _, t := range ts {
		if hostTenant != "" && t.TenantID == hostTenant {
			return hostTenant, nil
		}
	}
	if last := lastActive(ts); last != "" { // specs/026 §6 "last used"
		return last, nil
	}
	return "", ErrTenantRequired
}

// lastActive is the membership with the newest LastActiveAt, "" when none
// was ever switched into. Ties keep the first (the lister sorts by id).
func lastActive(ts []TenantRole) string {
	id, at := "", time.Time{}
	for _, t := range ts {
		if t.LastActiveAt != nil && t.LastActiveAt.After(at) {
			id, at = t.TenantID, *t.LastActiveAt
		}
	}
	return id
}

// switchReq is POST /api/v1/auth/tenant's body.
type switchReq struct {
	Tenant string `json:"tenant"`
}

// switchTenant is POST /api/v1/auth/tenant {"tenant": "<id>"} (specs/026 §6):
// it re-issues the session cookie with `t=<id>` when the signed-in human is a
// member of <id>. It never extends the session: the new cookie keeps the old
// expiry. The membership's last_active_at is stamped (best effort), so a later
// session with no `t` lands here too. Idempotent. The answer is the session
// read (GET session) of the new cookie.
func (h *Handler) switchTenant(w http.ResponseWriter, r *http.Request) {
	s, ok := h.SessionFromRequest(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no valid session")
		return
	}
	var req switchReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	if !validTenant(req.Tenant) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "tenant must be a tenant id")
		return
	}
	if s.HumanID == "" {
		writeErr(w, http.StatusConflict, "no_human", "this session has no registered human")
		return
	}
	if h.members == nil {
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "membership")
		return
	}
	ctx := r.Context()
	member, err := h.members.Member(ctx, s.HumanID, req.Tenant)
	if err != nil {
		h.log.Error().Err(err).Msg("auth.tenant_switch membership")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "membership")
		return
	}
	if !member { // the same answer for an unknown tenant: no tenant is revealed
		h.log.Warn().Str("hum", s.HumanID).Str("tenant", req.Tenant).Msg("auth.tenant_switch_refused")
		writeErr(w, http.StatusForbidden, "not_member", "not a member of that tenant")
		return
	}
	from := s.Tenant
	s.Tenant = req.Tenant
	tok, err := signToken(h.sessionKey, s)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "sign session")
		return
	}
	if tt, ok := h.members.(TenantToucher); ok {
		if err := tt.TouchTenant(ctx, s.HumanID, req.Tenant); err != nil {
			h.log.Warn().Err(err).Msg("auth.tenant_switch touch (non-fatal)")
		}
	}
	maxAge := int(time.Unix(s.Exp, 0).Sub(h.now()).Seconds())
	if maxAge < 1 {
		maxAge = 1
	}
	http.SetCookie(w, h.sessionCookie(tok, maxAge))
	h.log.Info().Str("hum", s.HumanID).Str("from", from).Str("tenant", req.Tenant).Msg("auth.tenant_switch")
	// The answer is what GET session would say with the new cookie.
	r2 := r.Clone(ctx)
	r2.Header = r.Header.Clone()
	r2.Header.Del("Cookie")
	r2.AddCookie(&http.Cookie{Name: h.cfg.CookieName, Value: tok})
	h.session(w, r2)
}

// bindTenant sets the `t` of a new session that names none: the human's only
// membership (specs/026 §3). A lookup error leaves `t` empty; the request-time
// resolution then decides.
func (h *Handler) bindTenant(ctx context.Context, s *Session) {
	if s.Tenant != "" || s.HumanID == "" {
		return
	}
	tl, _ := h.members.(TenantLister)
	if tl == nil {
		return
	}
	if ts, err := tl.Tenants(ctx, s.HumanID); err == nil && len(ts) == 1 {
		s.Tenant = ts[0].TenantID
	}
}

// sessionTenants fills GET session's active_tenant + tenants (specs/026 §3).
// Errors leave them null / empty: the session answer never fails on them.
func (h *Handler) sessionTenants(r *http.Request, out *sessionResp) {
	out.Tenants = []TenantRole{}
	if out.HumanID == "" || h.members == nil {
		return
	}
	if tl, ok := h.members.(TenantLister); ok {
		if ts, err := tl.Tenants(r.Context(), out.HumanID); err == nil && ts != nil {
			out.Tenants = ts
		}
	}
	if _, t, err := h.ActiveTenant(r, ""); err == nil {
		out.ActiveTenant = &t
	}
}
