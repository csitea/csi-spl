package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0127. The take is one statement: the upsert's row lock
// orders two takes racing on the same counter, and the WHERE of DO UPDATE
// refuses the one past the limit without writing (no row comes back).
const takeQuotaSQL = `INSERT INTO quota_counts (tenant_id, human_id, kind, window_start, n)
	VALUES ($1, $2, $3, $4, 1)
	ON CONFLICT (tenant_id, human_id, kind, window_start)
	DO UPDATE SET n = quota_counts.n + 1 WHERE quota_counts.n < $5
	RETURNING n`

func (s *Postgres) TakeQuota(ctx context.Context, tenant, human, kind string, window time.Time, limit int) (int, bool, error) {
	if err := checkQuota(tenant, human, kind); err != nil {
		return 0, false, err
	}
	if limit < 1 {
		return 0, false, nil
	}
	var n int
	err := s.queryRowTenant(ctx, tenant, takeQuotaSQL,
		[]any{tenant, human, kind, window.UTC(), limit}, &n)
	if errors.Is(err, pgx.ErrNoRows) {
		return limit, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return n, true, nil
}

// QuotaSweeper drops the counters no window reads any more. SweepEmbed
// drops the embed_* kinds; the demo kinds (the admission's demo_visit and
// demo_signup, the hub's agent_turn, post_min and post_day) go through this.
type QuotaSweeper interface {
	// SweepQuota deletes tenant's quota_counts rows of kinds whose window
	// started before before; it returns how many went.
	SweepQuota(ctx context.Context, tenant string, kinds []string, before time.Time) (int, error)
}

var _ QuotaSweeper = (*Postgres)(nil)

// DemoAdmitQuotaKinds are the admission counters' kinds (humans.go), for the
// hub's demo quota sweep.
var DemoAdmitQuotaKinds = []string{quotaDemoVisit, quotaDemoSignup}

// SweepQuota runs in tenant's own scope: every demo kind lives in the demo
// workspace, so it needs no operator scope.
func (s *Postgres) SweepQuota(ctx context.Context, tenant string, kinds []string, before time.Time) (int, error) {
	if err := checkTenant(tenant); err != nil {
		return 0, err
	}
	if len(kinds) == 0 {
		return 0, nil
	}
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM quota_counts
		WHERE tenant_id = $1 AND kind = ANY($2::text[]) AND window_start < $3`, tenant, kinds, before.UTC())
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

func (s *Postgres) MemberSince(ctx context.Context, tenant, human string) (time.Time, error) {
	var since time.Time
	err := s.queryRowTenant(ctx, tenant, `SELECT created_at FROM tenant_memberships
		WHERE tenant_id = $1 AND human_id = $2`, []any{tenant, human}, &since)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, ErrNotFound
	}
	return since, err
}
