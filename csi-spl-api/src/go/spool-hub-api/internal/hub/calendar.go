package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The calendar section's routes (specs/089 T004; spec section 6, wire format
// 6.1). The store (store/calendar.go, T003) holds the private filter; the hub
// adds what only a session knows:
//
//   - owner-only private (FR-010): a PATCH that moves audience to or from
//     private by anyone but the event's creator is 403 private_owner_only,
//     an admin and the workspace owner included. A create is by its owner.
//   - a demo visitor reads public events only and writes nothing
//     (403 demo_read_only).
//   - issues.deadline rows join the range answer and the marks, read only.
//
// Reminders are the WUI's own timer (D4): this file serves the list and
// sends nothing: no frame, no spool message, no notification
// (TestCalendarSendsNothing).

const (
	calendarMaxBody         = 32 << 10
	calendarMaxRangeDays    = 400
	calendarMaxReminderDays = 31
	calendarMaxYears        = 5
	calendarMaxMentions     = 50
	calendarMentionMax      = 64

	calendarSourceEvent  = "event"
	calendarSourceIssue  = "issue"
	calendarKindDeadline = "deadline"
	calendarDefaultKind  = "other"
)

// calendarEventJSON is the one item shape of spec 6.1.1.
type calendarEventJSON struct {
	ID             string   `json:"id"`
	Source         string   `json:"source"`
	Title          string   `json:"title"`
	Description    string   `json:"description"`
	Kind           string   `json:"kind"`
	StartsAt       string   `json:"starts_at"`
	EndsAt         string   `json:"ends_at"`
	AllDay         bool     `json:"all_day"`
	Audience       string   `json:"audience"`
	Mentions       []string `json:"mentions"`
	CreatorType    string   `json:"creator_type"`
	CreatorID      string   `json:"creator_id"`
	RemindAt       string   `json:"remind_at"`
	TopicID        string   `json:"topic_id"`
	ReleaseVersion string   `json:"release_version"`
	IssueKey       string   `json:"issue_key"`
	CreatedAt      string   `json:"created_at"`
	UpdatedAt      string   `json:"updated_at"`
}

type calendarMarkJSON struct {
	Day   string   `json:"day"`
	Count int      `json:"count"`
	Kinds []string `json:"kinds"`
}

type calendarOfficialJSON struct {
	Day   string `json:"day"`
	Title string `json:"title"`
}

func optCalTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return rfc(t)
}

func toCalendarJSON(e store.CalendarEvent) calendarEventJSON {
	mentions := e.Mentions
	if mentions == nil {
		mentions = []string{}
	}
	return calendarEventJSON{ID: e.ID, Source: calendarSourceEvent, Title: e.Title, Description: e.Description,
		Kind: e.Kind, StartsAt: rfc(e.StartsAt), EndsAt: rfc(e.EndsAt), AllDay: e.AllDay, Audience: e.Audience,
		Mentions: mentions, CreatorType: e.CreatorType, CreatorID: e.CreatorID, RemindAt: optCalTime(e.RemindAt),
		TopicID: e.TopicID, ReleaseVersion: e.ReleaseVersion, CreatedAt: rfc(e.CreatedAt), UpdatedAt: rfc(e.UpdatedAt)}
}

// deadlineJSON is an issue's deadline as a read-only grid item.
func deadlineJSON(i store.Issue) calendarEventJSON {
	at := rfc(*i.Deadline)
	return calendarEventJSON{ID: i.Key(), Source: calendarSourceIssue, Title: i.Title, Description: i.Description,
		Kind: calendarKindDeadline, StartsAt: at, EndsAt: at, Audience: store.CalendarPublic, Mentions: []string{},
		CreatorType: "human", CreatorID: i.CreatedBy, IssueKey: i.Key(), CreatedAt: rfc(i.CreatedAt), UpdatedAt: rfc(i.UpdatedAt)}
}

// ---- requests --------------------------------------------------------------------

