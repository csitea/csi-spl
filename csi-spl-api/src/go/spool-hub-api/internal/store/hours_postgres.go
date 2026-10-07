package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The Postgres side of hours.go (rdb 0151). Every statement runs in the
// tenant's RLS scope (FORCE RLS): a query that forgot its tenant_id still
// cannot reach another workspace.

// hoursMinutesUpsert is the post-over-tab rule of spec 1.3 at write time: an
// existing tab row takes the new target, source and zone; a post row stays.
const hoursMinutesUpsert = `INSERT INTO hours_minutes (tenant_id, member_id, minute, target, src, tz)
	SELECT $1, $2, u.m, u.t, u.s, u.z
	FROM unnest($3::timestamptz[], $4::text[], $5::text[], $6::text[]) AS u(m, t, s, z)
	ON CONFLICT (tenant_id, member_id, minute) DO UPDATE
	SET target = EXCLUDED.target, src = EXCLUDED.src, tz = EXCLUDED.tz
	WHERE hours_minutes.src = 'tab'`

func (s *Postgres) UpsertHoursMinutes(ctx context.Context, tenant, member string, ms []HoursMinute) error {
	ms, err := normalizeHoursMinutes(member, ms)
	if err != nil || len(ms) == 0 {
		return err
	}
	at := make([]time.Time, len(ms))
	tg, src, tz := make([]string, len(ms)), make([]string, len(ms)), make([]string, len(ms))
	for i, m := range ms {
		at[i], tg[i], src[i], tz[i] = m.At, m.Target, m.Src, m.TZ
	}
	_, err = s.execTenant(ctx, tenant, hoursMinutesUpsert, tenant, member, at, tg, src, tz)
	return hoursPGErr(err)
}

func (s *Postgres) HoursMinutes(ctx context.Context, tenant, member string, from, to time.Time) ([]HoursMinute, error) {
	out := []HoursMinute{}
	err := s.queryTenant(ctx, tenant, `SELECT minute, target, src, tz FROM hours_minutes
		WHERE tenant_id = $1 AND member_id = $2 AND minute >= $3 AND minute < $4
		ORDER BY minute`, []any{tenant, member, from, to}, func(r pgx.Rows) error {
		var m HoursMinute
		if err := r.Scan(&m.At, &m.Target, &m.Src, &m.TZ); err != nil {
			return err
		}
		m.At = m.At.UTC()
		out = append(out, m)
		return nil
	})
	return out, err
}

func (s *Postgres) HoursEntries(ctx context.Context, tenant, member, from, to string) ([]HoursEntry, error) {
	out := []HoursEntry{}
	err := s.queryTenant(ctx, tenant, `SELECT day::text, target, minutes, suggested_minutes, state,
			coalesce(note, ''), updated_at, updated_by
		FROM hours_entries
		WHERE tenant_id = $1 AND member_id = $2 AND day BETWEEN $3::date AND $4::date
		ORDER BY day, target`, []any{tenant, member, from, to}, func(r pgx.Rows) error {
		var e HoursEntry
		if err := r.Scan(&e.Day, &e.Target, &e.Minutes, &e.SuggestedMinutes, &e.State,
			&e.Note, &e.UpdatedAt, &e.UpdatedBy); err != nil {
			return err
		}
		e.UpdatedAt = e.UpdatedAt.UTC()
		out = append(out, e)
		return nil
	})
	return out, err
}

const hoursEntriesUpsert = `INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes,
		suggested_minutes, state, note, updated_at, updated_by)
	SELECT $1, $2, u.d, u.t, u.m, u.sm, u.st, NULLIF(u.n, ''), $9, $10
	FROM unnest($3::date[], $4::text[], $5::int[], $6::int[], $7::text[], $8::text[]) AS u(d, t, m, sm, st, n)
	ON CONFLICT (tenant_id, member_id, day, target) DO UPDATE
	SET minutes = EXCLUDED.minutes, suggested_minutes = EXCLUDED.suggested_minutes, state = EXCLUDED.state,
		note = EXCLUDED.note, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by`

// hoursCapOver is the first of the days whose approved minutes exceed the cap.
const hoursCapOver = `SELECT day::text FROM hours_entries
	WHERE tenant_id = $1 AND member_id = $2 AND day = ANY($3::date[])
	GROUP BY day HAVING coalesce(sum(minutes) FILTER (WHERE state = 'approved'), 0) > $4
	LIMIT 1`

// hoursMemberLock serialises one member's entry writes, so two concurrent
// writes to a day cannot each pass the cap on their own.
const hoursMemberLock = `SELECT pg_advisory_xact_lock(hashtextextended('hours_entries/' || $1 || '/' || $2, 0))`

func (s *Postgres) PutHoursEntries(ctx context.Context, tenant, member string, es []HoursEntry, by string, now time.Time) error {
	es = append([]HoursEntry(nil), es...)
	days, err := normalizeHoursEntries(member, by, es)
	if err != nil {
		return err
	}
	if err := refuseFrozen(ctx, s, tenant, member, days, now); err != nil {
		return err
	}
	n := len(es)
	d, tg, st, note := make([]string, n), make([]string, n), make([]string, n), make([]string, n)
	m, sm := make([]int, n), make([]int, n) // 0..1440, checked; the SQL casts to int
	for i, e := range es {
		d[i], tg[i], st[i], note[i] = e.Day, e.Target, e.State, e.Note
		m[i], sm[i] = e.Minutes, e.SuggestedMinutes
	}
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, hoursMemberLock, tenant, member); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, hoursEntriesUpsert, tenant, member, d, tg, m, sm, st, note, now.UTC(), by); err != nil {
			return err
		}
		var over string
		err := tx.QueryRow(ctx, hoursCapOver, tenant, member, days, HoursDayCap).Scan(&over)
		if err == nil {
			return ErrHoursDayCap
		}
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	})
	return hoursPGErr(err)
}

