package store

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
)

// calendarCols89 is one rdb 0125 row as scanCalendarEvent reads it; the
// 0139 columns follow it (calendarCols0139, or their 089 values).
const calendarCols89 = `event_id::text, title, description, kind, starts_at, ends_at, all_day, audience,
	mentions, creator_type, creator_id, remind_at, COALESCE(topic_id, ''), COALESCE(release_version, ''),
	created_at, updated_at`

const (
	calendarCols0139 = `, props, time_zone, deleted_at, COALESCE(deleted_by, ''),
	COALESCE(rrule, ''), recur_until, COALESCE(recurring_event_id::text, ''), original_start, status` + calendarGuestsSQL
	calendarColsAs89 = `, '{}'::jsonb, 'UTC'::text, NULL::timestamptz, ''::text,
	''::text, NULL::timestamptz, ''::text, NULL::timestamptz, 'confirmed'::text, '[]'::jsonb`
	// rdb 0156's source_key ends every row, or '' before it.
	calendarCols0156   = `, COALESCE(source_key, '')`
	calendarColsAs0156 = `, ''::text`
)

// calendarPrivateSQL is the private filter with the viewer at $2 (spec 089
// section 5). An empty viewer reads no private event.
const calendarPrivateSQL = `(audience <> 'private' OR ($2::text <> '' AND (creator_id = $2 OR $2 = ANY (mentions))))`

// calendarIDRe: event_id is a uuid; anything else names no row (and would
// make Postgres refuse the cast).
var calendarIDRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// hasCalendar is the catalogue probe for rdb 0125 (the agent_seats.go
// pattern): the hub may roll before the migration reaches its database.
func (s *Postgres) hasCalendar(ctx context.Context) bool {
	return s.cal.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT to_regclass('calendar_events') IS NOT NULL`).Scan(&ok)
		return ok, err
	}, s.now())
}

// calendarSQL is the row shape of this database: with rdb 0139 the full row
// and the live filter, without it 089's row and no filter.
type calendarSQL struct {
	full   bool
	key    bool   // rdb 0156: source_key is in cols
	cols   string // the select list scanCalendarEvent reads
	live   string // " AND deleted_at IS NULL", or ""
	top    string // not an exception row: a single event or a series
	single string // neither a series nor an exception row
}

// calendarShape probes for rdb 0139's columns (the missing-column probe;
// deleted_at stands for all of them, one migration added them together).
func (s *Postgres) calendarShape(ctx context.Context) calendarSQL {
	full := s.calEdit.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_attribute
			WHERE attrelid = to_regclass('calendar_events') AND attname = 'deleted_at' AND NOT attisdropped)`).Scan(&ok)
		return ok, err
	}, s.now())
	hasKey := full && s.calKey.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, calendarHasSourceKey).Scan(&ok)
		return ok, err
	}, s.now())
	key := calendarColsAs0156
	if hasKey {
		key = calendarCols0156
	}
	if !full {
		return calendarSQL{cols: calendarCols89 + calendarColsAs89 + key}
	}
	return calendarSQL{full: true, key: hasKey, cols: calendarCols89 + calendarCols0139 + key, live: ` AND deleted_at IS NULL`,
		top: ` AND recurring_event_id IS NULL`, single: ` AND rrule IS NULL AND recurring_event_id IS NULL`}
}

func scanCalendarEvent(row pgx.Row) (CalendarEvent, error) {
	var e CalendarEvent
	var remind, deleted, until, orig *time.Time
	err := row.Scan(&e.ID, &e.Title, &e.Description, &e.Kind, &e.StartsAt, &e.EndsAt, &e.AllDay, &e.Audience,
		&e.Mentions, &e.CreatorType, &e.CreatorID, &remind, &e.TopicID, &e.ReleaseVersion, &e.CreatedAt, &e.UpdatedAt,
		&e.Props, &e.TimeZone, &deleted, &e.DeletedBy, &e.RRule, &until, &e.RecurringEventID, &orig, &e.Status, &e.Guests, &e.SourceKey)
	for _, t := range []struct {
		dst *time.Time
		src *time.Time
	}{{&e.RemindAt, remind}, {&e.DeletedAt, deleted}, {&e.RecurUntil, until}, {&e.OriginalStart, orig}} {
		if t.src != nil {
			*t.dst = t.src.UTC()
		}
	}
	e.StartsAt, e.EndsAt = e.StartsAt.UTC(), e.EndsAt.UTC()
	e.CreatedAt, e.UpdatedAt = e.CreatedAt.UTC(), e.UpdatedAt.UTC()
	e.Audience = CalendarAudienceOf(e.Audience)
	if e.Mentions == nil {
		e.Mentions = []string{}
	}
	if e.Props == nil {
		e.Props = map[string]any{}
	}
	if e.Guests == nil {
		e.Guests = []CalendarGuest{}
	}
	return e, err
}

