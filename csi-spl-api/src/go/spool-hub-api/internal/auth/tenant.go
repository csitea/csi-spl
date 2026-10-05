package auth

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
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
	// Settings is the per-tenant settings override jsonb (rdb 0078), raw and
	// internal (never serialised): GET /session overlays the active tenant's
	// from this list, which it already reads, so no extra round trip (CLE-35099).
	Settings []byte `json:"-"`
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
	// ErrPageNotMember: the WUI page's tenant host (SPL-959, Options.PageTenant)
	// names a tenant the human is not a member of (403 not_member).
	ErrPageNotMember = errors.New("auth: not a member of the page's tenant")
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
	// SPL-959: a WUI page on a tenant host (or the apex) IS that tenant, per
	// request, whatever `t` says: two tabs on two hosts never cross. It is a
	// selection like `t`: membership still decides.
	if page := h.pageTenantOf(r); page != "" {
		ok, err := h.members.Member(ctx, s.HumanID, page)
		if err != nil {
			return Session{}, "", err
		}
		if !ok {
			return Session{}, "", ErrPageNotMember
		}
		if hostTenant != "" && hostTenant != page {
			return Session{}, "", ErrTenantMismatch
		}
		s.Tenant = page
		return s, page, nil
	}
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
	ts, err := h.seats(ctx, tl, humanID)
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

// MemberTenants lists the signed-in human of r and every tenant they belong
// to (SPL-959 locate), or ErrNoSession / ErrNoHuman / ErrNoMembership.
func (h *Handler) MemberTenants(r *http.Request) (Session, []TenantRole, error) {
	s, ok := h.SessionFromRequest(r)
	if !ok {
		return Session{}, nil, ErrNoSession
	}
	if s.HumanID == "" {
		return Session{}, nil, ErrNoHuman
	}
	tl, _ := h.members.(TenantLister)
	if tl == nil {
		return Session{}, nil, ErrNoMembership
	}
	ts, err := h.seats(r.Context(), tl, s.HumanID)
	return s, ts, err
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
	member, err := h.switchable(ctx, s.HumanID, req.Tenant)
	if err != nil {
		h.log.Error().Err(err).Msg("auth.tenant_switch membership")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "membership")
		return
	}
	if !member { // the same answer for an unknown tenant or a fenced demo seat: no tenant is revealed
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
	// The answer is what GET session would say with the new cookie. This is a
	// REQUEST cookie read back internally by h.session, not a Set-Cookie sent to
	// the browser (that already went out at sessionCookie above with HttpOnly +
	// Secure) -- Secure/HttpOnly have no meaning on a Cookie request header, so
	// set the header directly rather than build an http.Cookie the SAST rules
	// (cookie-missing-secure / -httponly) then flag as an insecure Set-Cookie.
	// SPL-1285/1287.
	r2 := r.Clone(ctx)
	r2.Header = r.Header.Clone()
	r2.Header.Set("Cookie", h.cfg.CookieName+"="+tok)
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
	if ts, err := h.seats(ctx, tl, s.HumanID); err == nil && len(ts) == 1 {
		s.Tenant = ts[0].TenantID
	}
}

// memberRoles reads the human's memberships (rdb 0078 carries each tenant's
// settings override on the row); nil on no human, no store, or a read error.
// GET /session reads them once and reuses them for the tenants list AND the
// per-tenant settings overlay (CLE-35099), so the overlay costs no round trip.
func (h *Handler) memberRoles(ctx context.Context, s Session) []TenantRole {
	if s.HumanID == "" || h.members == nil {
		return nil
	}
	tl, ok := h.members.(TenantLister)
	if !ok {
		return nil
	}
	roles, err := h.seats(ctx, tl, s.HumanID)
	if err != nil {
		h.log.Warn().Err(err).Msg("auth.session tenants")
		return nil
	}
	return roles
}

// sessionTenants fills GET session's active_tenant + tenants (specs/026 §3)
// from the memberships GET /session already read. Errors leave them null /
// empty: the session answer never fails on them.
func (h *Handler) sessionTenants(r *http.Request, out *sessionResp, roles []TenantRole) {
	out.Tenants = []TenantRole{}
	if out.HumanID == "" || h.members == nil {
		return
	}
	if roles != nil {
		out.Tenants = roles
	}
	// A `t` or page host naming a fenced demo seat is no active tenant either.
	if _, t, err := h.ActiveTenant(r, ""); err == nil && (roles == nil || listed(roles, t)) {
		out.ActiveTenant = &t
	}
}

// Fenced demo seats (specs/077 §3.8, T015). A demo_user seat outside the open
// demo workspace (the demo id changed, or the demo is off) is no membership to
// the hub (demoFenced); auth names its tenant nowhere either: not in GET
// session's tenants, not as its active_tenant, not as a switch target, not as
// a fallback or bound tenant.

// fenced reports whether t is a demo_user seat outside the open demo workspace.
func (h *Handler) fenced(t TenantRole) bool {
	return t.Role == rbac.DemoUser && (h.demoWS == "" || t.TenantID != h.demoWS)
}

// seats lists the human's memberships without the fenced demo seats.
func (h *Handler) seats(ctx context.Context, tl TenantLister, humanID string) ([]TenantRole, error) {
	ts, err := tl.Tenants(ctx, humanID)
	if err != nil {
		return nil, err
	}
	out := make([]TenantRole, 0, len(ts))
	for _, t := range ts {
		if !h.fenced(t) {
			out = append(out, t)
		}
	}
	return out, nil
}

// switchable reports whether the human may switch into tenant: a member, and
// not through a fenced demo seat. Without a lister there is no role to read,
// and Membership alone decides.
func (h *Handler) switchable(ctx context.Context, humanID, tenant string) (bool, error) {
	ok, err := h.members.Member(ctx, humanID, tenant)
	if err != nil || !ok {
		return false, err
	}
	tl, _ := h.members.(TenantLister)
	if tl == nil {
		return true, nil
	}
	ts, err := h.seats(ctx, tl, humanID)
	if err != nil {
		return false, err
	}
	return listed(ts, tenant), nil
}

// listed reports whether tenant is one of ts.
func listed(ts []TenantRole, tenant string) bool {
	for _, t := range ts {
		if t.TenantID == tenant {
			return true
		}
	}
	return false
}

// requestTenant is a CHEAP tenant guess for the per-tenant settings overlay
// (rdb 0078): the SPL-959 page host, else the session `t` claim — both from the
// request, no membership round trip. It is not authorization: a wrong guess
// (a tenant the human is not a member of) yields no override, so the read falls
// back to the global. The validated active tenant (for the claim and for a
// preferences WRITE) is ActiveTenant.
func (h *Handler) requestTenant(r *http.Request, s Session) string {
	if p := h.pageTenantOf(r); p != "" {
		return p
	}
	return s.Tenant
}

// pageTenantOf is the tenant the request's WUI page host names (SPL-959), ""
// when tenant hosts are off or the request names none (a box, curl, lde).
func (h *Handler) pageTenantOf(r *http.Request) string {
	if h.pageTenant == nil {
		return ""
	}
	if t := h.pageTenant(r); validTenant(t) {
		return t
	}
	return ""
}
