package store

import (
	"context"
	"time"
)

// ChangeStamp is what one stamp read answers (rdb 0103, DB payload round 2
// R2-5): the tenant's change stamp, whether the last change is settled, and
// whether a live message expired in (Since, Now].
type ChangeStamp struct {
	// Stamp is SUM(n) over the tenant's tenant_change_stamps rows: it grows
	// with every committed write to a table a covered view reads.
	Stamp int64
	// Settled: the last change is older than ChangeStampSettle by the DB
	// clock. Only then may a validator be minted on this stamp: a body read
	// sooner may come from another hub instance's door cache (hotCacheTTL)
	// that has not seen the change yet, and would be pinned until the next.
	Settled bool
	// Expired: a message of the tenant left the live window (expires_at) in
	// (Since, Now]. Expiry changes what a view reads with no write at all.
	Expired bool
}

// ChangeStampSettle is hotCacheTTL plus 2 s of hub-to-DB clock and commit
// margin.
const ChangeStampSettle = hotCacheTTL + 2*time.Second

// ChangeStamper reads a tenant's change stamp in ONE round trip. Only
// *Postgres has one: the triggers of rdb 0103 keep it. A store without it
// gets no stamp validators (the views keep the body hash, etag.go).
type ChangeStamper interface {
	ChangeStamp(ctx context.Context, tenant string, since, now time.Time) (ChangeStamp, error)
}

// changeStampSQL is one aggregate row: no stamp row yet reads 0, settled.
const changeStampSQL = `SELECT COALESCE(SUM(n), 0)::bigint,
		COALESCE(MAX(changed_at) <= clock_timestamp() - make_interval(secs => $4), true),
		EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = $1 AND m.expires_at > $2 AND m.expires_at <= $3)
	FROM tenant_change_stamps WHERE tenant_id = $1`

func (s *Postgres) ChangeStamp(ctx context.Context, tenant string, since, now time.Time) (ChangeStamp, error) {
	var c ChangeStamp
	err := s.queryRowTenant(ctx, tenant, changeStampSQL,
		[]any{tenant, since, now, ChangeStampSettle.Seconds()}, &c.Stamp, &c.Settled, &c.Expired)
	return c, err
}
