package store

import (
	"context"
	"sort"
	"strings"
)

// The read side of synced events (specs/112 HUB-1, spec 4.2 "Lookup"): the
// live events whose source_key starts with a prefix (goal:G01:), as the
// viewer may read them, by start then id. The event list's ?source_key=
// filter reads it, so the WUI never guesses an event id, and the sync route
// reads it to carry a key family the batch does not send (hub
// calendar_sync.go). Until rdb 0156 reaches a database it answers empty.

// CalendarSourced is that read (both stores, the same behaviour).
type CalendarSourced interface {
	CalendarBySourceKey(ctx context.Context, tenant, viewer, prefix string) ([]CalendarEvent, error)
}

var (
	_ CalendarSourced = (*Memory)(nil)
	_ CalendarSourced = (*Postgres)(nil)
)

// sortCalendarEvents orders by start, then id.
func sortCalendarEvents(evs []CalendarEvent) {
	sort.Slice(evs, func(i, j int) bool {
		if !evs[i].StartsAt.Equal(evs[j].StartsAt) {
			return evs[i].StartsAt.Before(evs[j].StartsAt)
		}
		return evs[i].ID < evs[j].ID
	})
}

func (s *Memory) CalendarBySourceKey(_ context.Context, tenant, viewer, prefix string) ([]CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []CalendarEvent
	for _, e := range s.cal.events[tenant] {
		if e.SourceKey != "" && strings.HasPrefix(e.SourceKey, prefix) && e.DeletedAt.IsZero() && calendarVisible(e, viewer) {
			out = append(out, cloneCalendarEvent(e))
		}
	}
	sortCalendarEvents(out)
	if len(out) > calendarMaxEvents {
		return nil, ErrCalendarTooMany
	}
	return out, nil
}

// CalendarBySourceKey compares with left(), not LIKE: '_' is a key character.
func (s *Postgres) CalendarBySourceKey(ctx context.Context, tenant, viewer, prefix string) ([]CalendarEvent, error) {
	if !s.hasCalendar(ctx) || !s.calendarShape(ctx).key {
		return nil, checkTenant(tenant)
	}
	out, err := s.calendarQuery(ctx, tenant, func(q calendarSQL) string {
		return `SELECT ` + q.cols + ` FROM calendar_events
		WHERE tenant_id = $1 AND source_key IS NOT NULL AND left(source_key, length($3)) = $3
			AND ` + calendarPrivateSQL + q.live + `
		ORDER BY starts_at, event_id::text LIMIT $4`
	}, []any{tenant, viewer, prefix, calendarMaxEvents + 1})
	if err == nil && len(out) > calendarMaxEvents {
		return nil, ErrCalendarTooMany
	}
	return out, err
}
