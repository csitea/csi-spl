package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/jackc/pgx/v5"
)

// Synced calendar events (specs/112 STORE-1, spec 4.2 and 4.3; rdb 0156).
// A sync writes events by their source_key (goal:G01:deadline,
// goal:G01:m:<key>, release:v1.3.0, spec:089:done, db:<topic_id>): a re-run
// of the same batch is an upsert by (tenant_id, source_key), never a
// duplicate, and a row whose fields did not change is left as it is
// (updated_at too). A goal: or spec: key that is no longer in the batch is
// soft-deleted (deleted_at, deleted_by = the row's creator); release: and db:
// keys are never pruned, because the backfill adds them one by one. A key back
// in a later batch brings its row back, same id.
//
// Every synced event names its audience (the 0125 default is public), and a
// db: key is internal only: it carries workspace discussion, which a guest
// must not see (spec 4.3). Synced events are single events: no rrule, no
// guests. The batch is checked whole before anything is written.

// CalendarSyncEvent is one event of a sync batch and its stable key.
type CalendarSyncEvent struct {
	SourceKey string
	Event     CalendarEvent
}

// CalendarSyncResult counts what one sync did. Created + Updated + Unchanged
// is the batch length; Deleted is the goal:/spec: rows it soft-deleted.
type CalendarSyncResult struct {
	Created, Updated, Unchanged, Deleted int
}

// CalendarSync is the sync's store (both stores, the same behaviour).
type CalendarSync interface {
	UpsertCalendarBySourceKey(ctx context.Context, tenant string, batch []CalendarSyncEvent, now time.Time) (CalendarSyncResult, error)
}

var (
	_ CalendarSync = (*Memory)(nil)
	_ CalendarSync = (*Postgres)(nil)
)

// calendarSourceKeyRe is spec 4.2's key families.
var calendarSourceKeyRe = regexp.MustCompile(`^(goal|spec|release|db):[A-Za-z0-9._:-]{1,200}$`)

// calendarPruned: key is in a family a sync owns whole (goal:, spec:).
func calendarPruned(key string) bool {
	return strings.HasPrefix(key, "goal:") || strings.HasPrefix(key, "spec:")
}

// normalizeCalendarSync checks a batch and normalizes its events in place.
func normalizeCalendarSync(batch []CalendarSyncEvent) error {
	bad := func(key, what string) error {
		return fmt.Errorf("%w: source_key %q: %s", ErrInvalidCalendarEvent, key, what)
	}
	if len(batch) > calendarMaxEvents {
		return fmt.Errorf("%w: a sync holds at most %d events", ErrInvalidCalendarEvent, calendarMaxEvents)
	}
	seen := map[string]bool{}
	for i := range batch {
		k, e := batch[i].SourceKey, &batch[i].Event
		switch {
		case !calendarSourceKeyRe.MatchString(k):
			return bad(k, "must be goal:, spec:, release: or db: and 1..200 key characters")
		case seen[k]:
			return bad(k, "is twice in the batch")
		case e.Audience == "":
			return bad(k, "a synced event names its audience")
		case strings.HasPrefix(k, "db:") && e.Audience != CalendarInternal:
			return bad(k, "a db: event is internal only")
		case e.RRule != "" || len(e.Guests) > 0:
			return bad(k, "a synced event has no rrule and no guests")
		}
		seen[k] = true
		if err := normalizeCalendarEvent(e); err != nil {
			return err
		}
	}
	return nil
}

// calendarSyncSame: stored row e already holds the synced event n (the
// fields a sync writes, and live). calendarSyncDiffers is its SQL.
func calendarSyncSame(e, n *CalendarEvent) bool {
	pa, _ := json.Marshal(e.Props)
	pb, _ := json.Marshal(n.Props)
	return e.Title == n.Title && e.Description == n.Description && e.Kind == n.Kind &&
		e.StartsAt.Equal(n.StartsAt) && e.EndsAt.Equal(n.EndsAt) && e.AllDay == n.AllDay &&
		e.Audience == n.Audience && slices.Equal(e.Mentions, n.Mentions) &&
		e.CreatorType == n.CreatorType && e.CreatorID == n.CreatorID && e.RemindAt.Equal(n.RemindAt) &&
		e.TopicID == n.TopicID && e.ReleaseVersion == n.ReleaseVersion && string(pa) == string(pb) &&
		e.TimeZone == n.TimeZone && e.DeletedAt.IsZero()
}

