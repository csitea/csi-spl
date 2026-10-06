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
	calendarCols0139 = `, props, time_zone, deleted_at, COALESCE(deleted_by, '')`
	calendarColsAs89 = `, '{}'::jsonb, 'UTC'::text, NULL::timestamptz, ''::text`
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
	full bool
	cols string // the select list scanCalendarEvent reads
	live string // " AND deleted_at IS NULL", or ""
}

// calendarShape probes for rdb 0139's columns (the missing-column probe;
// deleted_at stands for all of them, one migration added them together).
func (s *Postgres) calendarShape(ctx context.Context) calendarSQL {
	full := s.calEdit.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_attribute
			WHERE attrelid = to_regclass('calendar_events') AND attname = 'deleted_at' AND NOT attisdropped)`).Scan(&ok)
		return ok, err
	}, s.now())
	if !full {
		return calendarSQL{cols: calendarCols89 + calendarColsAs89}
	}
	return calendarSQL{full: true, cols: calendarCols89 + calendarCols0139, live: ` AND deleted_at IS NULL`}
}

func scanCalendarEvent(row pgx.Row) (CalendarEvent, error) {
	var e CalendarEvent
	var remind, deleted *time.Time
	err := row.Scan(&e.ID, &e.Title, &e.Description, &e.Kind, &e.StartsAt, &e.EndsAt, &e.AllDay, &e.Audience,
		&e.Mentions, &e.CreatorType, &e.CreatorID, &remind, &e.TopicID, &e.ReleaseVersion, &e.CreatedAt, &e.UpdatedAt,
		&e.Props, &e.TimeZone, &deleted, &e.DeletedBy)
	if remind != nil {
		e.RemindAt = remind.UTC()
	}
	if deleted != nil {
		e.DeletedAt = deleted.UTC()
	}
	e.StartsAt, e.EndsAt = e.StartsAt.UTC(), e.EndsAt.UTC()
	e.CreatedAt, e.UpdatedAt = e.CreatedAt.UTC(), e.UpdatedAt.UTC()
	if e.Mentions == nil {
		e.Mentions = []string{}
	}
	if e.Props == nil {
		e.Props = map[string]any{}
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
	cols, vals := ``, ``
	args := []any{tenant, e.Title, e.Description, e.Kind, e.StartsAt, e.EndsAt, e.AllDay, e.Audience, e.Mentions,
		e.CreatorType, e.CreatorID, nullTime(e.RemindAt), nullIfEmpty(e.TopicID), nullIfEmpty(e.ReleaseVersion), calendarNow(now)}
	if q.full {
		cols, vals = `, props, time_zone`, `, $16, $17`
		args = append(args, e.Props, e.TimeZone)
	}
	var out CalendarEvent
	err := s.tenantBatch(ctx, tenant, `INSERT INTO calendar_events (tenant_id, title, description, kind, starts_at, ends_at,
			all_day, audience, mentions, creator_type, creator_id, remind_at, topic_id, release_version, created_at, updated_at`+cols+`)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $15`+vals+`)
		RETURNING `+q.cols, args,
		func(br pgx.BatchResults) (err error) {
			out, err = scanCalendarEvent(br.QueryRow())
			return err
		})
	return out, err
}

func (s *Postgres) GetCalendarEvent(ctx context.Context, tenant, viewer, id string) (CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return CalendarEvent{}, err
	}
	if !calendarIDRe.MatchString(id) || !s.hasCalendar(ctx) {
		return CalendarEvent{}, ErrNotFound
	}
	q := s.calendarShape(ctx)
	var out CalendarEvent
	err := s.tenantBatch(ctx, tenant, `SELECT `+q.cols+` FROM calendar_events
		WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarPrivateSQL+q.live,
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
		WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarPrivateSQL+q.live+` FOR UPDATE`, tenant, viewer, id))
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
	q, err := s.calendarWritable(ctx, tenant, id)
	if err != nil {
		return CalendarEvent{}, err
	}
	var out CalendarEvent
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		e, err := lockCalendarEvent(ctx, tx, q, tenant, viewer, id, p.IfUpdatedAt)
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
			set, args = `, props = $15, time_zone = $16`, append(args, e.Props, e.TimeZone)
		}
		out, err = scanCalendarEvent(tx.QueryRow(ctx, `UPDATE calendar_events SET title = $3, description = $4, kind = $5,
				starts_at = $6, ends_at = $7, all_day = $8, audience = $9, mentions = $10, remind_at = $11,
				topic_id = $12, release_version = $13, updated_at = $14`+set+`
			WHERE tenant_id = $1 AND event_id = $2::uuid
			RETURNING `+q.cols, args...))
		return err
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
	q, err := s.calendarWritable(ctx, tenant, id)
	if err != nil {
		return CalendarEvent{}, err
	}
	var out CalendarEvent
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		e, err := lockCalendarEvent(ctx, tx, q, tenant, viewer, id, ifUpdated)
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
	q, err := s.calendarWritable(ctx, tenant, id)
	if err != nil {
		return CalendarEvent{}, err
	}
	if !q.full {
		return CalendarEvent{}, ErrNotFound
	}
	var out CalendarEvent
	err = s.tenantBatch(ctx, tenant, `UPDATE calendar_events SET deleted_at = NULL, deleted_by = NULL
		WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarTrashSQL+`
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
		WHERE tenant_id = $1 AND deleted_at >= $3 AND ` + calendarTrashSQL + `
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
	return s.calendarQuery(ctx, tenant, func(q calendarSQL) string {
		return `SELECT ` + q.cols + ` FROM calendar_events
		WHERE tenant_id = $1 AND starts_at < $4 AND ends_at >= $3 AND ` + calendarPrivateSQL + q.live + `
		ORDER BY starts_at, event_id::text LIMIT $5`
	}, []any{tenant, viewer, r.Start, r.End, calendarMaxEvents})
}

// CalendarMarks folds the range read into days in Go (calendarMarksOf), so
// the day rule is the same in both stores.
func (s *Postgres) CalendarMarks(ctx context.Context, tenant, viewer string, r CalendarRange) ([]CalendarMark, error) {
	evs, err := s.ListCalendarEvents(ctx, tenant, viewer, r)
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
		WHERE tenant_id = $1 AND remind_at >= $3 AND remind_at < $4 AND (creator_id = $2 OR $2 = ANY (mentions))` + q.live + `
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
