package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"time"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/jackc/pgx/v5"
)

// GcalImport writes the events the Google Calendar sync brings in (spec 149
// section 2.5 "In", build row B6b, SPL-3339): one Spool event per Google
// item of the member's "Spool Hub" calendar, keyed by source_key
// `gcal:<connection_id>:<google id>`. A re-import of the same item is an
// upsert by (tenant, key), never a duplicate; a row whose fields did not
// change keeps its updated_at; a trashed row comes back, same id.
//
// It is its own entry point, not UpsertCalendarBySourceKey: that batch is
// also the member route PUT /v1/calendar/sync (spec 112), whose key families
// (calendarSourceKeyRe) stay goal:, spec:, release: and db:, so no member can
// write a gcal: row. An imported event is the member's private event: human
// creator, audience private, no guests, no exception row; it may repeat
// (rrule, the Google series' RRULE line). A cancelled item is the caller's
// TrashCalendarEvent.
type GcalImport interface {
	// PutGcalImported upserts the imported event of key and answers it as
	// stored (live). ErrInvalidCalendarEvent for a key or event the rules
	// above refuse; ErrConflict when key names an event of another creator.
	PutGcalImported(ctx context.Context, tenant, key string, e CalendarEvent, now time.Time) (CalendarEvent, error)
}

var (
	_ GcalImport = (*Memory)(nil)
	_ GcalImport = (*Postgres)(nil)
)

// gcalImportKeyRe is the imported key: gcal:, the connection uuid, a Google
// event id of visible ASCII characters (1..gcalGoogleIDMax of them,
// normalizeGcalImport: Go's regexp repeats at most 1000).
var gcalImportKeyRe = regexp.MustCompile(`^gcal:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[!-~]+$`)

// gcalGoogleIDMax is rdb 0217's google_id bound.
const gcalGoogleIDMax = 1024

// gcalImportKeyLen is the key length before the Google id.
const gcalImportKeyLen = len("gcal:") + 36 + len(":")

// normalizeGcalImport checks key and e and normalizes e in place.
func normalizeGcalImport(key string, e *CalendarEvent) error {
	bad := func(what string) error {
		return fmt.Errorf("%w: imported event %q: %s", ErrInvalidCalendarEvent, key, what)
	}
	switch {
	case !gcalImportKeyRe.MatchString(key) || len(key) > gcalImportKeyLen+gcalGoogleIDMax:
		return bad("the key must be gcal:<connection>:<google id>")
	case e.Audience != CalendarPrivate || e.CreatorType != "human":
		return bad("an imported event is the member's private event")
	case len(e.Guests) > 0 || len(e.Mentions) > 0 || e.RecurringEventID != "":
		return bad("an imported event has no guests, no mentions and is no exception row")
	}
	e.Status = CalendarConfirmed
	return normalizeCalendarEvent(e)
}

// gcalImportSame: stored row o already holds the imported event n, live.
func gcalImportSame(o, n *CalendarEvent) bool {
	return o.Title == n.Title && o.Description == n.Description && o.Kind == n.Kind &&
		o.StartsAt.Equal(n.StartsAt) && o.EndsAt.Equal(n.EndsAt) && o.AllDay == n.AllDay &&
		o.TimeZone == n.TimeZone && o.RRule == n.RRule && o.DeletedAt.IsZero()
}