// calendarRequest is the event body of a create and of a PATCH (spec 6.1.2):
// an absent field is left alone; remind_at, topic_id, release_version "" clear.
type calendarRequest struct {
	Title          *string   `json:"title"`
	Description    *string   `json:"description"`
	Kind           *string   `json:"kind"`
	StartsAt       *string   `json:"starts_at"`
	EndsAt         *string   `json:"ends_at"`
	AllDay         *bool     `json:"all_day"`
	Audience       *string   `json:"audience"`
	Mentions       *[]string `json:"mentions"`
	RemindAt       *string   `json:"remind_at"`
	TopicID        *string   `json:"topic_id"`
	ReleaseVersion *string   `json:"release_version"`
}

func badCalendar(detail string) *issueErr {
	return &issueErr{http.StatusBadRequest, "bad_event", detail}
}

func badCalendarRange(detail string) *issueErr {
	return &issueErr{http.StatusBadRequest, "bad_range", detail}
}

// optCalTimePtr parses a set RFC 3339 time field into UTC; with clearable,
// "" is the zero time (remind_at clears).
func optCalTimePtr(name string, v *string, clearable bool) (*time.Time, *issueErr) {
	if v == nil {
		return nil, nil
	}
	if clearable && strings.TrimSpace(*v) == "" {
		return &time.Time{}, nil
	}
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(*v))
	if err != nil {
		return nil, badCalendar(name + " must be RFC 3339 with a zone, e.g. 2026-10-05T09:00:00Z")
	}
	t = t.UTC()
	return &t, nil
}

// calMentions trims, drops empties and repeats, and checks the limits.
func calMentions(in []string) ([]string, *issueErr) {
	out := make([]string, 0, len(in))
	for _, m := range in {
		m = strings.TrimSpace(m)
		if m == "" || slices.Contains(out, m) {
			continue
		}
		if utf8.RuneCountInString(m) > calendarMentionMax {
			return nil, badCalendar("a mention is at most 64 characters")
		}
		out = append(out, m)
	}
	if len(out) > calendarMaxMentions {
		return nil, badCalendar("an event names at most 50 mentions")
	}
	return out, nil
}

// patch turns the request into a store patch (shape checks; the store checks
// the rest of rdb 0125's rules).
func (q calendarRequest) patch() (store.CalendarPatch, *issueErr) {
	p := store.CalendarPatch{Title: q.Title, Description: q.Description, Kind: q.Kind, AllDay: q.AllDay,
		Audience: q.Audience, TopicID: q.TopicID, ReleaseVersion: q.ReleaseVersion}
	var ie *issueErr
	if p.StartsAt, ie = optCalTimePtr("starts_at", q.StartsAt, false); ie != nil {
		return p, ie
	}
	if p.EndsAt, ie = optCalTimePtr("ends_at", q.EndsAt, false); ie != nil {
		return p, ie
	}
	if p.RemindAt, ie = optCalTimePtr("remind_at", q.RemindAt, true); ie != nil {
		return p, ie
	}
	if q.Mentions != nil {
		m, ie := calMentions(*q.Mentions)
		if ie != nil {
			return p, ie
		}
		p.Mentions = &m
	}
	return p, nil
}

// calendarPatchEmpty: the PATCH changes nothing.
func calendarPatchEmpty(p store.CalendarPatch) bool {
	return p.Title == nil && p.Description == nil && p.Kind == nil && p.StartsAt == nil && p.EndsAt == nil &&
		p.AllDay == nil && p.Audience == nil && p.Mentions == nil && p.RemindAt == nil && p.TopicID == nil &&
		p.ReleaseVersion == nil
}

