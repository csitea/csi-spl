package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0183: the OD pool's ops. lock-next is ONE statement
// (spec 134 3.3): the oldest lockable row is picked FOR UPDATE SKIP LOCKED,
// so two seats in the same millisecond take different rows and a second
// caller on the last free row gets none; expiry is lazy inside it.

// errOdDup leaves the insert's transaction so the open duplicate is read in
// a clean one.
var errOdDup = errors.New("od dedupe")

func (s *Postgres) EnqueueOdJob(ctx context.Context, tenant string, a FleetAsk, needsOwner bool, box string, now time.Time) (FleetAsk, bool, error) {
	a.From = AskAtBox(a.From, box)
	a = newOdJob(a, needsOwner, box, now)
	var out FleetAsk
	created := false
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM fleet_asks WHERE tenant_id = $1 AND fleet = $2
			AND state IN ('done', 'declined', 'dead') AND updated_at < $3`, tenant, a.Fleet, now.Add(-AskClosedTTL)); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO fleet_asks
			(tenant_id, fleet, ask_id, role, kind, from_agent, topic, summary, state, deadline_at, writer_box, created_at, updated_at,
			 lease_s, dedupe_key, issue_key, vendor_allow, needs)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12, $13, $14, $15, $16, $17)
			ON CONFLICT (tenant_id, fleet, ask_id) DO NOTHING`,
			tenant, a.Fleet, a.AskID, OdRole, a.Kind, a.From, a.Topic, a.Summary, a.State, nullTime(a.DeadlineAt), box, now,
			a.LeaseS, a.DedupeKey, a.IssueKey, a.VendorAllow, a.Needs)
		if isUniqueViolation(err) {
			return errOdDup
		}
		if err != nil {
			return err
		}
		created = tag.RowsAffected() == 1
		out, err = scanAsk(tx.QueryRow(ctx, `SELECT `+askCols+` FROM fleet_asks
			WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3`, tenant, a.Fleet, a.AskID), a.Fleet, now)
		return err
	})
	if !errors.Is(err, errOdDup) {
		return out, created, err
	}
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanAsk(tx.QueryRow(ctx, `SELECT `+askCols+` FROM fleet_asks
			WHERE tenant_id = $1 AND fleet = $2 AND kind = $3 AND dedupe_key = $4
			AND state IN ('open', 'acked', 'needs_owner')`, tenant, a.Fleet, a.Kind, a.DedupeKey), a.Fleet, now)
		return err
	})
	if err != nil {
		return FleetAsk{}, false, err
	}
	return out, false, ErrAskDuplicate
}

// The 4th lost lock: the expired rows of the pool's kinds already lost three.
const odDeadSQL = `UPDATE fleet_asks SET state = 'dead', closed_by = '', reason = $5, raised_n = raised_n + 1,
	lock_until = NULL, writer_box = $6, updated_at = $3
	WHERE tenant_id = $1 AND fleet = $2 AND role = 'od' AND kind = ANY ($4)
	AND state = 'acked' AND lock_until < $3 AND raised_n >= $7
	RETURNING ` + askCols

// lock-next, spec 134 3.3, on the hub clock ($3).
const odLockSQL = `UPDATE fleet_asks SET state = 'acked', acked_by = $5, gen = gen + 1,
	lock_until = $3 + make_interval(secs => lease_s),
	raised_n = raised_n + CASE WHEN state = 'acked' THEN 1 ELSE 0 END,
	writer_box = $9, updated_at = $3
	WHERE (tenant_id, fleet, ask_id) = (
		SELECT tenant_id, fleet, ask_id FROM fleet_asks
		WHERE tenant_id = $1 AND fleet = $2 AND role = 'od'
		AND kind = ANY ($4)
		AND (state = 'open' OR (state = 'acked' AND lock_until < $3))
		AND (vendor_allow = '' OR vendor_allow = $6)
		AND ($7 <> ALL (not_by))
		AND (needs = '' OR needs = ANY ($8))
		ORDER BY created_at, ask_id
		LIMIT 1 FOR UPDATE SKIP LOCKED)
	RETURNING ` + askCols

