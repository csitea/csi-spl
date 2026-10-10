package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// The signed-out calendar read (owner t1 a3ce2031, msg a8e3d31d; rdb 0158):
// a visitor of a workspace's host who is not signed in reads that
// workspace's public events (called web before the rename of msg bad3799a,
// rdb 0159), and nothing else. It is its own narrow path, not
// the member range read with a filter on top:
//
//   - the SQL names the public audience (and its legacy name web, until rdb
//     0161 maps it), so no other row leaves the database;
//   - it selects only the fields that are safe for the internet (title,
//     description, start, end, all day): never mentions, guests, creator,
//     reminders or the topic link;
//   - it runs in the workspace's RLS scope (queryTenant), so another
//     workspace's web event is not readable either;
//   - specs/112 HUB-4: a synced event (source_key set) of a public roadmap
//     also carries its key and three props keys, roadmap_url, specs and
//     done_lines; the SQL reads only those three of props, and an event
//     that is not public or not synced carries none of the four
//     (webGoalFields).
//
// Single live events only: a web series is not expanded here (a follow-up).

// WebCalendarEvent is one web event as a signed-out visitor reads it.
type WebCalendarEvent struct {
	Title       string
	Description string
	StartsAt    time.Time
	EndsAt      time.Time
	AllDay      bool
	// Goal is the synced event's goal fields (HUB-4), nil on any other.
	Goal *WebCalendarGoal
}

// WebCalendarGoal is what a signed-out visitor reads of a public synced
// event's roadmap link (specs/112 HUB-4): never the rest of its props.
type WebCalendarGoal struct {
	SourceKey  string
	RoadmapURL string
	Specs      []string
	DoneLines  []string
}

// The props keys of a synced event (the hub's calendar_sync.go writes them).
const (
	calPropRoadmapURL = "roadmap_url"
	calPropSpecs      = "specs"
	calPropDoneLines  = "done_lines"
)

// CalendarPropStrings is props[k] as a list of strings, [] when it is
// absent or not one (a stored list reads back as []any).
func CalendarPropStrings(p map[string]any, k string) []string {
	out := []string{}
	switch l := p[k].(type) {
	case []string:
		out = append(out, l...)
	case []any:
		for _, v := range l {
			if s, ok := v.(string); ok {
				out = append(out, s)
			}
		}
	}
	return out
}

// webGoalFields is the goal of a public synced event, nil for an event
// that is not synced or not public: the one gate of the four fields.
func webGoalFields(audience, sourceKey string, props map[string]any) *WebCalendarGoal {
	if sourceKey == "" || CalendarAudienceOf(audience) != CalendarPublic {
		return nil
	}
	url, _ := props[calPropRoadmapURL].(string)
	return &WebCalendarGoal{SourceKey: sourceKey, RoadmapURL: url,
		Specs: CalendarPropStrings(props, calPropSpecs), DoneLines: CalendarPropStrings(props, calPropDoneLines)}
}

// CalendarWebReader is the signed-out read, an optional interface on
// *Memory and *Postgres (type-assert s.store.(store.CalendarWebReader)).
type CalendarWebReader interface {
	// WebCalendarEvents answers the tenant's live single web events that
	// overlap r, by start, at most calendarMaxEvents.
	WebCalendarEvents(ctx context.Context, tenant string, r CalendarRange) ([]WebCalendarEvent, error)
}

var (
	_ CalendarWebReader = (*Memory)(nil)
	_ CalendarWebReader = (*Postgres)(nil)
)

// calendarWebFilterOff is a test-only switch: true drops the audience filter
// from both stores, so the leak test's control can prove it would fail
// without it. Nothing outside a _test.go file sets it.
var calendarWebFilterOff = false

// calendarWebSQL is the audience filter of the signed-out read.
func calendarWebSQL() string {
	if calendarWebFilterOff {
		return `true`
	}
	return `audience IN ('public', 'web')`
}

func webCalendarEventOf(e *CalendarEvent) WebCalendarEvent {
	return WebCalendarEvent{Title: e.Title, Description: e.Description, StartsAt: e.StartsAt, EndsAt: e.EndsAt, AllDay: e.AllDay,
		Goal: webGoalFields(e.Audience, e.SourceKey, e.Props)}
}

func (s *Memory) WebCalendarEvents(_ context.Context, tenant string, r CalendarRange) ([]WebCalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	evs := s.calendarSelectLocked(tenant, func(e *CalendarEvent) bool {
		return (calendarWebFilterOff || e.Audience == CalendarPublic) && calendarSingle(e) && e.DeletedAt.IsZero() && calendarOverlaps(e, r)
	}, byCalendarStart)
	out := make([]WebCalendarEvent, 0, len(evs))
	for i := range evs {
		out = append(out, webCalendarEventOf(&evs[i]))
	}
	return out, nil
}

// WebCalendarEvents: $1 tenant, $2 start, $3 end, $4 limit. Before rdb 0139
// there is no soft delete and no series, so the live and single filters drop;
// before rdb 0156 there is no source_key, so no event carries a goal.
func (s *Postgres) WebCalendarEvents(ctx context.Context, tenant string, r CalendarRange) ([]WebCalendarEvent, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	if !s.hasCalendar(ctx) {
		return []WebCalendarEvent{}, nil
	}
	q := s.calendarShape(ctx)
	sql := `SELECT title, description, starts_at, ends_at, all_day, audience, ` + webGoalSQL(q.key) + ` FROM calendar_events
		WHERE tenant_id = $1 AND starts_at < $3 AND ends_at >= $2 AND ` + calendarWebSQL() + q.live + q.single + `
		ORDER BY starts_at, event_id::text LIMIT $4`
	out := []WebCalendarEvent{}
	err := s.queryTenant(ctx, tenant, sql, []any{tenant, r.Start, r.End, calendarMaxEvents}, func(rows pgx.Rows) error {
		var e WebCalendarEvent
		var audience, key string
		var props map[string]any
		if err := rows.Scan(&e.Title, &e.Description, &e.StartsAt, &e.EndsAt, &e.AllDay, &audience, &key, &props); err != nil {
			return err
		}
		e.StartsAt, e.EndsAt = e.StartsAt.UTC(), e.EndsAt.UTC()
		e.Goal = webGoalFields(audience, key, props)
		out = append(out, e)
		return nil
	})
	return out, err
}

// webGoalSQL selects a row's source_key and only the three goal keys of its
// props, or ” and {} before rdb 0156.
func webGoalSQL(key bool) string {
	if !key {
		return `''::text, '{}'::jsonb`
	}
	return `COALESCE(source_key, ''), jsonb_strip_nulls(jsonb_build_object('` + calPropRoadmapURL + `', props->'` +
		calPropRoadmapURL + `', '` + calPropSpecs + `', props->'` + calPropSpecs + `', '` + calPropDoneLines + `', props->'` + calPropDoneLines + `'))`
}