// newEvent is a create: the defaults of spec 6.1.2 (kind other, audience
// public) under the request's fields; the caller is the owner.
func (q calendarRequest) newEvent(actor string) (store.CalendarEvent, *issueErr) {
	if q.Title == nil || q.StartsAt == nil || q.EndsAt == nil {
		return store.CalendarEvent{}, badCalendar("title, starts_at and ends_at are required")
	}
	p, ie := q.patch()
	if ie != nil {
		return store.CalendarEvent{}, ie
	}
	e := store.CalendarEvent{Kind: calendarDefaultKind, Audience: store.CalendarPublic, Mentions: []string{},
		CreatorType: "human", CreatorID: actor, StartsAt: *p.StartsAt, EndsAt: *p.EndsAt}
	for _, f := range []struct{ dst, src *string }{{&e.Title, p.Title}, {&e.Description, p.Description},
		{&e.Kind, p.Kind}, {&e.Audience, p.Audience}, {&e.TopicID, p.TopicID}, {&e.ReleaseVersion, p.ReleaseVersion}} {
		if f.src != nil && *f.src != "" {
			*f.dst = *f.src
		}
	}
	if p.AllDay != nil {
		e.AllDay = *p.AllDay
	}
	if p.Mentions != nil {
		e.Mentions = *p.Mentions
	}
	if p.RemindAt != nil {
		e.RemindAt = *p.RemindAt
	}
	return e, nil
}

func decodeCalendarRequest(w http.ResponseWriter, r *http.Request) (calendarRequest, bool) {
	var q calendarRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, calendarMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be a calendar event (spec 089 section 6.1)")
		return q, false
	}
	return q, true
}

func calendarUnavailable() *issueErr {
	return &issueErr{http.StatusServiceUnavailable, "calendar_unavailable", "this environment has no calendar yet"}
}

// storeCalendarErr maps a store refusal (T003's errors).
func storeCalendarErr(err error) *issueErr {
	switch {
	case errors.Is(err, store.ErrInvalidCalendarEvent):
		return badCalendar(strings.TrimPrefix(err.Error(), store.ErrInvalidCalendarEvent.Error()+": "))
	case errors.Is(err, store.ErrNotFound):
		return &issueErr{http.StatusNotFound, "not_found", "no such event"}
	case errors.Is(err, store.ErrCalendarUnavailable):
		return calendarUnavailable()
	}
	return &issueErr{http.StatusInternalServerError, "internal", "calendar not stored"}
}

// ---- ranges ----------------------------------------------------------------------

// calendarRange reads [?a, ?b) of at most maxDays.
func calendarRange(r *http.Request, a, b string, maxDays int) (store.CalendarRange, *issueErr) {
	q := r.URL.Query()
	start, err1 := time.Parse(time.RFC3339, q.Get(a))
	end, err2 := time.Parse(time.RFC3339, q.Get(b))
	switch {
	case err1 != nil || err2 != nil:
		return store.CalendarRange{}, badCalendarRange(a + " and " + b + " must be RFC 3339 times with a zone")
	case !start.Before(end):
		return store.CalendarRange{}, badCalendarRange(a + " must be before " + b)
	case end.Sub(start) > time.Duration(maxDays)*24*time.Hour:
		return store.CalendarRange{}, badCalendarRange("the range is at most " + strconv.Itoa(maxDays) + " days")
	}
	return store.CalendarRange{Start: start.UTC(), End: end.UTC()}, nil
}

// calendarYears reads ?start_year=&end_year= as [Jan 1 start, Jan 1 end+1).
func calendarYears(r *http.Request) (int, int, store.CalendarRange, *issueErr) {
	q := r.URL.Query()
	from, err1 := strconv.Atoi(q.Get("start_year"))
	to, err2 := strconv.Atoi(q.Get("end_year"))
	if err1 != nil || err2 != nil || from < 1000 || to > 9998 || from > to || to-from >= calendarMaxYears {
		return 0, 0, store.CalendarRange{}, badCalendarRange("start_year and end_year are 4-digit years, at most 5 years apart")
	}
	rg := store.CalendarRange{Start: time.Date(from, 1, 1, 0, 0, 0, 0, time.UTC), End: time.Date(to+1, 1, 1, 0, 0, 0, 0, time.UTC)}
	return from, to, rg, nil
}

// ---- reads -----------------------------------------------------------------------

// calendarStore is the store's calendar, nil when it keeps none: reads then
// answer empty and writes 503, like an env without rdb 0125.
func (s *Server) calendarStore() store.Calendar {
	c, _ := s.o.Store.(store.Calendar)
	return c
}

