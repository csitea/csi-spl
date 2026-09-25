package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// BoxOperators is rdb 0040: which tenant member operates which box's
// terminals (specs/036 FR-010). The hub reads it to accept a send frame's
// typed_by; only a tenant owner / admin (the orc grant action) writes it,
// never a box.
type BoxOperators interface {
	// BoxOperatorBound reports whether (tenant, box, human) is bound.
	BoxOperatorBound(ctx context.Context, tenantID, boxID, humanID string) (bool, error)
	// GrantBoxOperator binds human to box. A second grant is a no-op.
	// ErrNotFound when human is not a member of the tenant.
	GrantBoxOperator(ctx context.Context, tenantID, boxID, humanID, grantedBy string, now time.Time) error
	// RevokeBoxOperator drops the binding; revoking an absent one is a no-op.
	RevokeBoxOperator(ctx context.Context, tenantID, boxID, humanID string) error
}

// ---- Memory driver -----------------------------------------------------------

func (s *Memory) BoxOperatorBound(_ context.Context, tenant, box, human string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if _, member := s.hum.members[[2]string{tenant, human}]; !member {
		return false, nil // the FK cascade: a removed member is never bound
	}
	_, ok := s.operators[[3]string{tenant, box, human}]
	return ok, nil
}

func (s *Memory) GrantBoxOperator(_ context.Context, tenant, box, human, _ string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if _, member := s.hum.members[[2]string{tenant, human}]; !member {
		return ErrNotFound
	}
	if s.operators == nil {
		s.operators = map[[3]string]time.Time{}
	}
	k := [3]string{tenant, box, human}
	if _, ok := s.operators[k]; !ok {
		s.operators[k] = now
	}
	return nil
}

func (s *Memory) RevokeBoxOperator(_ context.Context, tenant, box, human string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.operators, [3]string{tenant, box, human})
	return nil
}

// ---- Postgres driver ---------------------------------------------------------
//
// Every statement runs in the tenant scope (0040 RLS).

func (s *Postgres) BoxOperatorBound(ctx context.Context, tenant, box, human string) (bool, error) {
	var one int
	err := s.queryRowTenant(ctx, tenant, `SELECT 1 FROM box_operators
		WHERE tenant_id = $1 AND box_id = $2 AND human_id = $3`, []any{tenant, box, human}, &one)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (s *Postgres) GrantBoxOperator(ctx context.Context, tenant, box, human, grantedBy string, now time.Time) error {
	_, err := s.execTenant(ctx, tenant, `INSERT INTO box_operators (tenant_id, box_id, human_id, granted_by, granted_at)
		VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING`, tenant, box, human, grantedBy, now)
	return mapFK(err) // 23503: not a member of the tenant
}

func (s *Postgres) RevokeBoxOperator(ctx context.Context, tenant, box, human string) error {
	_, err := s.execTenant(ctx, tenant, `DELETE FROM box_operators
		WHERE tenant_id = $1 AND box_id = $2 AND human_id = $3`, tenant, box, human)
	return err
}
