package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of seats.go (rdb 0012).

func nullTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	u := t.UTC()
	return &u
}

// botSeatGate runs inside SetRoster's transaction, before the replace. The
// tenant row lock (NO KEY UPDATE: it does not block the FK KEY SHARE locks
// of concurrent message inserts) serialises two hellos racing for the last
// bot seat. A cap of 0 (M4 off) takes no count.
func (s *Postgres) botSeatGate(ctx context.Context, tx pgx.Tx, tenant, box string, agents []string) error {
	var capBots int
	err := tx.QueryRow(ctx, `SELECT seats_bots FROM tenants WHERE tenant_id = $1 FOR NO KEY UPDATE`,
		tenant).Scan(&capBots)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil || capBots == 0 {
		return err
	}
	var bots int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM roster WHERE tenant_id = $1 AND agent_id NOT LIKE 'HUM-%'`,
		tenant).Scan(&bots); err != nil {
		return err
	}
	rows, err := tx.Query(ctx, `SELECT agent_id FROM roster WHERE tenant_id = $1 AND box_id = $2`, tenant, box)
	if err != nil {
		return err
	}
	old, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	if overBotCap(capBots, bots, old, agents) {
		return ErrSeatQuota
	}
	return nil
}

func (s *Postgres) CountMembers(ctx context.Context, tenant string) (int, error) {
	var n int
	err := s.queryRowTenant(ctx, tenant, `SELECT count(*) FROM tenant_memberships m
		JOIN humans h ON h.human_id = m.human_id
		WHERE m.tenant_id = $1 AND NOT h.technical`, []any{tenant}, &n)
	return n, err
}

func (s *Postgres) CountBots(ctx context.Context, tenant string) (int, error) {
	var n int
	err := s.queryRowTenant(ctx, tenant, `SELECT count(*) FROM roster WHERE tenant_id = $1 AND agent_id NOT LIKE 'HUM-%'`,
		[]any{tenant}, &n)
	return n, err
}

func (s *Postgres) SetSeatCaps(ctx context.Context, tenant string, users, bots int) error {
	defer s.hot.forget()
	if err := checkSeatCaps(users, bots); err != nil {
		return err
	}
	tag, err := s.execTenant(ctx, tenant, `UPDATE tenants SET seats_users = $2, seats_bots = $3 WHERE tenant_id = $1`,
		tenant, users, bots)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) SetBuyStamp(ctx context.Context, tenant, org, app, projectID string, boughtAt time.Time) error {
	defer s.hot.forget()
	if err := checkBuyStamp(org, app, projectID); err != nil {
		return err
	}
	tag, err := s.execTenant(ctx, tenant, `UPDATE tenants SET org = NULLIF($2, ''), app = NULLIF($3, ''),
		project_id = NULLIF($4, ''), bought_at = $5 WHERE tenant_id = $1`,
		tenant, org, app, projectID, nullTime(boughtAt))
	if isUniqueViolation(err) {
		return ErrConflict
	}
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