// calendarViewer is who reads: the session's human, and whether it is a demo
// visitor (public events only).
func (s *Server) calendarViewer(r *http.Request, t store.Tenant) (string, bool) {
	hum, _ := s.memberID(r, t.ID)
	return hum, s.isDemoVisitor(r.Context(), t.ID, hum)
}

// visibleTo drops what a demo visitor may not see: everything but public (the
// store already dropped the private events it is not named on).
func visibleTo(evs []store.CalendarEvent, demo bool) []store.CalendarEvent {
	if !demo {
		return evs
	}
	return slices.DeleteFunc(evs, func(e store.CalendarEvent) bool { return e.Audience != store.CalendarPublic })
}

// deadlinesIn is the workspace's issue deadlines inside rg (read only here).
func (s *Server) deadlinesIn(ctx context.Context, tenant string, rg store.CalendarRange) ([]store.Issue, error) {
	is, ok := s.o.Store.(store.Issues)
	if !ok {
		return nil, nil
	}
	all, err := is.ListIssues(ctx, tenant)
	if err != nil {
		return nil, err
	}
	return slices.DeleteFunc(all, func(i store.Issue) bool {
		return i.Deadline == nil || i.Deadline.Before(rg.Start) || !i.Deadline.Before(rg.End)
	}), nil
}

func (s *Server) calendarFail(w http.ResponseWriter, tenant, what string, err error) {
	s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("calendar " + what)
	writeErrCause(w, http.StatusInternalServerError, "internal", "calendar not read", err)
}

// listCalendar is the viewer's events in rg.
func (s *Server) listCalendar(ctx context.Context, tenant, viewer string, demo bool, rg store.CalendarRange) ([]store.CalendarEvent, error) {
	c := s.calendarStore()
	if c == nil {
		return nil, nil
	}
	evs, err := c.ListCalendarEvents(ctx, tenant, viewer, rg)
	return visibleTo(evs, demo), err
}

// GET /v1/calendar/events?start=&end=
func (s *Server) handleCalendarEvents(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	rg, ie := calendarRange(r, "start", "end", calendarMaxRangeDays)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	viewer, demo := s.calendarViewer(r, t)
	evs, err := s.listCalendar(r.Context(), t.ID, viewer, demo, rg)
	if err != nil {
		s.calendarFail(w, t.ID, "list", err)
		return
	}
	dls, err := s.deadlinesIn(r.Context(), t.ID, rg)
	if err != nil {
		s.calendarFail(w, t.ID, "deadlines", err)
		return
	}
	out := make([]calendarEventJSON, 0, len(evs)+len(dls))
	for _, e := range evs {
		out = append(out, toCalendarJSON(e))
	}
	for _, i := range dls {
		out = append(out, deadlineJSON(i))
	}
	sort.SliceStable(out, func(a, b int) bool {
		if out[a].StartsAt != out[b].StartsAt {
			return out[a].StartsAt < out[b].StartsAt
		}
		return out[a].ID < out[b].ID
	})
	writeJSON(w, http.StatusOK, map[string]any{"start": rfc(rg.Start), "end": rfc(rg.End), "events": out})
}

// calendarMarks counts per UTC day: the store's marks, or for a demo visitor
// its public events only.
func (s *Server) calendarMarks(ctx context.Context, tenant, viewer string, demo bool, rg store.CalendarRange) (map[string]*calendarMarkJSON, error) {
	marks := map[string]*calendarMarkJSON{}
	c := s.calendarStore()
	if c == nil {
		return marks, nil
	}
	if !demo {
		ms, err := c.CalendarMarks(ctx, tenant, viewer, rg)
		for _, m := range ms {
			marks[m.Day] = &calendarMarkJSON{Day: m.Day, Count: m.Count, Kinds: slices.Clone(m.Kinds)}
		}
		return marks, err
	}
	evs, err := s.listCalendar(ctx, tenant, viewer, demo, rg)
	for _, e := range evs {
		for _, d := range eventDays(e, rg) {
			addMark(marks, d, e.Kind)
		}
	}
	return marks, err
}

func addMark(marks map[string]*calendarMarkJSON, day, kind string) {
	m := marks[day]
	if m == nil {
		m = &calendarMarkJSON{Day: day}
		marks[day] = m
	}
	m.Count++
	if !slices.Contains(m.Kinds, kind) {
		m.Kinds = append(m.Kinds, kind)
	}
}