// UpsertCalendarBySourceKey writes a sync batch (see above).
func (s *Memory) UpsertCalendarBySourceKey(_ context.Context, tenant string, batch []CalendarSyncEvent, now time.Time) (CalendarSyncResult, error) {
	var res CalendarSyncResult
	if err := checkTenant(tenant); err != nil {
		return res, err
	}
	batch = slices.Clone(batch)
	if err := normalizeCalendarSync(batch); err != nil {
		return res, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return res, ErrNotFound
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
	inBatch := map[string]bool{}
	for i := range batch {
		k, n := batch[i].SourceKey, cloneCalendarEvent(&batch[i].Event)
		inBatch[k] = true
		old, ok := s.cal.events[tenant][s.cal.keys[tenant][k]]
		switch {
		case !ok:
			n.ID, n.CreatedAt = uuid.New(), at
			res.Created++
		case calendarSyncSame(old, &n):
			res.Unchanged++
			continue
		default:
			n.ID, n.CreatedAt = old.ID, old.CreatedAt
			res.Updated++
		}
		n.UpdatedAt, n.DeletedAt, n.DeletedBy = at, time.Time{}, ""
		n.SourceKey = k
		n.RecurringEventID, n.OriginalStart, n.Status = "", time.Time{}, CalendarConfirmed
		s.cal.events[tenant][n.ID] = &n
		s.cal.keys[tenant][k] = n.ID
	}
	for k, id := range s.cal.keys[tenant] {
		e := s.cal.events[tenant][id]
		if !inBatch[k] && calendarPruned(k) && e.DeletedAt.IsZero() {
			e.DeletedAt, e.DeletedBy = at, e.CreatorID
			res.Deleted++
		}
	}
	return res, nil
}

// calendarSyncDiffers compares the columns a sync writes, stored against
// incoming, for ON CONFLICT ... WHERE: a row is rewritten only when one of
// them differs or it is deleted (calendarSyncSame in Go).
const calendarSyncDiffers = `(calendar_events.title, calendar_events.description, calendar_events.kind,
		calendar_events.starts_at, calendar_events.ends_at, calendar_events.all_day, calendar_events.audience,
		calendar_events.mentions, calendar_events.creator_type, calendar_events.creator_id, calendar_events.remind_at,
		calendar_events.topic_id, calendar_events.release_version, calendar_events.props, calendar_events.time_zone,
		calendar_events.deleted_at IS NOT NULL)
	IS DISTINCT FROM (EXCLUDED.title, EXCLUDED.description, EXCLUDED.kind, EXCLUDED.starts_at, EXCLUDED.ends_at,
		EXCLUDED.all_day, EXCLUDED.audience, EXCLUDED.mentions, EXCLUDED.creator_type, EXCLUDED.creator_id,
		EXCLUDED.remind_at, EXCLUDED.topic_id, EXCLUDED.release_version, EXCLUDED.props, EXCLUDED.time_zone, false)`

// calendarSyncUpsert writes one keyed event and answers whether it inserted;
// no row when the stored one is the same.
const calendarSyncUpsert = `INSERT INTO calendar_events (tenant_id, source_key, title, description, kind,
		starts_at, ends_at, all_day, audience, mentions, creator_type, creator_id, remind_at, topic_id,
		release_version, props, time_zone, created_at, updated_at)
	VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $18)
	ON CONFLICT (tenant_id, source_key) WHERE source_key IS NOT NULL DO UPDATE SET
		title = EXCLUDED.title, description = EXCLUDED.description, kind = EXCLUDED.kind,
		starts_at = EXCLUDED.starts_at, ends_at = EXCLUDED.ends_at, all_day = EXCLUDED.all_day,
		audience = EXCLUDED.audience, mentions = EXCLUDED.mentions, creator_type = EXCLUDED.creator_type,
		creator_id = EXCLUDED.creator_id, remind_at = EXCLUDED.remind_at, topic_id = EXCLUDED.topic_id,
		release_version = EXCLUDED.release_version, props = EXCLUDED.props, time_zone = EXCLUDED.time_zone,
		updated_at = EXCLUDED.updated_at, deleted_at = NULL, deleted_by = NULL
	WHERE ` + calendarSyncDiffers + `
	RETURNING xmax = 0`

// calendarSyncPrune soft-deletes the live goal:/spec: rows whose key is not in $2.
const calendarSyncPrune = `UPDATE calendar_events SET deleted_at = $3, deleted_by = creator_id
	WHERE tenant_id = $1 AND deleted_at IS NULL AND (source_key LIKE 'goal:%' OR source_key LIKE 'spec:%')
		AND NOT (source_key = ANY ($2::text[]))`

// calendarHasSourceKey is the catalogue probe for rdb 0156.
const calendarHasSourceKey = `SELECT EXISTS (SELECT 1 FROM pg_attribute
	WHERE attrelid = to_regclass('calendar_events') AND attname = 'source_key' AND NOT attisdropped)`

// UpsertCalendarBySourceKey writes a sync batch (see above) in one
// transaction; ErrCalendarUnavailable until rdb 0156 reaches the database.
func (s *Postgres) UpsertCalendarBySourceKey(ctx context.Context, tenant string, batch []CalendarSyncEvent, now time.Time) (CalendarSyncResult, error) {
	var res CalendarSyncResult
	if err := checkTenant(tenant); err != nil {
		return res, err
	}
	batch = slices.Clone(batch)
	if err := normalizeCalendarSync(batch); err != nil {
		return res, err
	}
	if !s.hasCalendar(ctx) {
		return res, ErrCalendarUnavailable
	}
	at := calendarNow(now)
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		res = CalendarSyncResult{}
		var has bool
		if err := tx.QueryRow(ctx, calendarHasSourceKey).Scan(&has); err != nil {
			return err
		}
		if !has {
			return ErrCalendarUnavailable
		}
		b := &pgx.Batch{}
		keys := make([]string, 0, len(batch))
		for _, x := range batch {
			e := x.Event
			keys = append(keys, x.SourceKey)
			b.Queue(calendarSyncUpsert, tenant, x.SourceKey, e.Title, e.Description, e.Kind, e.StartsAt, e.EndsAt,
				e.AllDay, e.Audience, e.Mentions, e.CreatorType, e.CreatorID, nullTime(e.RemindAt),
				nullIfEmpty(e.TopicID), nullIfEmpty(e.ReleaseVersion), e.Props, e.TimeZone, at)
		}
		b.Queue(calendarSyncPrune, tenant, keys, at)
		br := tx.SendBatch(ctx, b)
		defer br.Close()
		for range batch {
			var inserted bool
			switch err := br.QueryRow().Scan(&inserted); {
			case errors.Is(err, pgx.ErrNoRows):
				res.Unchanged++
			case err != nil:
				return err
			case inserted:
				res.Created++
			default:
				res.Updated++
			}
		}
		tag, err := br.Exec()
		if err != nil {
			return err
		}
		res.Deleted = int(tag.RowsAffected())
		return br.Close()
	})
	if err != nil {
		return CalendarSyncResult{}, err
	}
	return res, nil
}
