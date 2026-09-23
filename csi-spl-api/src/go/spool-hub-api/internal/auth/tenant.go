package auth

import (
	"context"
	"errors"
	"net/http"
)

// The active tenant (specs/026 §3). The session's `t` claim is the tenant
// the human works in: bound at sign-in (the ?tenant= of the flow, else the
// only membership), re-checked against membership on every request. It is a
// selection, never an authorisation (010 SEC-001): Membership decides.

// TenantRole is one of a human's memberships.
type TenantRole struct {
	TenantID string `json:"tenant_id"`
	Role     string `json:"role"`
}

// TenantLister lists every tenant a human belongs to. Optional: a Membership
// that also implements it lets a session without `t` resolve to the sole
// membership, and fills GET session's `tenants`.
type TenantLister interface {
	Tenants(ctx context.Context, humanID string) ([]TenantRole, error)
}

// Errors from ActiveTenant beyond the SessionForTenant ones.
var (
	// ErrTenantRequired: several memberships and no bound `t` (409; the
	// phase 2 switcher, specs/026 §6, resolves it without a new sign-in).
	ErrTenantRequired = errors.New("auth: session has several tenants and none is active")
	// ErrTenantMismatch: a legacy tenant Host names another tenant than the
	// session resolves to (403).
	ErrTenantMismatch = errors.New("auth: host tenant differs from the session's tenant")
)

// ActiveTenant resolves the tenant of a human request: `t` while still a
// member, else the only membership, else hostTenant when the human is a member
// of it (a legacy tenant host, specs/026 §5), else ErrTenantRequired /
// ErrNotMember. A non-empty hostTenant must then EQUAL the result, or
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
	return "", ErrTenantRequired
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