func (s *Postgres) CreateCalendarEvent(ctx context.Context, tenant string, e CalendarEvent, now time.Time) (CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return CalendarEvent{}, err
	}
	if err := normalizeCalendarEvent(&e); err != nil {
		return CalendarEvent{}, err
	}
	if !s.hasCalendar(ctx) {
		return CalendarEvent{}, ErrCalendarUnavailable
	}
	q := s.calendarShape(ctx)
	if !q.full && e.RRule != "" {
		return CalendarEvent{}, errCalendarScope("a repeating event needs rdb 0139")
	}
	if !q.full && len(e.Guests) > 0 {
		return CalendarEvent{}, errCalendarScope("guests need rdb 0139")
	}
	cols, vals := ``, ``
	args := []any{tenant, e.Title, e.Description, e.Kind, e.StartsAt, e.EndsAt, e.AllDay, e.Audience, e.Mentions,
		e.CreatorType, e.CreatorID, nullTime(e.RemindAt), nullIfEmpty(e.TopicID), nullIfEmpty(e.ReleaseVersion), calendarNow(now)}
	if q.full {
		cols, vals = `, props, time_zone, rrule, recur_until`, `, $16, $17, $18, $19`
		args = append(args, e.Props, e.TimeZone, nullIfEmpty(e.RRule), nullTime(e.RecurUntil))
	}
	insert := `INSERT INTO calendar_events (tenant_id, title, description, kind, starts_at, ends_at,
			all_day, audience, mentions, creator_type, creator_id, remind_at, topic_id, release_version, created_at, updated_at` + cols + `)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $15` + vals + `)
		RETURNING ` + q.cols
	var out CalendarEvent
	if len(e.Guests) > 0 { // the guest rows in the same transaction (T007)
		err := s.inTenant(ctx, tenant, func(tx pgx.Tx) (err error) {
			if out, err = scanCalendarEvent(tx.QueryRow(ctx, insert, args...)); err != nil {
				return err
			}
			out.Guests = e.Guests
			return syncCalendarGuests(ctx, tx, tenant, out.ID, e.Guests)
		})
		return out, err
	}
	err := s.tenantBatch(ctx, tenant, insert, args, func(br pgx.BatchResults) (err error) {
		out, err = scanCalendarEvent(br.QueryRow())
		return err
	})
	return out, err
}

func (s *Postgres) GetCalendarEvent(ctx context.Context, tenant, viewer, id string) (CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return CalendarEvent{}, err
	}
	series, orig := calendarRef(id)
	if !calendarIDRe.MatchString(series) || !s.hasCalendar(ctx) {
		return CalendarEvent{}, ErrNotFound
	}
	q := s.calendarShape(ctx)
	var out CalendarEvent
	if !orig.IsZero() {
		err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			b, err := lockCalendarBundle(ctx, tx, q, tenant, viewer, series, "")
			if err == nil {
				out, _, err = b.occurrence(orig)
			}
			return err
		})
		return out, err
	}
	err := s.tenantBatch(ctx, tenant, `SELECT `+q.cols+` FROM calendar_events
		WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarPrivateSQL+q.live+q.top,
		[]any{tenant, viewer, id}, func(br pgx.BatchResults) (err error) {
			out, err = scanCalendarEvent(br.QueryRow())
			return err
		})
	if errors.Is(err, pgx.ErrNoRows) {
		return CalendarEvent{}, ErrNotFound
	}
	return out, err
}

// calendarWritable checks a write's tenant, table and id, and answers the
// row shape to write with.
func (s *Postgres) calendarWritable(ctx context.Context, tenant, id string) (calendarSQL, error) {
	if err := checkTenant(tenant); err != nil {
		return calendarSQL{}, err
	}
	if !s.hasCalendar(ctx) {
		return calendarSQL{}, ErrCalendarUnavailable
	}
	if !calendarIDRe.MatchString(id) {
		return calendarSQL{}, ErrNotFound
	}
	return s.calendarShape(ctx), nil
}

// lockCalendarEvent locks the live row the viewer can see and checks the
// precondition; a stale one answers the current row with ErrEditConflict.
func lockCalendarEvent(ctx context.Context, tx pgx.Tx, q calendarSQL, tenant, viewer, id string, ifUpdated time.Time) (CalendarEvent, error) {
	e, err := scanCalendarEvent(tx.QueryRow(ctx, `SELECT `+q.cols+` FROM calendar_events
		WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarPrivateSQL+q.live+q.top+` FOR UPDATE`, tenant, viewer, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return CalendarEvent{}, ErrNotFound
	} else if err != nil {
		return CalendarEvent{}, err
	}
	return e, calendarPrecondition(&e, ifUpdated)
}