func (s *Postgres) LockNextOdJob(ctx context.Context, tenant string, q OdLock, box string, now time.Time) (FleetAsk, bool, []FleetAsk, error) {
	odLockNorm(&q, box)
	caps := odCaps(q, box)
	var got FleetAsk
	ok := false
	dead := []FleetAsk{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		pool, err := getOdPool(ctx, tx, tenant, q.Fleet)
		if err != nil || len(pool.Kinds) == 0 {
			return err
		}
		rows, err := tx.Query(ctx, odDeadSQL, tenant, q.Fleet, now, pool.Kinds, odDeadReason, box, OdMaxLocks-1)
		if err != nil {
			return err
		}
		for rows.Next() {
			a, err := scanAsk(rows, q.Fleet, now)
			if err != nil {
				rows.Close()
				return err
			}
			dead = append(dead, a)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		got, err = scanAsk(tx.QueryRow(ctx, odLockSQL, tenant, q.Fleet, now, pool.Kinds, q.Seat, q.Vendor, q.Harness, caps, box), q.Fleet, now)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		ok = err == nil
		return err
	})
	if err != nil {
		return FleetAsk{}, false, nil, err
	}
	sortAsks(dead)
	return got, ok, dead, nil
}

func (s *Postgres) ReleaseOdSeat(ctx context.Context, tenant, fleet, seat, box string, now time.Time) ([]FleetAsk, error) {
	seat = AskAtBox(seat, box)
	out := []FleetAsk{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `UPDATE fleet_asks SET state = 'open', gen = gen + 1, lock_until = NULL, writer_box = $4
			WHERE tenant_id = $1 AND fleet = $2 AND role = 'od' AND state = 'acked' AND acked_by = $3
			RETURNING `+askCols, tenant, fleet, seat, box)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			a, err := scanAsk(rows, fleet, now)
			if err != nil {
				return err
			}
			out = append(out, a)
		}
		return rows.Err()
	})
	sortAsks(out)
	return out, err
}

func getOdPool(ctx context.Context, tx pgx.Tx, tenant, fleet string) (OdPool, error) {
	p := OdPool{Fleet: fleet}
	var until *time.Time
	err := tx.QueryRow(ctx, `SELECT claude_n, grok_n, min_boxes, vendor_out, out_until, kinds, updated_by, writer_box, updated_at
		FROM od_pool WHERE tenant_id = $1 AND fleet = $2`, tenant, fleet).
		Scan(&p.ClaudeN, &p.GrokN, &p.MinBoxes, &p.VendorOut, &until, &p.Kinds, &p.UpdatedBy, &p.WriterBox, &p.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return DefaultOdPool(fleet), nil
	}
	if err != nil {
		return p, err
	}
	if until != nil {
		p.OutUntil = until.UTC()
	}
	if p.Kinds == nil {
		p.Kinds = []string{}
	}
	p.UpdatedAt = p.UpdatedAt.UTC()
	return p, nil
}

func (s *Postgres) GetOdPool(ctx context.Context, tenant, fleet string) (OdPool, error) {
	var p OdPool
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		p, err = getOdPool(ctx, tx, tenant, fleet)
		return err
	})
	return p, err
}

func (s *Postgres) PutOdPool(ctx context.Context, tenant string, p OdPool, by, box string, now time.Time) (OdPool, error) {
	by = AskAtBox(by, box)
	if p.Kinds == nil {
		p.Kinds = []string{}
	}
	var out OdPool
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO od_pool
			(tenant_id, fleet, claude_n, grok_n, min_boxes, vendor_out, out_until, kinds, updated_by, writer_box, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
			ON CONFLICT (tenant_id, fleet) DO UPDATE SET claude_n = EXCLUDED.claude_n, grok_n = EXCLUDED.grok_n,
			min_boxes = EXCLUDED.min_boxes, vendor_out = EXCLUDED.vendor_out, out_until = EXCLUDED.out_until,
			kinds = EXCLUDED.kinds, updated_by = EXCLUDED.updated_by, writer_box = EXCLUDED.writer_box,
			updated_at = EXCLUDED.updated_at`,
			tenant, p.Fleet, p.ClaudeN, p.GrokN, p.MinBoxes, p.VendorOut, nullTime(p.OutUntil), p.Kinds, by, box, now); err != nil {
			return err
		}
		var err error
		out, err = getOdPool(ctx, tx, tenant, p.Fleet)
		return err
	})
	return out, err
}
