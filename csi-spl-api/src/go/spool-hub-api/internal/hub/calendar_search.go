package hub

import (
	"encoding/base64"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// GET /v1/calendar/search (specs/097 T009, spec 4.7): q matches title,
// description and location; kind and audience may repeat; guest is a human
// or agent id (owner, mention or guest); from / to default to one year back
// and one year ahead, at most 5 years apart; limit 1..100, default 50;
// cursor is the last answer's next_cursor. The answer is
// {"events": [...], "next_cursor": ""}, by starts_at. The store applies the
// workspace, the private filter and deleted_at; a demo visitor searches
// public events only (the store is asked for public alone, so a page is
// never short of a demo row it then drops). A series matches once after
// T006 (recurrence); until then every row is one event.

const (
	calendarSearchDefault  = 50
	calendarSearchMax      = 100
	calendarSearchTextMax  = 200
	calendarSearchValues   = 20 // repeats of kind or of audience
	calendarSearchValueMax = 64
)

func badCalendarSearch(detail string) *issueErr {
	return &issueErr{http.StatusBadRequest, "bad_query", detail}
}

// calendarSearchRange reads from / to, each defaulting around now.
func calendarSearchRange(v url.Values, now time.Time) (store.CalendarRange, *issueErr) {
	rg := store.CalendarRange{Start: now.AddDate(-1, 0, 0).UTC(), End: now.AddDate(1, 0, 0).UTC()}
	for _, f := range []struct {
		name string
		dst  *time.Time
	}{{"from", &rg.Start}, {"to", &rg.End}} {
		if s := strings.TrimSpace(v.Get(f.name)); s != "" {
			t, err := time.Parse(time.RFC3339, s)
			if err != nil {
				return rg, badCalendarRange(f.name + " must be an RFC 3339 time with a zone")
			}
			*f.dst = t.UTC()
		}
	}
	switch {
	case !rg.Start.Before(rg.End):
		return rg, badCalendarRange("from must be before to")
	case rg.Start.AddDate(calendarMaxYears, 0, 0).Before(rg.End):
		return rg, badCalendarRange("from and to are at most 5 years apart")
	}
	return rg, nil
}

// calendarSearchValuesOf is a repeated parameter, trimmed, empties dropped.
func calendarSearchValuesOf(name string, vs []string) ([]string, *issueErr) {
	var out []string
	for _, v := range vs {
		if v = strings.TrimSpace(v); v != "" && !slices.Contains(out, v) {
			out = append(out, v)
		}
	}
	if len(out) > calendarSearchValues {
		return nil, badCalendarSearch(name + " repeats at most 20 times")
	}
	for _, v := range out {
		if utf8.RuneCountInString(v) > calendarSearchValueMax {
			return nil, badCalendarSearch(name + " is at most 64 characters")
		}
	}
	return out, nil
}

// calendarSearchAudiences checks audience values against rdb 0125's set.
func calendarSearchAudiences(vs []string) ([]string, *issueErr) {
	out, ie := calendarSearchValuesOf("audience", vs)
	for _, a := range out {
		if a != store.CalendarPublic && a != store.CalendarInternal && a != store.CalendarPrivate {
			return nil, badCalendarSearch("audience must be public, internal or private")
		}
	}
	return out, ie
}

func calendarSearchLimit(s string) (int, *issueErr) {
	if s = strings.TrimSpace(s); s == "" {
		return calendarSearchDefault, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 || n > calendarSearchMax {
		return 0, badCalendarSearch("limit must be 1..100")
	}
	return n, nil
}

// calendarCursor is "<starts_at>\n<id>" of the last event of a page,
// base64url: opaque to the caller, the store's keyset to the hub.
func calendarCursor(e store.CalendarEvent) string {
	return base64.RawURLEncoding.EncodeToString([]byte(e.StartsAt.UTC().Format(time.RFC3339Nano) + "\n" + e.ID))
}

func readCalendarCursor(s string, q *store.CalendarQuery) *issueErr {
	if s = strings.TrimSpace(s); s == "" {
		return nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(s)
	at, id, ok := strings.Cut(string(raw), "\n")
	t, terr := time.Parse(time.RFC3339Nano, at)
	if err != nil || !ok || terr != nil || id == "" || len(id) > calendarSearchValueMax {
		return &issueErr{http.StatusBadRequest, "bad_cursor", "cursor must be a next_cursor of this call"}
	}
	q.AfterStart, q.AfterID = t.UTC(), id
	return nil
}

// calendarSearchQuery reads the query string into a store query.
func calendarSearchQuery(r *http.Request, now time.Time) (store.CalendarQuery, *issueErr) {
	v := r.URL.Query()
	var q store.CalendarQuery
	var ie *issueErr
	if q.Text = strings.TrimSpace(v.Get("q")); utf8.RuneCountInString(q.Text) > calendarSearchTextMax {
		return q, badCalendarSearch("q is at most 200 characters")
	}
	if q.Guest = strings.TrimSpace(v.Get("guest")); utf8.RuneCountInString(q.Guest) > calendarSearchValueMax {
		return q, badCalendarSearch("guest is at most 64 characters")
	}
	if q.Kinds, ie = calendarSearchValuesOf("kind", v["kind"]); ie != nil {
		return q, ie
	}
	if q.Audiences, ie = calendarSearchAudiences(v["audience"]); ie != nil {
		return q, ie
	}
	if q.Range, ie = calendarSearchRange(v, now); ie != nil {
		return q, ie
	}
	if q.Limit, ie = calendarSearchLimit(v.Get("limit")); ie != nil {
		return q, ie
	}
	return q, readCalendarCursor(v.Get("cursor"), &q)
}

// demoAudiences narrows a demo visitor's search to public; false when the
// asked audiences leave nothing it may read.
func demoAudiences(q *store.CalendarQuery) bool {
	if len(q.Audiences) > 0 && !slices.Contains(q.Audiences, store.CalendarPublic) {
		return false
	}
	q.Audiences = []string{store.CalendarPublic}
	return true
}

// searchCalendar runs q and answers one page and the next page's cursor.
func (s *Server) searchCalendar(r *http.Request, tenant, viewer string, q store.CalendarQuery) ([]store.CalendarEvent, string, error) {
	srch, ok := s.o.Store.(store.CalendarSearch)
	if !ok {
		return nil, "", nil
	}
	want := q.Limit
	q.Limit = want + 1 // one more tells whether a next page exists
	evs, err := srch.SearchCalendarEvents(r.Context(), tenant, viewer, q)
	if err != nil || len(evs) <= want {
		return evs, "", err
	}
	evs = evs[:want]
	return evs, calendarCursor(evs[want-1]), nil
}

func (s *Server) handleCalendarSearch(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	now := s.o.Now()
	q, ie := calendarSearchQuery(r, now)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	viewer, demo := s.calendarViewer(r, t)
	out, next := []calendarEventJSON{}, ""
	if !demo || demoAudiences(&q) {
		evs, cur, err := s.searchCalendar(r, t.ID, viewer, q)
		if err != nil {
			s.calendarFail(w, t.ID, "search", err)
			return
		}
		for _, e := range evs {
			out = append(out, toCalendarJSON(e, now))
		}
		next = cur
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": out, "next_cursor": next})
}

// routeCalendarSearch is the search's route, one line in routeCalendar.
func (s *Server) routeCalendarSearch(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/calendar/search", s.viewHandler(s.handleCalendarSearch))
	mux.HandleFunc("OPTIONS /v1/calendar/search", s.calendarPreflight)
}