// UpdateCalendarEvent locks the row the viewer can see, applies p in Go (so
// both stores validate one way) and writes every column back.
func (s *Postgres) UpdateCalendarEvent(ctx context.Context, tenant, viewer, id string, p CalendarPatch, now time.Time) (CalendarEvent, error) {
	series, orig := calendarRef(id)
	q, err := s.calendarWritable(ctx, tenant, series)
	if err != nil {
		return CalendarEvent{}, err
	}
	var out CalendarEvent
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		e, err := lockCalendarEvent(ctx, tx, q, tenant, viewer, series, time.Time{})
		if err == nil && (e.RRule != "" || !orig.IsZero()) {
			out, err = writeCalendarSeries(ctx, tx, q, tenant, e, func(b *calendarBundle) (calendarPlan, error) {
				return planCalendarEdit(b, orig, p, now)
			})
			return err
		}
		if err == nil {
			err = calendarPrecondition(&e, p.IfUpdatedAt)
		}
		if err != nil {
			out = e
			return err
		}
		applyCalendarPatch(&e, p)
		if err := normalizeCalendarEvent(&e); err != nil {
			return err
		}
		set, args := ``, []any{tenant, id, e.Title, e.Description, e.Kind, e.StartsAt, e.EndsAt, e.AllDay, e.Audience,
			e.Mentions, nullTime(e.RemindAt), nullIfEmpty(e.TopicID), nullIfEmpty(e.ReleaseVersion), calendarNow(now)}
		if q.full {
			set = `, props = $15, time_zone = $16, rrule = $17, recur_until = $18`
			args = append(args, e.Props, e.TimeZone, nullIfEmpty(e.RRule), nullTime(e.RecurUntil))
		} else if e.RRule != "" || len(e.Guests) > 0 {
			return errCalendarScope("a repeating event or a guest needs rdb 0139")
		}
		out, err = scanCalendarEvent(tx.QueryRow(ctx, `UPDATE calendar_events SET title = $3, description = $4, kind = $5,
				starts_at = $6, ends_at = $7, all_day = $8, audience = $9, mentions = $10, remind_at = $11,
				topic_id = $12, release_version = $13, updated_at = $14`+set+`
			WHERE tenant_id = $1 AND event_id = $2::uuid
			RETURNING `+q.cols, args...))
		if err != nil || p.Guests == nil {
			return err
		}
		out.Guests = e.Guests
		return syncCalendarGuests(ctx, tx, tenant, id, e.Guests)
	})
	return out, err
}

func (s *Postgres) DeleteCalendarEvent(ctx context.Context, tenant, viewer, id string) error {
	_, err := s.TrashCalendarEvent(ctx, tenant, viewer, id, time.Time{}, s.now())
	return err
}

// TrashCalendarEvent sets deleted_at / deleted_by (updated_at stays, so an
// Undo gives back the version the caller last read). Without rdb 0139 it is
// 089's hard delete.
func (s *Postgres) TrashCalendarEvent(ctx context.Context, tenant, viewer, id string, ifUpdated, now time.Time) (CalendarEvent, error) {
	return s.TrashCalendarScope(ctx, tenant, viewer, id, "", ifUpdated, now)
}

