package store

import (
	"context"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/097 T009 (spec 4.7): the calendar search. Every filter of a range
// read applies (the workspace, the private filter, deleted_at IS NULL); the
// hub adds the demo filter by asking for public events only. No new index
// in v1: a workspace holds thousands of events, not millions (spec 4.7).
//
// A series matches once, as its next occurrence after the range start, once
// recurrence lands (T006); until then every row is one event.

// CalendarQuery is one search. Text matches title, description and the
// location prop, case-insensitive substring; Guest is the creator or a
// mention (or, with rdb 0139, a calendar_guests row); empty Kinds /
// Audiences match any. The answer overlaps Range, by start then id, after
// the cursor (AfterStart, AfterID) when AfterID is set, at most Limit rows.
type CalendarQuery struct {
	Text       string
	Kinds      []string
	Audiences  []string
	Guest      string
	Range      CalendarRange
	AfterStart time.Time
	AfterID    string
	Limit      int
}

// CalendarSearch is the store side of GET /v1/calendar/search.
type CalendarSearch interface {
	SearchCalendarEvents(ctx context.Context, tenant, viewer string, q CalendarQuery) ([]CalendarEvent, error)
}

var (
	_ CalendarSearch = (*Memory)(nil)
	_ CalendarSearch = (*Postgres)(nil)
)

// calendarSearchLimit is q.Limit capped at calendarMaxEvents; 0 is the cap.
func calendarSearchLimit(n int) int {
	if n <= 0 {
		return calendarMaxEvents
	}
	return min(n, calendarMaxEvents)
}

// calendarMatches is the search predicate in Go (Memory), the same rule as
// calendarSearchSQL's WHERE.
func calendarMatches(e *CalendarEvent, viewer string, q CalendarQuery) bool {
	switch {
	case !e.DeletedAt.IsZero() || !calendarVisible(e, viewer) || !calendarOverlaps(e, q.Range):
	case len(q.Kinds) > 0 && !slices.Contains(q.Kinds, e.Kind):
	case len(q.Audiences) > 0 && !slices.Contains(q.Audiences, e.Audience):
	case q.Guest != "" && !calendarOwnsOrNamed(e, q.Guest):
	case q.AfterID != "" && !calendarAfter(e, q.AfterStart, q.AfterID):
	default:
		return calendarTextMatch(e, q.Text)
	}
	return false
}

// calendarAfter: e sorts after the cursor (starts_at, id).
func calendarAfter(e *CalendarEvent, start time.Time, id string) bool {
	return e.StartsAt.After(start) || (e.StartsAt.Equal(start) && e.ID > id)
}

func calendarTextMatch(e *CalendarEvent, text string) bool {
	if text == "" {
		return true
	}
	t := strings.ToLower(text)
	loc, _ := e.Props["location"].(string)
	for _, f := range []string{e.Title, e.Description, loc} {
		if strings.Contains(strings.ToLower(f), t) {
			return true
		}
	}
	return false
}

func (s *Memory) SearchCalendarEvents(_ context.Context, tenant, viewer string, q CalendarQuery) ([]CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.calendarSelectLocked(tenant, func(e *CalendarEvent) bool {
		return calendarMatches(e, viewer, q)
	}, byCalendarStart)
	if n := calendarSearchLimit(q.Limit); len(out) > n {
		out = out[:n]
	}
	return out, nil
}

// calendarSearchSQL is the statement for this database's shape: $1 tenant,
// $2 viewer, $3/$4 the range, then one argument per filter set.
func calendarSearchSQL(sh calendarSQL, tenant, viewer string, q CalendarQuery) (string, []any) {
	args := []any{tenant, viewer, q.Range.Start, q.Range.End}
	arg := func(v any) string {
		args = append(args, v)
		return "$" + strconv.Itoa(len(args))
	}
	var b strings.Builder
	b.WriteString(`SELECT ` + sh.cols + ` FROM calendar_events
		WHERE tenant_id = $1 AND starts_at < $4 AND ends_at >= $3 AND ` + calendarPrivateSQL + sh.live)
	if q.Text != "" {
		t := `lower(` + arg(q.Text) + `)`
		b.WriteString(` AND (strpos(lower(title), ` + t + `) > 0 OR strpos(lower(description), ` + t + `) > 0`)
		if sh.full {
			b.WriteString(` OR strpos(lower(COALESCE(props->>'location', '')), ` + t + `) > 0`)
		}
		b.WriteString(`)`)
	}
	if len(q.Kinds) > 0 {
		b.WriteString(` AND kind = ANY (` + arg(q.Kinds) + `::text[])`)
	}
	if len(q.Audiences) > 0 {
		b.WriteString(` AND audience = ANY (` + arg(q.Audiences) + `::text[])`)
	}
	if q.Guest != "" {
		g := arg(q.Guest) + `::text`
		b.WriteString(` AND (creator_id = ` + g + ` OR ` + g + ` = ANY (mentions)`)
		if sh.full {
			b.WriteString(` OR EXISTS (SELECT 1 FROM calendar_guests cg WHERE cg.tenant_id = calendar_events.tenant_id
				AND cg.event_id = calendar_events.event_id AND cg.guest_id = ` + g + `)`)
		}
		b.WriteString(`)`)
	}
	if q.AfterID != "" {
		b.WriteString(` AND (starts_at, event_id::text) > (` + arg(q.AfterStart) + `::timestamptz, ` + arg(q.AfterID) + `::text)`)
	}
	b.WriteString(` ORDER BY starts_at, event_id::text LIMIT ` + arg(calendarSearchLimit(q.Limit)))
	return b.String(), args
}

// SearchCalendarEvents reads the tenant's live rows in the range; the
// filters are plain predicates on them (no index of their own in v1).
func (s *Postgres) SearchCalendarEvents(ctx context.Context, tenant, viewer string, q CalendarQuery) ([]CalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	if !s.hasCalendar(ctx) {
		return nil, nil
	}
	sql, args := calendarSearchSQL(s.calendarShape(ctx), tenant, viewer, q)
	var out []CalendarEvent
	err := s.queryTenant(ctx, tenant, sql, args, func(rows pgx.Rows) error {
		e, err := scanCalendarEvent(rows)
		out = append(out, e)
		return err
	})
	return out, err
}
