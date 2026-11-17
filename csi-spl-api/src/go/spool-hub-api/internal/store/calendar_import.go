package store

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// An imported calendar (spec 180 FR-4, FR-5): one member's events from an
// outside calendar (the Outlook export), written by key like a roadmap sync
// (calendar_sync.go) and pruned by window. Every key of a batch starts with
// the window's prefix (outlook:<owner>:), so one member's import never
// touches another's rows. After the upsert, a live row with that prefix that
// starts inside [From, To) and is not in the batch is soft-deleted, deleted_by
// = By (a moved or cancelled meeting); a row outside the window is never
// touched. A key back in a later batch brings its row back, same id. Unlike a
// roadmap sync, an import writes owner_id on insert (the member).

// CalendarImportWindow is an import's scope: the key prefix it owns, the
// window [From, To) it prunes in, and who a prune names as deleted_by.
type CalendarImportWindow struct {
	Prefix   string
	From, To time.Time
	By       string
}

// CalendarImport is the import's store (both stores, the same behaviour).
type CalendarImport interface {
	ImportCalendarBySourceKey(ctx context.Context, tenant string, win CalendarImportWindow, batch []CalendarSyncEvent, now time.Time) (CalendarSyncResult, error)
}

// CalendarSyncMaxEvents is the most events one sync or import batch holds.
const CalendarSyncMaxEvents = calendarMaxEvents

var (
	_ CalendarImport = (*Memory)(nil)
	_ CalendarImport = (*Postgres)(nil)
)

// checkCalendarImport checks the window and the batch, normalizing it in place.
func checkCalendarImport(win CalendarImportWindow, batch []CalendarSyncEvent) error {
	switch {
	case !calendarOutlookKey(win.Prefix) || !strings.HasSuffix(win.Prefix, ":") || strings.Count(win.Prefix, ":") != 2:
		return fmt.Errorf("%w: an import prefix is outlook:<owner>:", ErrInvalidCalendarEvent)
	case win.From.IsZero() || win.To.Before(win.From):
		return fmt.Errorf("%w: an import window has from <= to", ErrInvalidCalendarEvent)
	case win.By == "":
		return fmt.Errorf("%w: an import names who deletes", ErrInvalidCalendarEvent)
	}
	return normalizeCalendarSync(batch, win.Prefix)
}

// calendarImportPrunes: e is a live row of win's prefix that starts inside
// the window and is not in the batch.
func calendarImportPrunes(win CalendarImportWindow, key string, e *CalendarEvent, inBatch map[string]bool) bool {
	return !inBatch[key] && strings.HasPrefix(key, win.Prefix) && e.DeletedAt.IsZero() &&
		!e.StartsAt.Before(win.From) && e.StartsAt.Before(win.To)
}

// ImportCalendarBySourceKey writes an import batch (see above).
func (s *Memory) ImportCalendarBySourceKey(_ context.Context, tenant string, win CalendarImportWindow, batch []CalendarSyncEvent, now time.Time) (CalendarSyncResult, error) {
	var res CalendarSyncResult
	if err := checkTenant(tenant); err != nil {
		return res, err
	}
	batch = slices.Clone(batch)
	if err := checkCalendarImport(win, batch); err != nil {
		return res, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return res, ErrNotFound
	}
	at := calendarNow(now)
	res, inBatch := s.upsertCalendarKeyedLocked(tenant, batch, at)
	for k, id := range s.cal.keys[tenant] {
		if e := s.cal.events[tenant][id]; calendarImportPrunes(win, k, e, inBatch) {
			e.DeletedAt, e.DeletedBy = at, win.By
			res.Deleted++
		}
	}
	return res, nil
}

// calendarImportUpsert is calendarSyncUpsert that also writes owner_id on
// insert ($19); an update leaves it, as a sync does.
const calendarImportUpsert = `INSERT INTO calendar_events (tenant_id, source_key, title, description, kind,
		starts_at, ends_at, all_day, audience, mentions, creator_type, creator_id, remind_at, topic_id,
		release_version, props, time_zone, created_at, updated_at, owner_id)
	VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $18, $19)
	ON CONFLICT (tenant_id, source_key) WHERE source_key IS NOT NULL DO UPDATE SET
		title = EXCLUDED.title, description = EXCLUDED.description, kind = EXCLUDED.kind,
		starts_at = EXCLUDED.starts_at, ends_at = EXCLUDED.ends_at, all_day = EXCLUDED.all_day,
		audience = EXCLUDED.audience, mentions = EXCLUDED.mentions, creator_type = EXCLUDED.creator_type,
		creator_id = EXCLUDED.creator_id, remind_at = EXCLUDED.remind_at, topic_id = EXCLUDED.topic_id,
		release_version = EXCLUDED.release_version, props = EXCLUDED.props, time_zone = EXCLUDED.time_zone,
		updated_at = EXCLUDED.updated_at, deleted_at = NULL, deleted_by = NULL
	WHERE ` + calendarSyncDiffers + `
	RETURNING xmax = 0`

// calendarImportPrune soft-deletes the live rows of prefix $5 that start in
// [$6, $7) and are not in $2. left(), not LIKE: '_' is a key character.
const calendarImportPrune = `UPDATE calendar_events SET deleted_at = $3, deleted_by = $4
	WHERE tenant_id = $1 AND deleted_at IS NULL AND source_key IS NOT NULL
		AND left(source_key, length($5)) = $5 AND starts_at >= $6 AND starts_at < $7
		AND NOT (source_key = ANY ($2::text[]))`

// ImportCalendarBySourceKey writes an import batch (see above) in one
// transaction; ErrCalendarUnavailable until rdb 0156 and 0247 reach the db.
func (s *Postgres) ImportCalendarBySourceKey(ctx context.Context, tenant string, win CalendarImportWindow, batch []CalendarSyncEvent, now time.Time) (CalendarSyncResult, error) {
	if err := checkTenant(tenant); err != nil {
		return CalendarSyncResult{}, err
	}
	batch = slices.Clone(batch)
	if err := checkCalendarImport(win, batch); err != nil {
		return CalendarSyncResult{}, err
	}
	if !s.hasCalendar(ctx) {
		return CalendarSyncResult{}, ErrCalendarUnavailable
	}
	keys := make([]string, 0, len(batch))
	for _, x := range batch {
		keys = append(keys, x.SourceKey)
	}
	at := calendarNow(now)
	return s.upsertCalendarKeyed(ctx, tenant, batch, calendarKeyedSQL{
		upsert: func(b *pgx.Batch, x CalendarSyncEvent) {
			e := x.Event
			b.Queue(calendarImportUpsert, tenant, x.SourceKey, e.Title, e.Description, e.Kind, e.StartsAt, e.EndsAt,
				e.AllDay, e.Audience, e.Mentions, e.CreatorType, e.CreatorID, nullTime(e.RemindAt),
				nullIfEmpty(e.TopicID), nullIfEmpty(e.ReleaseVersion), e.Props, e.TimeZone, at, e.OwnerID)
		},
		prune:     calendarImportPrune,
		pruneArgs: []any{tenant, keys, at, win.By, win.Prefix, win.From.UTC(), win.To.UTC()},
		probe:     calendarHasOwnerID,
	})
}