// TrashCalendarScope: a series or an occurrence goes through its plan
// (planCalendarDelete); a single event is TrashCalendarEvent's soft delete.
func (s *Postgres) TrashCalendarScope(ctx context.Context, tenant, viewer, id, scope string, ifUpdated, now time.Time) (CalendarEvent, error) {
	series, orig := calendarRef(id)
	q, err := s.calendarWritable(ctx, tenant, series)
	if err != nil {
		return CalendarEvent{}, err
	}
	var out CalendarEvent
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		e, err := lockCalendarEvent(ctx, tx, q, tenant, viewer, series, time.Time{})
		if err == nil && (e.RRule != "" || !orig.IsZero()) {
			out, err = writeCalendarSeries(ctx, tx, q, tenant, e, func(b *calendarBundle) (calendarPlan, error) {
				return planCalendarDelete(b, orig, scope, viewer, ifUpdated, now)
			})
			return err
		}
		if err == nil {
			err = calendarPrecondition(&e, ifUpdated)
		}
		out = e
		if err != nil {
			return err
		}
		if !q.full {
			_, err = tx.Exec(ctx, `DELETE FROM calendar_events WHERE tenant_id = $1 AND event_id = $2::uuid`, tenant, id)
			return err
		}
		out, err = scanCalendarEvent(tx.QueryRow(ctx, `UPDATE calendar_events SET deleted_at = $3, deleted_by = $4
			WHERE tenant_id = $1 AND event_id = $2::uuid RETURNING `+q.cols, tenant, id, calendarNow(now), nullIfEmpty(viewer)))
		return err
	})
	return out, err
}

// calendarTrashSQL: in the trash, deleted by the viewer ($2), who can read it.
const calendarTrashSQL = `deleted_at IS NOT NULL AND $2::text <> '' AND deleted_by = $2 AND ` + calendarPrivateSQL

