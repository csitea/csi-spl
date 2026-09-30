package hub

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// clonesLister reads a tenant's act-as audit trail (specs/054 §7).
type clonesLister interface {
	ListClones(ctx context.Context, tenant string) ([]store.Clone, error)
}

// cloneReader reads one clone (to tell a clone session apart, specs/054).
type cloneReader interface {
	Clone(ctx context.Context, tenant, clone string) (store.Clone, error)
}

// readerIsActAsClone reports whether hum is a LIVE act-as clone of tenant. The
// owner's rule (18597eaa: "no of course"): a clone sees only the person's
// channels and issues, NEVER their DMs, so every DM endpoint refuses it. This
// is store-based (a live member_clones row), not session-based, so it holds
// however the session was formed — including the hub's own read door.
func (s *Server) readerIsActAsClone(ctx context.Context, tenant, hum string) bool {
	if hum == "" {
		return false
	}
	cr, ok := s.o.Store.(cloneReader)
	if !ok {
		return false
	}
	c, err := cr.Clone(ctx, tenant, hum)
	return err == nil && c.EndedAt == nil
}

// actAsMe is the act-as banner state for GET /v1/view/me: non-nil only when hum
// is a LIVE clone of tenant. A store without clone support, a non-clone, or an
// ended clone all yield nil (no banner).
func (s *Server) actAsMe(ctx context.Context, tenant, hum string) *actAsMe {
	cr, ok := s.o.Store.(cloneReader)
	if !ok {
		return nil
	}
	c, err := cr.Clone(ctx, tenant, hum)
	if err != nil || c.EndedAt != nil {
		return nil
	}
	name := c.TargetName
	if name == "" {
		name = c.TargetHum
	}
	return &actAsMe{TargetHum: c.TargetHum, TargetName: name, ExpiresAt: c.ExpiresAt.UTC().Format(time.RFC3339)}
}

// cloneAudit is one row of GET /v1/audit/clones.
type cloneAudit struct {
	CloneHum  string  `json:"clone_hum"`
	TargetHum string  `json:"target_hum"`
	CreatedBy string  `json:"created_by"`
	Role      string  `json:"role"`
	CreatedAt string  `json:"created_at"`
	ExpiresAt string  `json:"expires_at"`
	EndedAt   *string `json:"ended_at"`
	EndReason string  `json:"end_reason,omitempty"`
}

// handleAuditClones is GET /v1/audit/clones — the tenant's act-as trail (who
// acted as whom, when, until when, how it ended), behind the audit.read
// permission (specs/054 §7).
func (s *Server) handleAuditClones(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if !s.permit(w, r, t.ID, hum, rbac.AuditRead) {
		return
	}
	lister, ok := s.o.Store.(clonesLister)
	if !ok {
		writeJSON(w, http.StatusOK, []cloneAudit{})
		return
	}
	rows, err := lister.ListClones(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "audit")
		return
	}
	out := make([]cloneAudit, 0, len(rows))
	for _, c := range rows {
		a := cloneAudit{CloneHum: c.CloneHum, TargetHum: c.TargetHum, CreatedBy: c.CreatedBy, Role: c.Role,
			CreatedAt: c.CreatedAt.UTC().Format(time.RFC3339), ExpiresAt: c.ExpiresAt.UTC().Format(time.RFC3339),
			EndReason: c.EndReason}
		if c.EndedAt != nil {
			e := c.EndedAt.UTC().Format(time.RFC3339)
			a.EndedAt = &e
		}
		out = append(out, a)
	}
	writeJSON(w, http.StatusOK, out)
}

// DefaultActAsTTL is how long an act-as clone lives before the sweeper expires
// it (specs/054 §8 Q3, owner recommendation 60 min). Kept a var so a deploy
// could tune it without a schema change.
var DefaultActAsTTL = time.Hour

// cloneSweeper expires act-as clones past their TTL (specs/054 §5). *store.Postgres
// satisfies it; the memory store does not.
type cloneSweeper interface {
	SweepClones(ctx context.Context, now time.Time) (int, error)
}