// PutGcalImported upserts the import in the tenant's events, found by its key.
func (s *Memory) PutGcalImported(_ context.Context, tenant, key string, e CalendarEvent, now time.Time) (CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return CalendarEvent{}, err
	}
	if err := normalizeGcalImport(key, &e); err != nil {
		return CalendarEvent{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return CalendarEvent{}, ErrNotFound
	}
	if s.cal.events == nil {
		s.cal.events = map[string]map[string]*CalendarEvent{}
	}
	if s.cal.keys == nil {
		s.cal.keys = map[string]map[string]string{}
	}
	if s.cal.events[tenant] == nil {
		s.cal.events[tenant] = map[string]*CalendarEvent{}
	}
	if s.cal.keys[tenant] == nil {
		s.cal.keys[tenant] = map[string]string{}
	}
	at := calendarNow(now)
	old, ok := s.cal.events[tenant][s.cal.keys[tenant][key]]
	switch {
	case ok && old.CreatorID != e.CreatorID:
		return CalendarEvent{}, ErrConflict
	case ok && gcalImportSame(old, &e):
		return cloneCalendarEvent(old), nil
	case ok:
		e.ID, e.CreatedAt = old.ID, old.CreatedAt
	default:
		e.ID, e.CreatedAt = uuid.New(), at
	}
	n := cloneCalendarEvent(&e)
	n.UpdatedAt, n.DeletedAt, n.DeletedBy, n.SourceKey = at, time.Time{}, "", key
	n.RemindAt, n.TopicID, n.ReleaseVersion = time.Time{}, "", ""
	n.OriginalStart = time.Time{}
	s.cal.events[tenant][n.ID] = &n
	s.cal.keys[tenant][key] = n.ID
	return cloneCalendarEvent(&n), nil
}

// gcalImportDiffers compares the columns an import writes (gcalImportSame
// in Go): updated_at moves only when one of them differs or the row was
// trashed.
const gcalImportDiffers = `(calendar_events.title, calendar_events.description, calendar_events.kind,
		calendar_events.starts_at, calendar_events.ends_at, calendar_events.all_day, calendar_events.time_zone,
		calendar_events.rrule, calendar_events.deleted_at IS NOT NULL)
	IS DISTINCT FROM (EXCLUDED.title, EXCLUDED.description, EXCLUDED.kind, EXCLUDED.starts_at,
		EXCLUDED.ends_at, EXCLUDED.all_day, EXCLUDED.time_zone, EXCLUDED.rrule, false)`

// gcalImportUpsert writes one imported event and answers its row; no row
// when the key belongs to another creator. The select list follows.
const gcalImportUpsert = `INSERT INTO calendar_events (tenant_id, source_key, title, description, kind,
		starts_at, ends_at, all_day, audience, mentions, creator_type, creator_id, props, time_zone,
		rrule, recur_until, created_at, updated_at)
	VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'private', '{}', 'human', $9, '{}'::jsonb, $10, $11, $12, $13, $13)
	ON CONFLICT (tenant_id, source_key) WHERE source_key IS NOT NULL DO UPDATE SET
		title = EXCLUDED.title, description = EXCLUDED.description, kind = EXCLUDED.kind,
		starts_at = EXCLUDED.starts_at, ends_at = EXCLUDED.ends_at, all_day = EXCLUDED.all_day,
		time_zone = EXCLUDED.time_zone, rrule = EXCLUDED.rrule, recur_until = EXCLUDED.recur_until,
		updated_at = CASE WHEN ` + gcalImportDiffers + ` THEN EXCLUDED.updated_at ELSE calendar_events.updated_at END,
		deleted_at = NULL, deleted_by = NULL
	WHERE calendar_events.creator_id = EXCLUDED.creator_id
	RETURNING `

// PutGcalImported is one statement in the tenant's scope;
// ErrCalendarUnavailable until rdb 0156 (source_key) reaches the database.
func (s *Postgres) PutGcalImported(ctx context.Context, tenant, key string, e CalendarEvent, now time.Time) (CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return CalendarEvent{}, err
	}
	if err := normalizeGcalImport(key, &e); err != nil {
		return CalendarEvent{}, err
	}
	if !s.hasCalendar(ctx) {
		return CalendarEvent{}, ErrCalendarUnavailable
	}
	q := s.calendarShape(ctx)
	if !q.full || !q.key {
		return CalendarEvent{}, ErrCalendarUnavailable
	}
	args := []any{tenant, key, e.Title, e.Description, e.Kind, e.StartsAt, e.EndsAt, e.AllDay, e.CreatorID,
		e.TimeZone, nullIfEmpty(e.RRule), nullTime(e.RecurUntil), calendarNow(now)}
	var out CalendarEvent
	err := s.tenantBatch(ctx, tenant, gcalImportUpsert+q.cols, args, func(br pgx.BatchResults) (err error) {
		out, err = scanCalendarEvent(br.QueryRow())
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return CalendarEvent{}, ErrConflict
	}
	return out, err
}
