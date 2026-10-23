package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The Postgres side of hours.go (rdb 0151, 0176, 0218). Every statement runs in the
// tenant's RLS scope (FORCE RLS): a query that forgot its tenant_id still
// cannot reach another workspace. A per-member statement runs in the member
// scope too (inMember, rdb 0176's member_scope): one that forgot its
// member_id still cannot reach another member's rows.

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
	_, err = s.execMember(ctx, tenant, member, hoursMinutesUpsert, tenant, member, at, tg, src, tz)
	return hoursPGErr(err)
}

func (s *Postgres) HoursMinutes(ctx context.Context, tenant, member string, from, to time.Time) ([]HoursMinute, error) {
	out := []HoursMinute{}
	err := s.queryMember(ctx, tenant, member, `SELECT minute, target, src, tz FROM hours_minutes
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
	err := s.queryMember(ctx, tenant, member, `SELECT day::text, target, kind, minutes, suggested_minutes, state,
			coalesce(note, ''), coalesce(absence_type, ''), coalesce(entered_by, ''), coalesce(reason, ''),
			category_minutes, updated_at, updated_by
		FROM hours_entries
		WHERE tenant_id = $1 AND member_id = $2 AND day BETWEEN $3::date AND $4::date
		ORDER BY day, target, kind`, []any{tenant, member, from, to}, func(r pgx.Rows) error {
		var e HoursEntry
		var cats []byte
		if err := r.Scan(&e.Day, &e.Target, &e.Kind, &e.Minutes, &e.SuggestedMinutes, &e.State,
			&e.Note, &e.AbsenceType, &e.EnteredBy, &e.Reason, &cats, &e.UpdatedAt, &e.UpdatedBy); err != nil {
			return err
		}
		if cats != nil {
			if err := json.Unmarshal(cats, &e.CategoryMinutes); err != nil {
				return err
			}
		}
		e.UpdatedAt = e.UpdatedAt.UTC()
		out = append(out, e)
		return nil
	})
	return out, err
}

// hoursEntriesUpsert is the natural-key upsert on rdb 0218's five-column key.
const hoursEntriesUpsert = `INSERT INTO hours_entries (tenant_id, member_id, day, target, kind, minutes,
		suggested_minutes, state, note, absence_type, entered_by, reason, category_minutes, updated_at, updated_by)
	SELECT $1, $2, u.d, u.t, u.k, u.m, u.sm, u.st, NULLIF(u.n, ''), NULLIF(u.ab, ''), NULLIF(u.eb, ''),
		NULLIF(u.r, ''), NULLIF(u.c, '')::jsonb, $14, $15
	FROM unnest($3::date[], $4::text[], $5::text[], $6::int[], $7::int[], $8::text[], $9::text[],
		$10::text[], $11::text[], $12::text[], $13::text[]) AS u(d, t, k, m, sm, st, n, ab, eb, r, c)
	ON CONFLICT (tenant_id, member_id, day, target, kind) DO UPDATE
	SET minutes = EXCLUDED.minutes, suggested_minutes = EXCLUDED.suggested_minutes, state = EXCLUDED.state,
		note = EXCLUDED.note, absence_type = EXCLUDED.absence_type, entered_by = EXCLUDED.entered_by,
		reason = EXCLUDED.reason, category_minutes = EXCLUDED.category_minutes,
		updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by`

// hoursCategoryJSON is e's category split as jsonb text; "" = NULL.
func hoursCategoryJSON(e HoursEntry) (string, error) {
	if e.CategoryMinutes == nil {
		return "", nil
	}
	b, err := json.Marshal(e.CategoryMinutes)
	return string(b), err
}

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
	d, tg, kd, st, note := make([]string, n), make([]string, n), make([]string, n), make([]string, n), make([]string, n)
	ab, eb, rs, cat := make([]string, n), make([]string, n), make([]string, n), make([]string, n)
	m, sm := make([]int, n), make([]int, n) // 0..1440, checked; the SQL casts to int
	for i, e := range es {
		d[i], tg[i], kd[i], st[i], note[i] = e.Day, e.Target, e.Kind, e.State, e.Note
		ab[i], eb[i], rs[i] = e.AbsenceType, e.EnteredBy, e.Reason
		m[i], sm[i] = e.Minutes, e.SuggestedMinutes
		if cat[i], err = hoursCategoryJSON(e); err != nil {
			return err
		}
	}
	err = s.inMember(ctx, tenant, member, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, hoursMemberLock, tenant, member); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, hoursEntriesUpsert, tenant, member, d, tg, kd, m, sm, st, note,
			ab, eb, rs, cat, now.UTC(), by); err != nil {
			return err
		}
		if err := putHoursSpans(ctx, tx, tenant, member, es); err != nil {
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

// hoursSpansDropActivity removes the activity spans of the entries a write
// replaces them for (spec 107 3.4).
const hoursSpansDropActivity = `DELETE FROM hours_entry_spans s
	USING unnest($3::date[], $4::text[], $5::text[]) AS u(d, t, k)
	WHERE s.tenant_id = $1 AND s.member_id = $2 AND s.day = u.d AND s.target = u.t AND s.kind = u.k
		AND s.src = 'activity'`

// hoursSpansInsert inserts spans; with hoursSpansSkip (the activity spans)
// a span that overlaps a stored one is skipped, not refused.
const (
	hoursSpansInsert = `INSERT INTO hours_entry_spans (tenant_id, member_id, day, target, kind, start_at, end_at, src)
	SELECT $1, $2, u.d, u.t, u.k, u.s, u.e, u.src
	FROM unnest($3::date[], $4::text[], $5::text[], $6::timestamptz[], $7::timestamptz[], $8::text[])
		AS u(d, t, k, s, e, src)`
	hoursSpansSkip = ` ON CONFLICT DO NOTHING`
)

// hoursSpanCols is one INSERT's spans as unnest columns.
type hoursSpanCols struct {
	d, tg, kd, src []string
	st, en         []time.Time
}

func (c *hoursSpanCols) add(e HoursEntry, sp HoursSpan) {
	c.d, c.tg, c.kd, c.src = append(c.d, e.Day), append(c.tg, e.Target), append(c.kd, e.Kind), append(c.src, sp.Src)
	c.st, c.en = append(c.st, sp.Start), append(c.en, sp.End)
}

// putHoursSpans writes es's spans in the entries' transaction (spec 107 3.4):
// the activity spans dropped where es replaces them; then the member's own
// times (timer, plan, clock, manual), where an overlap with any span of the
// member (rdb 0176's EXCLUDE, or the same start: the PK) is ErrHoursOverlap;
// then the activity spans, the hub's own derivation, skipped where they
// overlap a stored span (their minutes stay unplaced, spec 118 6.2).
func putHoursSpans(ctx context.Context, tx pgx.Tx, tenant, member string, es []HoursEntry) error {
	var rd, rt, rk []string
	var own, act hoursSpanCols
	for _, e := range es {
		if hoursReplacesActivity(e) {
			rd, rt, rk = append(rd, e.Day), append(rt, e.Target), append(rk, e.Kind)
		}
		for _, sp := range e.Spans {
			if sp.Src == HoursSpanActivity {
				act.add(e, sp)
			} else {
				own.add(e, sp)
			}
		}
	}
	if len(rd) > 0 {
		if _, err := tx.Exec(ctx, hoursSpansDropActivity, tenant, member, rd, rt, rk); err != nil {
			return err
		}
	}
	if len(own.d) > 0 {
		_, err := tx.Exec(ctx, hoursSpansInsert, tenant, member, own.d, own.tg, own.kd, own.st, own.en, own.src)
		var pe *pgconn.PgError
		if errors.As(err, &pe) && (pe.Code == "23P01" || (pe.Code == "23505" && pe.ConstraintName == "hours_entry_spans_pkey")) {
			return ErrHoursOverlap
		}
		if err != nil {
			return err
		}
	}
	if len(act.d) > 0 {
		_, err := tx.Exec(ctx, hoursSpansInsert+hoursSpansSkip, tenant, member, act.d, act.tg, act.kd, act.st, act.en, act.src)
		return err
	}
	return nil
}

func (s *Postgres) HoursEntrySpans(ctx context.Context, tenant, member, from, to string) ([]HoursEntrySpan, error) {
	out := []HoursEntrySpan{}
	err := s.queryMember(ctx, tenant, member, `SELECT day::text, target, kind, start_at, end_at, src
		FROM hours_entry_spans
		WHERE tenant_id = $1 AND member_id = $2 AND day BETWEEN $3::date AND $4::date
		ORDER BY start_at`, []any{tenant, member, from, to}, func(r pgx.Rows) error {
		var sp HoursEntrySpan
		if err := r.Scan(&sp.Day, &sp.Target, &sp.Kind, &sp.Start, &sp.End, &sp.Src); err != nil {
			return err
		}
		sp.Start, sp.End = sp.Start.UTC(), sp.End.UTC()
		out = append(out, sp)
		return nil
	})
	return out, err
}

func (s *Postgres) DeleteHoursEntry(ctx context.Context, tenant, member, day, target string, now time.Time) error {
	if err := refuseFrozen(ctx, s, tenant, member, []string{day}, now); err != nil {
		return err
	}
	tag, err := s.execMember(ctx, tenant, member, `DELETE FROM hours_entries
		WHERE tenant_id = $1 AND member_id = $2 AND day = $3::date AND target = $4 AND kind = 'work'`,
		tenant, member, day, target)
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
// either means the row was refused by rdb 0151 or 0218.
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