func (s *Postgres) DeleteHoursEntry(ctx context.Context, tenant, member, day, target string, now time.Time) error {
	if err := refuseFrozen(ctx, s, tenant, member, []string{day}, now); err != nil {
		return err
	}
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM hours_entries
		WHERE tenant_id = $1 AND member_id = $2 AND day = $3::date AND target = $4`, tenant, member, day, target)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) CreateHoursPeriod(ctx context.Context, tenant string, p HoursPeriod) (bool, error) {
	if err := checkHoursPeriod(&p); err != nil {
		return false, err
	}
	if p.DecidedAt.IsZero() {
		p.DecidedAt = time.Now()
	}
	tag, err := s.execTenant(ctx, tenant, `INSERT INTO hours_periods (tenant_id, member_id, period_start,
			period_end, state, minutes, note, decided_by, decided_at)
		VALUES ($1, $2, $3::date, $4::date, $5, $6, NULLIF($7, ''), $8, $9)
		ON CONFLICT (tenant_id, member_id, period_start) DO NOTHING`,
		tenant, p.Member, p.Start, p.End, p.State, p.Minutes, p.Note, p.DecidedBy, p.DecidedAt.UTC())
	if err != nil {
		return false, hoursPGErr(err)
	}
	return tag.RowsAffected() == 1, nil
}

const hoursPeriodCols = `member_id, period_start::text, period_end::text, state, minutes,
	coalesce(note, ''), decided_by, decided_at`

func scanHoursPeriod(r pgx.Row) (HoursPeriod, error) {
	var p HoursPeriod
	err := r.Scan(&p.Member, &p.Start, &p.End, &p.State, &p.Minutes, &p.Note, &p.DecidedBy, &p.DecidedAt)
	p.DecidedAt = p.DecidedAt.UTC()
	return p, err
}

func (s *Postgres) SetHoursPeriodState(ctx context.Context, tenant, member, start string, ch HoursPeriodChange) (HoursPeriod, error) {
	from, err := checkHoursPeriodChange(&ch)
	if err != nil {
		return HoursPeriod{}, err
	}
	if _, err := ParseHoursDay(start); err != nil {
		return HoursPeriod{}, err
	}
	var minutes any
	if ch.Minutes != nil {
		minutes = *ch.Minutes
	}
	var p HoursPeriod
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		p, err = scanHoursPeriod(tx.QueryRow(ctx, `UPDATE hours_periods
			SET state = $4, minutes = coalesce($5::int, minutes),
				note = CASE WHEN $4 = 'returned' THEN $6 ELSE note END,
				decided_by = $7, decided_at = $8
			WHERE tenant_id = $1 AND member_id = $2 AND period_start = $3::date AND state = ANY($9::text[])
			RETURNING `+hoursPeriodCols, tenant, member, start, ch.State, minutes, ch.Note, ch.By, ch.At, from))
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM hours_periods
			WHERE tenant_id = $1 AND member_id = $2 AND period_start = $3::date)`, tenant, member, start).Scan(&exists); err != nil {
			return err
		}
		if exists {
			return ErrHoursPeriodState
		}
		return ErrNotFound
	})
	return p, err
}

func (s *Postgres) HoursPeriods(ctx context.Context, tenant, member, from, to string) ([]HoursPeriod, error) {
	out := []HoursPeriod{}
	err := s.queryTenant(ctx, tenant, `SELECT `+hoursPeriodCols+` FROM hours_periods
		WHERE tenant_id = $1 AND ($2 = '' OR member_id = $2)
			AND period_start <= $4::date AND period_end >= $3::date
		ORDER BY period_start, member_id`, []any{tenant, member, from, to}, func(r pgx.Rows) error {
		p, err := scanHoursPeriod(r)
		if err != nil {
			return err
		}
		out = append(out, p)
		return nil
	})
	return out, err
}

func (s *Postgres) HoursFrozenDays(ctx context.Context, tenant, member string, days []string, now time.Time) (map[string]bool, error) {
	return hoursFrozenDays(ctx, s, tenant, member, days, now)
}

func (s *Postgres) HoursIdleMinutes(ctx context.Context, tenant, member string) (int, error) {
	return hoursIdleMinutes(ctx, s, tenant, member)
}

// hoursPGErr maps a foreign-key violation (no such tenant) to ErrNotFound and
// a CHECK violation to ErrHoursBad; the store's own checks run first, so
// either means the row was refused by rdb 0151.
func hoursPGErr(err error) error {
	var pe *pgconn.PgError
	if !errors.As(err, &pe) {
		return err
	}
	switch pe.Code {
	case "23503":
		return ErrNotFound
	case "23514":
		return errors.Join(ErrHoursBad, err)
	}
	return err
}
