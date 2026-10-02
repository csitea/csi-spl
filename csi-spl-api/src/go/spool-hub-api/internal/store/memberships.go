package store

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Membership is one tenant a human belongs to (rdb 0006 tenant_memberships).
type Membership struct {
	TenantID    string `json:"tenant_id"`
	Role        string `json:"role"`
	DisplayName string `json:"display_name,omitempty"`
	// LastActiveAt is when the human last switched into this tenant (rdb
	// 0044, specs/026 §6); nil = never.
	LastActiveAt *time.Time `json:"last_active_at,omitempty"`
	// SortOrder is the tenant's place in the drop box (rdb 0049); 0 = unset.
	SortOrder int `json:"-"`
	// Settings is the per-tenant settings override jsonb (rdb 0078), raw; nil
	// when none. It rides this list so GET /session overlays it with no extra
	// round trip (CLE-35099): the tenants list is already read there.
	Settings []byte `json:"-"`
}

// MembershipLister lists every tenant a human belongs to (specs/026 §3: the
// active tenant of a session without one, and the session's `tenants`). It
// spans tenants by design, like sign-in, and is keyed by the HUM-* of a signed
// session only. A disabled or unknown human has none. Sorted by the tenant's
// sort_order (rdb 0049, SPL-71), unset last, then by tenant id: the WUI
// drop box draws them in this order.
type MembershipLister interface {
	Memberships(ctx context.Context, humanID string) ([]Membership, error)
}

// MembershipToucher stamps a membership's last_active_at (specs/026 §6, the
// workspace switcher). ErrNotFound when there is no such membership. The
// caller checks membership first (auth: Member, which refuses a disabled
// human); the Memory store also refuses one.
type MembershipToucher interface {
	TouchMembership(ctx context.Context, humanID, tenant string, at time.Time) error
}

var (
	_ MembershipLister  = (*Memory)(nil)
	_ MembershipLister  = (*Postgres)(nil)
	_ MembershipToucher = (*Memory)(nil)
	_ MembershipToucher = (*Postgres)(nil)
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
		if k[1] == humanID && !m.disabled {
			ms := Membership{TenantID: k[0], Role: m.role}
			if t, ok := s.tenants[k[0]]; ok {
				ms.DisplayName, ms.SortOrder = t.DisplayName, t.SortOrder
			}
			if !m.lastActive.IsZero() {
				at := m.lastActive
				ms.LastActiveAt = &at
			}
			if len(m.settings) > 0 {
				obj := make(map[string]json.RawMessage, len(m.settings))
				for sk, sv := range m.settings {
					obj[sk] = sv
				}
				if b, err := json.Marshal(obj); err == nil {
					ms.Settings = b
				}
			}
			out = append(out, ms)
		}
	}
	sort.Slice(out, func(i, j int) bool { return membershipLess(out[i], out[j]) })
	return out, nil
}

// membershipLess is the drop box order: a set sort_order first, ascending,
// then the unset ones; ties by tenant id. Postgres orders the same way.
func membershipLess(a, b Membership) bool {
	if (a.SortOrder > 0) != (b.SortOrder > 0) {
		return a.SortOrder > 0
	}
	if a.SortOrder != b.SortOrder {
		return a.SortOrder < b.SortOrder
	}
	return a.TenantID < b.TenantID
}

// Memberships reads under the operator scope: tenant_memberships is FORCE
// RLS (rdb 0014) and this read crosses tenants on purpose.
//
// The per-tenant settings override (rdb 0078) rides this list so GET /session
// reads it with no extra round trip (CLE-35099). The list is CRITICAL (the
// tenant switcher, the active-tenant selection); the override is OPTIONAL. So a
// failure to read the settings column — most importantly `undefined_column`
// before 0078 is applied — falls back to the list WITHOUT the override rather
// than losing the whole list (the SPL-1179 tenant-dropdown regression: the code
// shipped before the migration, the failed column read emptied the list, and
// the switcher showed only the active tenant). The override then falls back to
// the humans-row global, as it does whenever a tenant has none.
func (s *Postgres) Memberships(ctx context.Context, humanID string) ([]Membership, error) {
	// The list is ONE batch (asOperatorQuery: scope + read, one round trip;
	// asOperator's BEGIN..COMMIT cost three more, db-payload audit cut 6). It
	// is the one operator-scoped read of this route (TestOperatorScopeCallers
	// keys the allow-list on the enclosing method). withSettings folds in the
	// rdb 0078 override; on undefined_column (0078 not applied) it retries
	// without it so the list survives (SPL-1179).
	var out []Membership
	err := s.asOperatorQuery(ctx, membershipsSQL(true), []any{humanID}, membershipRow(true, &out))
	if err != nil && isUndefinedColumn(err) {
		out = out[:0]
		err = s.asOperatorQuery(ctx, membershipsSQL(false), []any{humanID}, membershipRow(false, &out))
	}
	return out, err
}

// isUndefinedColumn reports a Postgres undefined_column error (SQLSTATE 42703),
// the shape of a read of a column a migration has not added yet.
func isUndefinedColumn(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "42703"
}

// membershipsSQL is the membership list of the human in $1; withSettings
// folds in the rdb 0078 override column (NULL otherwise).
func membershipsSQL(withSettings bool) string {
	settingsCol := "NULL::jsonb"
	if withSettings {
		settingsCol = "m.settings"
	}
	return `SELECT m.tenant_id, m.role, COALESCE(tn.display_name, ''), m.last_active_at,
		COALESCE(tn.sort_order, 0), ` + settingsCol + `
		FROM tenant_memberships m
		JOIN humans h ON h.human_id = m.human_id
		JOIN tenants tn ON tn.tenant_id = m.tenant_id
		WHERE m.human_id = $1 AND h.disabled_at IS NULL AND m.disabled_at IS NULL
		ORDER BY tn.sort_order NULLS LAST, m.tenant_id`
}

// membershipRow scans one membershipsSQL row into out (nil Settings unless
// withSettings).
func membershipRow(withSettings bool, out *[]Membership) func(pgx.Rows) error {
	return func(rows pgx.Rows) error {
		var m Membership
		var settings []byte
		if err := rows.Scan(&m.TenantID, &m.Role, &m.DisplayName, &m.LastActiveAt, &m.SortOrder, &settings); err != nil {
			return err
		}
		if withSettings {
			m.Settings = settings
		}
		*out = append(*out, m)
		return nil
	}
}

func (s *Memory) TouchMembership(_ context.Context, humanID, tenant string, at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if hm, ok := s.hum.humans[humanID]; !ok || hm.disabled {
		return ErrNotFound
	}
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	m.lastActive = at.UTC()
	s.hum.members[k] = m
	return nil
}

// TouchMembership writes one row of the tenant it names, so it runs in that
// tenant's scope (FORCE RLS, rdb 0014), not as the operator.
func (s *Postgres) TouchMembership(ctx context.Context, humanID, tenant string, at time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE tenant_memberships SET last_active_at = $3
			WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID, at.UTC())
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}
