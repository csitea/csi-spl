package hub

import (
	"context"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// calendarSection is the workspace's calendar entries (spec 100 section 15,
// SPL-6251), through the calendar search's own store query
// (store.CalendarSearch, the one GET /v1/calendar/search runs): the
// workspace, the private filter (a private entry only for its creator and
// the people it names) and deleted_at, so a hit is one the reader sees on the
// calendar. A demo visitor reads workspace and public entries only
// (demoAudiences), as on that route. The query's longest top-level word
// narrows the store read (a substring of the title, the description or the
// location, case-insensitive, as the calendar's own search matches); the
// whole query then filters the page, so OR, - and name: work as in every
// section. One year back to one year ahead (the calendar
// search's default range), by start, paged by the store's (starts_at, id)
// keyset. The row opens the entry in the calendar.
func (s *Server) calendarSection(ctx context.Context, tenant string, q *search.Query, sq store.SearchQuery, c searchCursor, limit int) (section, error) {
	out := section{Results: []any{}}
	cs, ok := s.o.Store.(store.CalendarSearch)
	if !ok {
		return out, nil
	}
	cq := store.CalendarQuery{Text: calendarStoreWord(q.Root),
		Range:      store.CalendarRange{Start: sq.Now.AddDate(-1, 0, 0).UTC(), End: sq.Now.AddDate(1, 0, 0).UTC()},
		AfterStart: c.At, AfterID: c.ID, Limit: limit + 1}
	if s.isDemoVisitor(ctx, tenant, sq.Viewer) && !demoAudiences(&cq) {
		return out, nil
	}
	evs, err := cs.SearchCalendarEvents(ctx, tenant, sq.Viewer, cq)
	if err != nil {
		return out, err
	}
	if len(evs) > limit {
		evs = evs[:limit]
		last := evs[limit-1]
		out.Next = searchCursor{T: c.T, H: c.H, At: last.StartsAt, ID: last.ID}.enc()
	}
	for _, e := range evs {
		loc := propsString(e, calPropLocation)
		ent := search.Entity{Type: search.TypeCalendar, Name: e.Title, Text: []string{e.Title, e.Description, loc}}
		if !search.MatchEntity(q.Root, ent) {
			continue
		}
		text, hs := q.Snippet(e.Description)
		out.Results = append(out.Results, map[string]any{"id": e.ID, "kind": e.Kind, "audience": e.Audience,
			"starts_at": rfc(e.StartsAt), "ends_at": rfc(e.EndsAt), "all_day": e.AllDay, "location": strPtr(loc),
			"title": hl{e.Title, q.HighlightSubstrings(e.Title)}, "snippet": hl{text, hs}})
	}
	return out, nil
}

// calendarStoreWord is the one word every calendar hit must hold, for the
// store to narrow by: the longest positive text term at the query's top
// level (a lone term, or a term of its top AND), a phrase whole. Terms under
// OR or - are left to the filter; "" reads the range unnarrowed.
func calendarStoreWord(root *search.Node) string {
	if root == nil {
		return ""
	}
	terms := []*search.Node{root}
	if root.Kind == search.And {
		terms = root.Kids
	}
	best := ""
	for _, n := range terms {
		if n.Kind != search.Leaf || n.Term.Op != search.OpText {
			continue
		}
		if w := strings.TrimSuffix(n.Term.Value, "*"); utf8.RuneCountInString(w) > utf8.RuneCountInString(best) {
			best = w
		}
	}
	return best
}