// RestoreCalendarEvent clears deleted_at / deleted_by of an event the viewer
// deleted. Without rdb 0139 nothing is ever in the trash.
func (s *Postgres) RestoreCalendarEvent(ctx context.Context, tenant, viewer, id string) (CalendarEvent, error) {
	series, orig := calendarRef(id)
	q, err := s.calendarWritable(ctx, tenant, series)
	if err != nil {
		return CalendarEvent{}, err
	}
	if !q.full {
		return CalendarEvent{}, ErrNotFound
	}
	var out CalendarEvent
	if !orig.IsZero() {
		err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			b, err := lockCalendarBundle(ctx, tx, q, tenant, viewer, series, " FOR UPDATE")
			if err != nil {
				return err
			}
			pl, err := planCalendarRestore(b, orig, viewer, s.now())
			if err != nil {
				return err
			}
			out = pl.out
			return upsertCalendarRows(ctx, tx, tenant, pl.writes)
		})
		return out, err
	}
	err = s.tenantBatch(ctx, tenant, `UPDATE calendar_events SET deleted_at = NULL, deleted_by = NULL
		WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarTrashSQL+q.top+`
		RETURNING `+q.cols, []any{tenant, viewer, id}, func(br pgx.BatchResults) (err error) {
		out, err = scanCalendarEvent(br.QueryRow())
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return CalendarEvent{}, ErrNotFound
	}
	return out, err
}

// CalendarTrash reads the calendar_events_trash index range.
func (s *Postgres) CalendarTrash(ctx context.Context, tenant, viewer string, since time.Time) ([]CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	if viewer == "" || !s.hasCalendar(ctx) || !s.calendarShape(ctx).full {
		return nil, nil
	}
	return s.calendarQuery(ctx, tenant, func(q calendarSQL) string {
		return `SELECT ` + q.cols + ` FROM calendar_events
		WHERE tenant_id = $1 AND deleted_at >= $3 AND ` + calendarTrashSQL + q.top + `
		ORDER BY deleted_at DESC, event_id::text LIMIT $4`
	}, []any{tenant, viewer, since, calendarMaxEvents})
}

// calendarQuery runs one read of events in the tenant's scope; $1 tenant,
// $2 viewer, then args. sql builds the statement for this database's shape.
func (s *Postgres) calendarQuery(ctx context.Context, tenant string, sql func(calendarSQL) string, args []any) ([]CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	if !s.hasCalendar(ctx) {
		return nil, nil
	}
	var out []CalendarEvent
	err := s.queryTenant(ctx, tenant, sql(s.calendarShape(ctx)), args, func(rows pgx.Rows) error {
		e, err := scanCalendarEvent(rows)
		out = append(out, e)
		return err
	})
	return out, err
}

func (s *Postgres) ListCalendarEvents(ctx context.Context, tenant, viewer string, r CalendarRange) ([]CalendarEvent, error) {
	return s.listCalendar(ctx, tenant, viewer, r, calendarMaxEvents)
}

// listCalendar reads the single events that overlap r, the live series that
// may reach it (calendar_events_series: starts before r ends, recur_until
// NULL or not before r starts) and their exceptions, and expands the series
// in Go (calendarWithSeries).
func (s *Postgres) listCalendar(ctx context.Context, tenant, viewer string, r CalendarRange, limit int) ([]CalendarEvent, error) {
	singles, err := s.calendarQuery(ctx, tenant, func(q calendarSQL) string {
		return `SELECT ` + q.cols + ` FROM calendar_events
		WHERE tenant_id = $1 AND starts_at < $4 AND ends_at >= $3 AND ` + calendarPrivateSQL + q.live + q.single + `
		ORDER BY starts_at, event_id::text LIMIT $5`
	}, []any{tenant, viewer, r.Start, r.End, calendarMaxEvents})
	if err != nil || !s.hasCalendar(ctx) || !s.calendarShape(ctx).full {
		return singles, err
	}
	series, err := s.calendarQuery(ctx, tenant, func(q calendarSQL) string {
		return `SELECT ` + q.cols + ` FROM calendar_events
		WHERE tenant_id = $1 AND rrule IS NOT NULL AND starts_at < $4 AND (recur_until IS NULL OR recur_until >= $3)
			AND ` + calendarPrivateSQL + q.live + `
		ORDER BY starts_at, event_id::text LIMIT $5`
	}, []any{tenant, viewer, r.Start, r.End, calendarMaxEvents})
	if err != nil || len(series) == 0 {
		return singles, err
	}
	ids := make([]string, 0, len(series))
	for _, e := range series {
		ids = append(ids, e.ID)
	}
	excs, err := s.calendarQuery(ctx, tenant, func(q calendarSQL) string {
		return `SELECT ` + q.cols + ` FROM calendar_events
		WHERE tenant_id = $1 AND $2::text IS NOT NULL AND recurring_event_id = ANY ($3::uuid[])
		ORDER BY original_start`
	}, []any{tenant, viewer, ids})
	if err != nil {
		return nil, err
	}
	return calendarWithSeries(singles, series, excs, viewer, r, limit)
}

// CalendarMarks folds the range read into days in Go (calendarMarksOf), so
// the day rule is the same in both stores.
func (s *Postgres) CalendarMarks(ctx context.Context, tenant, viewer string, r CalendarRange) ([]CalendarMark, error) {
	evs, err := s.listCalendar(ctx, tenant, viewer, r, calendarMaxMarkOccurrences)
	if err != nil {
		return nil, err
	}
	return calendarMarksOf(evs, r), nil
}

// CalendarReminders reads the calendar_events_remind index range.
func (s *Postgres) CalendarReminders(ctx context.Context, tenant, viewer string, r CalendarRange) ([]CalendarEvent, error) {
	if viewer == "" {
		return nil, nil
	}
	return s.calendarQuery(ctx, tenant, func(q calendarSQL) string {
		return `SELECT ` + q.cols + ` FROM calendar_events
		WHERE tenant_id = $1 AND remind_at >= $3 AND remind_at < $4 AND (creator_id = $2 OR $2 = ANY (mentions))` + q.live + q.single + `
		ORDER BY remind_at, event_id::text LIMIT $5`
	}, []any{tenant, viewer, r.Start, r.End, calendarMaxEvents})
}

// OfficialDays reads the shared reference table (no tenant_id, no RLS).
// The range's days are [Start's day, the day of End - 1 µs].
func (s *Postgres) OfficialDays(ctx context.Context, region string, r CalendarRange) ([]OfficialDay, error) {
	if region == "" || !r.Start.Before(r.End) || !s.hasCalendar(ctx) {
		return nil, nil
	}
	from := r.Start.UTC().Format(time.DateOnly)
	to := r.End.UTC().Add(-time.Microsecond).Format(time.DateOnly)
	rows, err := s.pool.Query(ctx, `SELECT region, to_char(day, 'YYYY-MM-DD'), title FROM official_days
		WHERE region = $1 AND day BETWEEN $2::date AND $3::date ORDER BY day`, region, from, to)
	if err != nil {
		return nil, err
	}
	var out []OfficialDay
	err = scanRows(rows, func(rows pgx.Rows) error {
		var d OfficialDay
		err := rows.Scan(&d.Region, &d.Day, &d.Title)
		out = append(out, d)
		return err
	})
	return out, err
}

// lockCalendarBundle reads the live series id the viewer can read and its
// exception rows (lock " FOR UPDATE" locks the series row: every write to a
// series goes through it).
func lockCalendarBundle(ctx context.Context, tx pgx.Tx, q calendarSQL, tenant, viewer, id, lock string) (*calendarBundle, error) {
	e, err := scanCalendarEvent(tx.QueryRow(ctx, `SELECT `+q.cols+` FROM calendar_events
		WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarPrivateSQL+q.live+q.top+lock, tenant, viewer, id))
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && e.RRule == "") {
		return nil, ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return loadCalendarExceptions(ctx, tx, q, tenant, e)
}