// eventDays lists the UTC days e covers inside rg; an event ending exactly at
// midnight does not cover the day it ends on (the store's rule).
func eventDays(e store.CalendarEvent, rg store.CalendarRange) []string {
	last := e.EndsAt
	if last.After(e.StartsAt) {
		last = last.Add(-time.Microsecond)
	}
	if !last.Before(rg.End) {
		last = rg.End.Add(-time.Microsecond)
	}
	d := e.StartsAt
	if d.Before(rg.Start) {
		d = rg.Start
	}
	var out []string
	for d = d.UTC().Truncate(24 * time.Hour); !d.After(last); d = d.Add(24 * time.Hour) {
		out = append(out, d.Format(time.DateOnly))
	}
	return out
}

// GET /v1/calendar/marks?start_year=&end_year=
func (s *Server) handleCalendarMarks(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	from, to, rg, ie := calendarYears(r)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	viewer, demo := s.calendarViewer(r, t)
	marks, err := s.calendarMarks(r.Context(), t.ID, viewer, demo, rg)
	if err != nil {
		s.calendarFail(w, t.ID, "marks", err)
		return
	}
	dls, err := s.deadlinesIn(r.Context(), t.ID, rg)
	if err != nil {
		s.calendarFail(w, t.ID, "deadlines", err)
		return
	}
	for _, i := range dls {
		addMark(marks, i.Deadline.UTC().Format(time.DateOnly), calendarKindDeadline)
	}
	days := make([]calendarMarkJSON, 0, len(marks))
	for _, m := range marks {
		if m.Kinds == nil {
			m.Kinds = []string{}
		}
		sort.Strings(m.Kinds)
		days = append(days, *m)
	}
	sort.Slice(days, func(a, b int) bool { return days[a].Day < days[b].Day })
	// Official-day tints need the workspace's region, which stays empty until
	// T011 sets one: no region, no tints (spec 4.1).
	writeJSON(w, http.StatusOK, map[string]any{"start_year": from, "end_year": to, "days": days,
		"official_days": []calendarOfficialJSON{}})
}

// GET /v1/calendar/reminders?from=&to=
func (s *Server) handleCalendarReminders(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	rg, ie := calendarRange(r, "from", "to", calendarMaxReminderDays)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	viewer, demo := s.calendarViewer(r, t)
	out := []calendarEventJSON{}
	if c := s.calendarStore(); c != nil && viewer != "" {
		evs, err := c.CalendarReminders(r.Context(), t.ID, viewer, rg)
		if err != nil {
			s.calendarFail(w, t.ID, "reminders", err)
			return
		}
		for _, e := range visibleTo(evs, demo) {
			out = append(out, toCalendarJSON(e))
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"from": rfc(rg.Start), "to": rfc(rg.End), "reminders": out})
}

// ---- writes ----------------------------------------------------------------------

// calendarWriter resolves a browser write: workspace, actor, notes.send, not
// a demo visitor, a paying workspace, a store with a calendar.
func (s *Server) calendarWriter(w http.ResponseWriter, r *http.Request) (store.Tenant, string, store.Calendar, bool) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok || !s.permit(w, r, t.ID, hum, rbac.NotesSend) {
		return t, "", nil, false
	}
	if s.isDemoVisitor(r.Context(), t.ID, hum) {
		writeErr(w, http.StatusForbidden, "demo_read_only", "a demo visit reads the calendar but does not change it")
		return t, "", nil, false
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return t, "", nil, false
	}
	c := s.calendarStore()
	if c == nil {
		writeIssueErr(w, calendarUnavailable())
		return t, "", nil, false
	}
	actor := hum
	if actor == "" {
		actor = "wui" // the door-off rig
	}
	return t, actor, c, true
}

func (s *Server) writeCalendarErr(w http.ResponseWriter, tenant, what string, err error) {
	ie := storeCalendarErr(err)
	if ie.status == http.StatusInternalServerError {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("calendar " + what)
	}
	writeIssueErr(w, ie)
}