// sweepClones expires every clone past its TTL, on the same tick as the
// retention sweep. A store without clone support is a no-op.
func (s *Server) sweepClones(ctx context.Context) {
	cs, ok := s.o.Store.(cloneSweeper)
	if !ok {
		return
	}
	n, err := cs.SweepClones(ctx, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("act-as clone sweep")
		return
	}
	if n > 0 {
		s.o.Log.Info().Int("expired", n).Msg("act-as clone sweep")
	}
}

// CloneStore is the slice of the store the act-as adapter needs. *store.Postgres
// satisfies it; the memory store does not, so act-as is off under it.
type CloneStore interface {
	StartClone(ctx context.Context, in store.CloneStart, now time.Time) (store.Clone, error)
	StopClone(ctx context.Context, tenant, clone, reason string, now time.Time) error
	Clone(ctx context.Context, tenant, clone string) (store.Clone, error)
}

// actAs implements auth.Impersonation: it enforces the members.impersonate
// permission and the role ceiling through the Authorizer, then drives the clone
// store (specs/054). The enforcement is here, server-side, never in the WUI.
type actAs struct {
	clones CloneStore
	authz  Authorizer
	ttl    time.Duration
	now    func() time.Time
}

// NewActAs builds the adapter for auth.Options.Impersonation, or returns nil
// when the store cannot clone (the memory store) — in which case the act-as
// routes are simply not mounted.
func NewActAs(st store.Store, ttl time.Duration, now func() time.Time) auth.Impersonation {
	cs, ok := st.(CloneStore)
	if !ok {
		return nil
	}
	authz := defaultAuthorizer(st)
	if authz == nil {
		return nil
	}
	if ttl <= 0 {
		ttl = DefaultActAsTTL
	}
	if now == nil {
		now = time.Now
	}
	return &actAs{clones: cs, authz: authz, ttl: ttl, now: now}
}

// StartActAs checks the permission and the ceiling, then mints the clone.
func (a *actAs) StartActAs(ctx context.Context, tenant, admin, adminName, target string) (auth.ActAsResult, error) {
	adminAcc, err := a.authz.Access(ctx, admin, tenant)
	if err != nil {
		return auth.ActAsResult{}, err
	}
	if !adminAcc.Can(rbac.MembersImpersonate) {
		return auth.ActAsResult{}, auth.ErrActAsForbidden
	}
	if target == admin {
		return auth.ActAsResult{}, auth.ErrActAsCeiling
	}
	targetAcc, err := a.authz.Access(ctx, target, tenant)
	if err != nil {
		if errors.Is(err, rbac.ErrNotMember) || errors.Is(err, store.ErrNotFound) {
			return auth.ActAsResult{}, auth.ErrActAsNotMember
		}
		return auth.ActAsResult{}, err
	}
	if targetAcc.Role == "" {
		return auth.ActAsResult{}, auth.ErrActAsNotMember
	}
	// The ceiling: the admin must strictly outrank the target — cover every
	// permission the target holds, and hold at least one the target does not.
	// So an admin can act as a developer or tester, never a peer admin, never
	// the owner (who holds billing the admin lacks).
	if targetAcc.TenantOwner || !adminAcc.CoversAccess(targetAcc) || targetAcc.CoversAccess(adminAcc) {
		return auth.ActAsResult{}, auth.ErrActAsCeiling
	}
	now := a.now()
	cl, err := a.clones.StartClone(ctx, store.CloneStart{TenantID: tenant, TargetHum: target,
		AdminName: adminName, CreatedBy: admin, ExpiresAt: now.Add(a.ttl)}, now)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return auth.ActAsResult{}, auth.ErrActAsNotMember
		}
		return auth.ActAsResult{}, err
	}
	return auth.ActAsResult{CloneHum: cl.CloneHum, TargetHum: target, ExpiresAt: cl.ExpiresAt}, nil
}

// StopActAs ends the clone (the sign-out). An already-ended clone is not an
// error — the sign-out still clears the cookie.
func (a *actAs) StopActAs(ctx context.Context, tenant, clone string) error {
	err := a.clones.StopClone(ctx, tenant, clone, "stop", a.now())
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	return err
}

// IsClone reports whether human is a LIVE clone of tenant (ended clones are not).
func (a *actAs) IsClone(ctx context.Context, tenant, human string) (bool, error) {
	c, err := a.clones.Clone(ctx, tenant, human)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return c.EndedAt == nil, nil
}
