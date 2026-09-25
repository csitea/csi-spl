package store

import (
	"context"
	"sort"

	"github.com/jackc/pgx/v5"
)

// Membership is one tenant a human belongs to (rdb 0006 tenant_memberships).
type Membership struct {
	TenantID    string `json:"tenant_id"`
	Role        string `json:"role"`
	DisplayName string `json:"display_name,omitempty"`
}

// MembershipLister lists every tenant a human belongs to (specs/026 §3: the
// active tenant of a session without one, and the session's `tenants`). It
// spans tenants by design, like sign-in, and is keyed by the HUM-* of a signed
// session only. A disabled or unknown human has none. Sorted by tenant id.
type MembershipLister interface {
	Memberships(ctx context.Context, humanID string) ([]Membership, error)
}

var (
	_ MembershipLister = (*Memory)(nil)
	_ MembershipLister = (*Postgres)(nil)
)

func (s *Memory) Memberships(_ context.Context, humanID string) ([]Membership, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if hm, ok := s.hum.humans[humanID]; !ok || hm.disabled {
		return nil, nil
	}
	var out []Membership
	for k, m := range s.hum.members {
		if k[1] == humanID {
			name := ""
			if t, ok := s.tenants[k[0]]; ok {
				name = t.DisplayName
			}
			out = append(out, Membership{TenantID: k[0], Role: m.role, DisplayName: name})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].TenantID < out[j].TenantID })
	return out, nil
}

// Memberships reads under the operator scope: tenant_memberships is FORCE
// RLS (rdb 0014) and this read crosses tenants on purpose.
func (s *Postgres) Memberships(ctx context.Context, humanID string) ([]Membership, error) {
	var out []Membership
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT m.tenant_id, m.role, COALESCE(tn.display_name, '')
			FROM tenant_memberships m
			JOIN humans h ON h.human_id = m.human_id
			JOIN tenants tn ON tn.tenant_id = m.tenant_id
			WHERE m.human_id = $1 AND h.disabled_at IS NULL ORDER BY m.tenant_id`, humanID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var m Membership
			if err := rows.Scan(&m.TenantID, &m.Role, &m.DisplayName); err != nil {
				return err
			}
			out = append(out, m)
		}
		return rows.Err()
	})
	return out, err
}
