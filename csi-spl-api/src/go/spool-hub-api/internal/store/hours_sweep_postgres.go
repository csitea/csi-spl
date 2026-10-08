package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Postgres side of hours_sweep.go (rdb 0151). The per-workspace work runs
// in that workspace's RLS scope; only the workspace list and the 45-day prune
// see every workspace (operator scope, operator_scope_test.go).

func (s *Postgres) SweepHours(ctx context.Context, now time.Time) (HoursSweepResult, error) {
	return sweepHours(ctx, s, now)
}

func (s *Postgres) hoursSweepTenants(ctx context.Context) ([]string, error) {
	out := []string{}
	err := s.asOperatorQuery(ctx, `SELECT tenant_id FROM tenants ORDER BY tenant_id`, nil, func(r pgx.Rows) error {
		var id string
		if err := r.Scan(&id); err != nil {
			return err
		}
		out = append(out, id)
		return nil
	})
	return out, err
}

// hoursLocalDays selects the minutes of local days $2..$3: a day of slack
// either side bounds the index scan, the zone of each row decides its day.
const hoursLocalDays = `minute >= ($2::date - 1)::timestamp AT TIME ZONE 'UTC'
	AND minute < ($3::date + 2)::timestamp AT TIME ZONE 'UTC'
	AND (minute AT TIME ZONE tz)::date BETWEEN $2::date AND $3::date`

func (s *Postgres) hoursActiveMembers(ctx context.Context, tenant, from, to string) (map[string]bool, error) {
	out := map[string]bool{}
	err := s.queryTenant(ctx, tenant, `SELECT a.member_id FROM (
			SELECT member_id FROM hours_entries WHERE tenant_id = $1 AND day BETWEEN $2::date AND $3::date
			UNION
			SELECT member_id FROM hours_minutes WHERE tenant_id = $1 AND `+hoursLocalDays+`
		) a JOIN humans h ON h.human_id = a.member_id AND NOT h.technical`,
		[]any{tenant, from, to}, func(r pgx.Rows) error {
			var id string
			if err := r.Scan(&id); err != nil {
				return err
			}
			out[id] = true
			return nil
		})
	return out, err
}

func (s *Postgres) freezeHoursPeriod(ctx context.Context, tenant string, p HoursPeriod) (created bool, pruned int, err error) {
	if err := checkHoursPeriod(&p); err != nil {
		return false, 0, err
	}
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO hours_periods (tenant_id, member_id, period_start, period_end,
				state, minutes, decided_by, decided_at)
			SELECT $1, $4, $2::date, $3::date, $5, coalesce((SELECT sum(minutes) FROM hours_entries
					WHERE tenant_id = $1 AND member_id = $4 AND day BETWEEN $2::date AND $3::date
						AND state = 'approved'), 0), $6, $7
			ON CONFLICT (tenant_id, member_id, period_start) DO NOTHING`,
			tenant, p.Start, p.End, p.Member, p.State, p.DecidedBy, p.DecidedAt.UTC())
		if err != nil {
			return err
		}
		created = tag.RowsAffected() == 1
		tag, err = tx.Exec(ctx, `DELETE FROM hours_minutes
			WHERE tenant_id = $1 AND member_id = $4 AND `+hoursLocalDays, tenant, p.Start, p.End, p.Member)
		pruned = int(tag.RowsAffected())
		return err
	})
	if err != nil {
		return false, 0, hoursPGErr(err)
	}
	return created, pruned, nil
}

func (s *Postgres) pruneAgedHoursMinutes(ctx context.Context, before time.Time) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM hours_minutes WHERE minute < $1`, before)
		n = int(tag.RowsAffected())
		return err
	})
	return n, err
}
