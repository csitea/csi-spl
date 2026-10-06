package store

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
)

// calendarCols is one calendar_events row as scanCalendarEvent reads it.
const calendarCols = `event_id::text, title, description, kind, starts_at, ends_at, all_day, audience,
	mentions, creator_type, creator_id, remind_at, COALESCE(topic_id, ''), COALESCE(release_version, ''),
	created_at, updated_at`

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

func scanCalendarEvent(row pgx.Row) (CalendarEvent, error) {
	var e CalendarEvent
	var remind *time.Time
	err := row.Scan(&e.ID, &e.Title, &e.Description, &e.Kind, &e.StartsAt, &e.EndsAt, &e.AllDay, &e.Audience,
		&e.Mentions, &e.CreatorType, &e.CreatorID, &remind, &e.TopicID, &e.ReleaseVersion, &e.CreatedAt, &e.UpdatedAt)
	if remind != nil {
		e.RemindAt = remind.UTC()
	}
	e.StartsAt, e.EndsAt = e.StartsAt.UTC(), e.EndsAt.UTC()
	e.CreatedAt, e.UpdatedAt = e.CreatedAt.UTC(), e.UpdatedAt.UTC()
	if e.Mentions == nil {
		e.Mentions = []string{}
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
	var out CalendarEvent
	err := s.tenantBatch(ctx, tenant, `INSERT INTO calendar_events (tenant_id, title, description, kind, starts_at, ends_at,
			all_day, audience, mentions, creator_type, creator_id, remind_at, topic_id, release_version, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $15)
		RETURNING `+calendarCols,
		[]any{tenant, e.Title, e.Description, e.Kind, e.StartsAt, e.EndsAt, e.AllDay, e.Audience, e.Mentions,
			e.CreatorType, e.CreatorID, nullTime(e.RemindAt), nullIfEmpty(e.TopicID), nullIfEmpty(e.ReleaseVersion), now.UTC()},
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
	var out CalendarEvent
	err := s.tenantBatch(ctx, tenant, `SELECT `+calendarCols+` FROM calendar_events
		WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarPrivateSQL,
		[]any{tenant, viewer, id}, func(br pgx.BatchResults) (err error) {
			out, err = scanCalendarEvent(br.QueryRow())
			return err
		})
	if errors.Is(err, pgx.ErrNoRows) {
		return CalendarEvent{}, ErrNotFound
	}
	return out, err
}

// UpdateCalendarEvent locks the row the viewer can see, applies p in Go (so
// both stores validate one way) and writes every column back.
func (s *Postgres) UpdateCalendarEvent(ctx context.Context, tenant, viewer, id string, p CalendarPatch, now time.Time) (CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return CalendarEvent{}, err
	}
	if !s.hasCalendar(ctx) {
		return CalendarEvent{}, ErrCalendarUnavailable
	}
	if !calendarIDRe.MatchString(id) {
		return CalendarEvent{}, ErrNotFound
	}
	var out CalendarEvent
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		e, err := scanCalendarEvent(tx.QueryRow(ctx, `SELECT `+calendarCols+` FROM calendar_events
			WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarPrivateSQL+` FOR UPDATE`, tenant, viewer, id))
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		} else if err != nil {
			return err
		}
		applyCalendarPatch(&e, p)
		if err := normalizeCalendarEvent(&e); err != nil {
			return err
		}
		out, err = scanCalendarEvent(tx.QueryRow(ctx, `UPDATE calendar_events SET title = $3, description = $4, kind = $5,
				starts_at = $6, ends_at = $7, all_day = $8, audience = $9, mentions = $10, remind_at = $11,
				topic_id = $12, release_version = $13, updated_at = $14
			WHERE tenant_id = $1 AND event_id = $2::uuid
			RETURNING `+calendarCols,
			tenant, id, e.Title, e.Description, e.Kind, e.StartsAt, e.EndsAt, e.AllDay, e.Audience, e.Mentions,
			nullTime(e.RemindAt), nullIfEmpty(e.TopicID), nullIfEmpty(e.ReleaseVersion), now.UTC()))
		return err
	})
	return out, err
}

func (s *Postgres) DeleteCalendarEvent(ctx context.Context, tenant, viewer, id string) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if !s.hasCalendar(ctx) {
		return ErrCalendarUnavailable
	}
	if !calendarIDRe.MatchString(id) {
		return ErrNotFound
	}
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM calendar_events
		WHERE tenant_id = $1 AND event_id = $3::uuid AND `+calendarPrivateSQL, tenant, viewer, id)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

// calendarQuery runs one read of events in the tenant's scope; $1 tenant,
// $2 viewer, then args.
func (s *Postgres) calendarQuery(ctx context.Context, tenant, sql string, args []any) ([]CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	if !s.hasCalendar(ctx) {
		return nil, nil
	}
	var out []CalendarEvent
	err := s.queryTenant(ctx, tenant, sql, args, func(rows pgx.Rows) error {
		e, err := scanCalendarEvent(rows)
		out = append(out, e)
		return err
	})
	return out, err
}

func (s *Postgres) ListCalendarEvents(ctx context.Context, tenant, viewer string, r CalendarRange) ([]CalendarEvent, error) {
	return s.calendarQuery(ctx, tenant, `SELECT `+calendarCols+` FROM calendar_events
		WHERE tenant_id = $1 AND starts_at < $4 AND ends_at >= $3 AND `+calendarPrivateSQL+`
		ORDER BY starts_at, event_id::text LIMIT $5`,
		[]any{tenant, viewer, r.Start, r.End, calendarMaxEvents})
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
	return s.calendarQuery(ctx, tenant, `SELECT `+calendarCols+` FROM calendar_events
		WHERE tenant_id = $1 AND remind_at >= $3 AND remind_at < $4 AND (creator_id = $2 OR $2 = ANY (mentions))
		ORDER BY remind_at, event_id::text LIMIT $5`,
		[]any{tenant, viewer, r.Start, r.End, calendarMaxEvents})
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