// loadCalendarExceptions is series e's bundle: e and its exception rows.
func loadCalendarExceptions(ctx context.Context, tx pgx.Tx, q calendarSQL, tenant string, e CalendarEvent) (*calendarBundle, error) {
	b := &calendarBundle{series: e}
	rows, err := tx.Query(ctx, `SELECT `+q.cols+` FROM calendar_events
		WHERE tenant_id = $1 AND recurring_event_id = $2::uuid ORDER BY original_start`, tenant, e.ID)
	if err != nil {
		return nil, err
	}
	err = scanRows(rows, func(rows pgx.Rows) error {
		x, err := scanCalendarEvent(rows)
		b.excs = append(b.excs, x)
		return err
	})
	return b, err
}

// writeCalendarSeries runs plan on series e (locked by the caller) and writes
// its rows. An occurrence id of a single event names nothing.
func writeCalendarSeries(ctx context.Context, tx pgx.Tx, q calendarSQL, tenant string, e CalendarEvent,
	plan func(*calendarBundle) (calendarPlan, error)) (CalendarEvent, error) {
	if e.RRule == "" {
		return CalendarEvent{}, ErrNotFound
	}
	b, err := loadCalendarExceptions(ctx, tx, q, tenant, e)
	if err != nil {
		return CalendarEvent{}, err
	}
	pl, err := plan(b)
	if err != nil {
		return pl.out, err
	}
	return pl.out, upsertCalendarRows(ctx, tx, tenant, pl.writes)
}

// calendarUpsertSQL writes one full row of a series plan: a new row, or every
// mutable column of an existing one in the same workspace.
const calendarUpsertSQL = `INSERT INTO calendar_events (event_id, tenant_id, title, description, kind, starts_at,
		ends_at, all_day, audience, mentions, creator_type, creator_id, remind_at, topic_id, release_version, created_at,
		updated_at, props, time_zone, rrule, recur_until, recurring_event_id, original_start, status, deleted_at, deleted_by)
	VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23,
		$24, $25, $26)
	ON CONFLICT (event_id) DO UPDATE SET title = EXCLUDED.title, description = EXCLUDED.description,
		kind = EXCLUDED.kind, starts_at = EXCLUDED.starts_at, ends_at = EXCLUDED.ends_at, all_day = EXCLUDED.all_day,
		audience = EXCLUDED.audience, mentions = EXCLUDED.mentions, remind_at = EXCLUDED.remind_at,
		topic_id = EXCLUDED.topic_id, release_version = EXCLUDED.release_version, updated_at = EXCLUDED.updated_at,
		props = EXCLUDED.props, time_zone = EXCLUDED.time_zone, rrule = EXCLUDED.rrule,
		recur_until = EXCLUDED.recur_until, recurring_event_id = EXCLUDED.recurring_event_id,
		original_start = EXCLUDED.original_start, status = EXCLUDED.status, deleted_at = EXCLUDED.deleted_at,
		deleted_by = EXCLUDED.deleted_by
	WHERE calendar_events.tenant_id = EXCLUDED.tenant_id`

// upsertCalendarRows writes rows in order, each in tenant, with its guest rows.
func upsertCalendarRows(ctx context.Context, tx pgx.Tx, tenant string, rows []CalendarEvent) error {
	for _, e := range rows {
		tag, err := tx.Exec(ctx, calendarUpsertSQL, e.ID, tenant, e.Title, e.Description, e.Kind, e.StartsAt, e.EndsAt,
			e.AllDay, e.Audience, e.Mentions, e.CreatorType, e.CreatorID, nullTime(e.RemindAt), nullIfEmpty(e.TopicID),
			nullIfEmpty(e.ReleaseVersion), e.CreatedAt, e.UpdatedAt, e.Props, e.TimeZone, nullIfEmpty(e.RRule),
			nullTime(e.RecurUntil), nullIfEmpty(e.RecurringEventID), nullTime(e.OriginalStart), e.Status,
			nullTime(e.DeletedAt), nullIfEmpty(e.DeletedBy))
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return ErrNotFound
		}
		if err := syncCalendarGuests(ctx, tx, tenant, e.ID, e.Guests); err != nil {
			return err
		}
	}
	return nil
}
