package store

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// InviteFinder answers which workspaces a provider-verified address holds a
// LIVE invite to (pending, not expired), newest first (SPL-1230). A sign-in
// that named no tenant lands in the newest one instead of nowhere, so an
// invitee who opens the plain sign-in page (not the mailed link) still ends up
// in the workspace that invited them. Memory and Postgres implement it.
type InviteFinder interface {
	LiveInviteTenants(ctx context.Context, email string, now time.Time) ([]string, error)
}

var (
	_ InviteFinder = (*Postgres)(nil)
	_ InviteFinder = (*Memory)(nil)
)

// LiveInviteTenants reads across tenants, so it runs under the operator scope
// (TestOperatorScopeCallers): keyed by the SESSION's own provider-verified
// address, it only ever names workspaces that invited that address.
func (s *Postgres) LiveInviteTenants(ctx context.Context, email string, now time.Time) ([]string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" {
		return nil, nil
	}
	var out []string
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT i.tenant_id FROM tenant_invites i
			JOIN tenants t ON t.tenant_id = i.tenant_id
			WHERE i.email = $1 AND i.accepted_at IS NULL AND i.expires_at > $2
			ORDER BY i.created_at DESC, i.tenant_id`, email, now)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var t string
			if err := rows.Scan(&t); err != nil {
				return err
			}
			out = append(out, t)
		}
		return rows.Err()
	})
	return out, err
}

func (s *Memory) LiveInviteTenants(_ context.Context, email string, now time.Time) ([]string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" {
		return nil, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	type hit struct {
		tenant string
		at     time.Time
	}
	var hits []hit
	for k, i := range s.hum.invites {
		if k[1] != email || i.accepted || !now.Before(i.ExpiresAt) {
			continue
		}
		if _, ok := s.tenants[k[0]]; !ok {
			continue
		}
		hits = append(hits, hit{k[0], i.createdAt})
	}
	sort.Slice(hits, func(a, b int) bool {
		if !hits[a].at.Equal(hits[b].at) {
			return hits[a].at.After(hits[b].at)
		}
		return hits[a].tenant < hits[b].tenant
	})
	out := make([]string, 0, len(hits))
	for _, h := range hits {
		out = append(out, h.tenant)
	}
	return out, nil
}