// POST /v1/calendar/events
func (s *Server) handleCreateCalendarEvent(w http.ResponseWriter, r *http.Request) {
	t, actor, c, ok := s.calendarWriter(w, r)
	if !ok {
		return
	}
	q, ok := decodeCalendarRequest(w, r)
	if !ok {
		return
	}
	e, ie := q.newEvent(actor)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	out, err := c.CreateCalendarEvent(r.Context(), t.ID, e, s.o.Now())
	if err != nil {
		s.writeCalendarErr(w, t.ID, "create", err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"event": toCalendarJSON(out)})
}

// privateOwnerOnly (FR-010): moving audience to or from private is the event
// owner's action alone; no role overrides it.
func privateOwnerOnly(cur store.CalendarEvent, p store.CalendarPatch, actor string) *issueErr {
	if p.Audience == nil || *p.Audience == cur.Audience || cur.CreatorID == actor {
		return nil
	}
	if *p.Audience != store.CalendarPrivate && cur.Audience != store.CalendarPrivate {
		return nil
	}
	return &issueErr{http.StatusForbidden, "private_owner_only", "only the event's owner sets or clears private"}
}

// PATCH /v1/calendar/events/{id}
func (s *Server) handlePatchCalendarEvent(w http.ResponseWriter, r *http.Request) {
	t, actor, c, ok := s.calendarWriter(w, r)
	if !ok {
		return
	}
	q, ok := decodeCalendarRequest(w, r)
	if !ok {
		return
	}
	p, ie := q.patch()
	if ie == nil && calendarPatchEmpty(p) {
		ie = badCalendar("nothing to change")
	}
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	id := r.PathValue("id")
	cur, err := c.GetCalendarEvent(r.Context(), t.ID, actor, id)
	if err != nil {
		s.writeCalendarErr(w, t.ID, "get", err)
		return
	}
	if ie := privateOwnerOnly(cur, p, actor); ie != nil {
		writeIssueErr(w, ie)
		return
	}
	out, err := c.UpdateCalendarEvent(r.Context(), t.ID, actor, id, p, s.o.Now())
	if err != nil {
		s.writeCalendarErr(w, t.ID, "update", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(out)})
}

// DELETE /v1/calendar/events/{id}: 200 with the event as it was.
func (s *Server) handleDeleteCalendarEvent(w http.ResponseWriter, r *http.Request) {
	t, actor, c, ok := s.calendarWriter(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	cur, err := c.GetCalendarEvent(r.Context(), t.ID, actor, id)
	if err == nil {
		err = c.DeleteCalendarEvent(r.Context(), t.ID, actor, id)
	}
	if err != nil {
		s.writeCalendarErr(w, t.ID, "delete", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(cur)})
}

func (s *Server) calendarPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeCalendar(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/calendar/events", s.viewHandler(s.handleCalendarEvents))
	mux.HandleFunc("GET /v1/calendar/marks", s.viewHandler(s.handleCalendarMarks))
	mux.HandleFunc("GET /v1/calendar/reminders", s.viewHandler(s.handleCalendarReminders))
	mux.HandleFunc("POST /v1/calendar/events", s.handleCreateCalendarEvent)
	mux.HandleFunc("PATCH /v1/calendar/events/{id}", s.handlePatchCalendarEvent)
	mux.HandleFunc("DELETE /v1/calendar/events/{id}", s.handleDeleteCalendarEvent)
	mux.HandleFunc("OPTIONS /v1/calendar/events", s.calendarPreflight)
	mux.HandleFunc("OPTIONS /v1/calendar/events/{id}", s.calendarPreflight)
	mux.HandleFunc("OPTIONS /v1/calendar/marks", s.calendarPreflight)
	mux.HandleFunc("OPTIONS /v1/calendar/reminders", s.calendarPreflight)
}

// routeWorkItems registers the issues (specs/039) and the calendar that
// shows their deadlines (specs/089), one line in Handler.
func (s *Server) routeWorkItems(mux *http.ServeMux) {
	s.routeIssues(mux)
	s.routeCalendar(mux)
}
