package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/calrecur"
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
//
// specs/097 T004 grows it without changing a field's meaning (FR-001): the
// event object's new fields (spec 4.1) at their defaults, time_zone and the
// props registry (calendar_props.go) on the body, several reminders,
// If-Match on PATCH and DELETE (409 edit_conflict with the current event), a
// soft DELETE, POST .../restore and GET /v1/calendar/trash.
//
// specs/097 T006 adds recurrence (spec 4.4): rrule on the body (the calrecur
// subset, else 400 bad_event), occurrences on the range, marks and reminders
// reads (the store expands them; past 2000 in one range it is 400 bad_range),
// and ?scope=this|following|all on PATCH and DELETE of a series id or an
// occurrence id <event_id>_<YYYYMMDDTHHMMSSZ>.
//
// specs/097 T007 adds guests (spec 4.5, calendar_guests.go): guests on
// create and PATCH (members and agents of this workspace, kept in mentions),
// guests and my_response on the event object, and POST .../rsvp.

const (
	calendarMaxBody         = 32 << 10
	calendarMaxRangeDays    = 400
	calendarMaxReminderDays = 31
	calendarMaxYears        = 5
	calendarMaxMentions     = 50
	calendarMentionMax      = 64
	calendarTrashDays       = 30 // spec 4.8 (Q6)
	calendarPatchTries      = 3  // a PATCH without If-Match re-reads on a race

	calendarSourceEvent  = "event"
	calendarSourceIssue  = "issue"
	calendarKindDeadline = "deadline"
	calendarDefaultKind  = "other"
)

// calendarEventJSON is the one item shape of spec 6.1.1, plus 097's 4.1.
type calendarEventJSON struct {
	ID               string              `json:"id"`
	Source           string              `json:"source"`
	Title            string              `json:"title"`
	Description      string              `json:"description"`
	Kind             string              `json:"kind"`
	StartsAt         string              `json:"starts_at"`
	EndsAt           string              `json:"ends_at"`
	AllDay           bool                `json:"all_day"`
	Audience         string              `json:"audience"`
	Mentions         []string            `json:"mentions"`
	CreatorType      string              `json:"creator_type"`
	CreatorID        string              `json:"creator_id"`
	RemindAt         string              `json:"remind_at"`
	TopicID          string              `json:"topic_id"`
	ReleaseVersion   string              `json:"release_version"`
	IssueKey         string              `json:"issue_key"`
	CreatedAt        string              `json:"created_at"`
	UpdatedAt        string              `json:"updated_at"`
	TimeZone         string              `json:"time_zone"`
	RRule            string              `json:"rrule"`
	RecurringEventID string              `json:"recurring_event_id"`
	OriginalStart    string              `json:"original_start"`
	Location         string              `json:"location"`
	Color            string              `json:"color"`
	Reminders        []calendarReminder  `json:"reminders"`
	Guests           []calendarGuestJSON `json:"guests"`
	MyResponse       string              `json:"my_response"`
	DeletedAt        string              `json:"deleted_at"`
	// specs/112 HUB-1: a synced event's key ("" = a member's event, which
	// alone may be changed here) and its roadmap link.
	SourceKey  string `json:"source_key"`
	RoadmapURL string `json:"roadmap_url"`
}

// calendarGuestJSON is one guest and their answer (spec 4.1).
type calendarGuestJSON struct {
	Type     string `json:"type"`
	ID       string `json:"id"`
	Response string `json:"response"`
	Comment  string `json:"comment"`
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

// toCalendarJSON is a stored event on the wire as viewer reads it (their own
// answer in my_response); now picks remind_at's earliest coming reminder.
func toCalendarJSON(e store.CalendarEvent, now time.Time, viewer string) calendarEventJSON {
	mentions := e.Mentions
	if mentions == nil {
		mentions = []string{}
	}
	tz := e.TimeZone
	if tz == "" {
		tz = store.CalendarUTC
	}
	guests, mine := calendarGuestsJSON(e, viewer)
	return calendarEventJSON{ID: e.ID, Source: calendarSourceEvent, Title: e.Title, Description: e.Description,
		Kind: e.Kind, StartsAt: rfc(e.StartsAt), EndsAt: rfc(e.EndsAt), AllDay: e.AllDay, Audience: e.Audience,
		Mentions: mentions, CreatorType: e.CreatorType, CreatorID: e.CreatorID, RemindAt: optCalTime(wireRemindAt(e, now)),
		TopicID: e.TopicID, ReleaseVersion: e.ReleaseVersion, CreatedAt: rfc(e.CreatedAt), UpdatedAt: rfc(e.UpdatedAt),
		TimeZone: tz, RRule: e.RRule, RecurringEventID: e.RecurringEventID, OriginalStart: optCalTime(e.OriginalStart),
		Location: propsString(e, calPropLocation), Color: propsString(e, calPropColor),
		Reminders: eventReminders(e), Guests: guests, MyResponse: mine, DeletedAt: optCalTime(e.DeletedAt),
		SourceKey: e.SourceKey, RoadmapURL: propsString(e, calPropRoadmapURL)}
}

// calendarGuestsJSON is e's guests on the wire, the owner never listed (spec
// 4.1), and viewer's own answer ("" when they are not a guest).
func calendarGuestsJSON(e store.CalendarEvent, viewer string) ([]calendarGuestJSON, string) {
	out, mine := []calendarGuestJSON{}, ""
	for _, g := range e.Guests {
		if g.ID == e.CreatorID {
			continue
		}
		out = append(out, calendarGuestJSON{Type: g.Type, ID: g.ID, Response: g.Response, Comment: g.Comment})
		if viewer != "" && g.ID == viewer {
			mine = g.Response
		}
	}
	return out, mine
}

// deadlineJSON is an issue's deadline as a read-only grid item.
func deadlineJSON(i store.Issue) calendarEventJSON {
	at := rfc(*i.Deadline)
	return calendarEventJSON{ID: i.Key(), Source: calendarSourceIssue, Title: i.Title, Description: i.Description,
		Kind: calendarKindDeadline, StartsAt: at, EndsAt: at, Audience: store.CalendarPublic, Mentions: []string{},
		CreatorType: "human", CreatorID: i.CreatedBy, IssueKey: i.Key(), CreatedAt: rfc(i.CreatedAt), UpdatedAt: rfc(i.UpdatedAt),
		TimeZone: store.CalendarUTC, Reminders: []calendarReminder{}, Guests: []calendarGuestJSON{}}
}

// ---- requests --------------------------------------------------------------------

// calendarRequest is the event body of a create and of a PATCH (spec 6.1.2):
// an absent field is left alone; remind_at, topic_id, release_version "" clear.
// 097 4.2 adds time_zone, location, color and reminders ("" / [] reset them)
// and props, the registry's keys as one object (a typed field wins over it);
// T006 adds rrule ("" ends the repeat); T007 guests (on PATCH the full new
// list) and notify_guests (read by the notices, T008).
type calendarRequest struct {
	Title          *string            `json:"title"`
	Description    *string            `json:"description"`
	Kind           *string            `json:"kind"`
	StartsAt       *string            `json:"starts_at"`
	EndsAt         *string            `json:"ends_at"`
	AllDay         *bool              `json:"all_day"`
	Audience       *string            `json:"audience"`
	Mentions       *[]string          `json:"mentions"`
	RemindAt       *string            `json:"remind_at"`
	TopicID        *string            `json:"topic_id"`
	ReleaseVersion *string            `json:"release_version"`
	TimeZone       *string            `json:"time_zone"`
	Location       *string            `json:"location"`
	Color          *string            `json:"color"`
	Reminders      *[]any             `json:"reminders"`
	Props          map[string]any     `json:"props"`
	RRule          *string            `json:"rrule"`
	Guests         *[]calendarGuestIn `json:"guests"`
	NotifyGuests   *bool              `json:"notify_guests"`
}

// calendarGuestIn is one guest of a create or PATCH body (spec 4.2).
type calendarGuestIn struct {
	Type string `json:"type"`
	ID   string `json:"id"`
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

// patch turns the request into a store patch against cur, the event as
// stored (zero for a create): shape checks, the props registry and the
// reminders' remind_at column; the store checks the rest of rdb 0125's rules.
func (q calendarRequest) patch(cur store.CalendarEvent) (store.CalendarPatch, *issueErr) {
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
	if q.TimeZone != nil {
		tz := strings.TrimSpace(*q.TimeZone)
		if tz == "" {
			tz = store.CalendarUTC
		}
		if ie := checkTimeZone(tz); ie != nil {
			return p, ie
		}
		p.TimeZone = &tz
	}
	if q.RRule != nil {
		rule := strings.TrimPrefix(strings.TrimSpace(*q.RRule), "RRULE:")
		if _, err := calrecur.Parse(rule); rule != "" && err != nil {
			return p, badCalendar("rrule: " + strings.TrimPrefix(err.Error(), calrecur.ErrBadRule.Error()+": "))
		}
		p.RRule = &rule
	}
	return p, q.patchProps(cur, &p)
}

// propsSet is what the request writes into props: props, then the typed
// fields over it, then remind_at as reminders unless reminders is sent.
func (q calendarRequest) propsSet(start time.Time, remindAt *time.Time) (map[string]any, *issueErr) {
	set := map[string]any{}
	for k, v := range q.Props {
		set[k] = v
	}
	for k, v := range map[string]*string{calPropLocation: q.Location, calPropColor: q.Color} {
		if v != nil {
			set[k] = *v
		}
	}
	if q.Reminders != nil {
		set[calPropReminders] = *q.Reminders
	}
	if _, sent := set[calPropReminders]; !sent && remindAt != nil {
		rs, ie := remindAtAsReminders(*remindAt, start)
		if ie != nil {
			return nil, ie
		}
		set[calPropReminders] = rs
	}
	return set, nil
}

// patchProps sets p.Props and, when the reminders or the start change, the
// remind_at column (the earliest fire time). A move keeps an 089 event's
// remind_at as many minutes before the new start.
func (q calendarRequest) patchProps(cur store.CalendarEvent, p *store.CalendarPatch) *issueErr {
	start := cur.StartsAt
	if p.StartsAt != nil {
		start = *p.StartsAt
	}
	set, ie := q.propsSet(start, p.RemindAt)
	if ie != nil {
		return ie
	}
	_, hasStored := storedReminders(cur)
	if _, sent := set[calPropReminders]; !sent && p.StartsAt != nil && !hasStored {
		if r, ok := legacyReminder(cur.RemindAt, cur.StartsAt); ok {
			set[calPropReminders] = []any{map[string]any{"amount": float64(r.Amount), "unit": r.Unit}}
		}
	}
	p.RemindAt = nil
	if len(set) == 0 && (p.StartsAt == nil || !hasStored) {
		return nil
	}
	merged, ie := mergeCalendarProps(cur.Props, set)
	if ie != nil {
		return ie
	}
	p.Props = &merged
	if rs, ok := storedReminders(store.CalendarEvent{Props: merged}); ok || hasStored || set[calPropReminders] != nil {
		at := remindAtColumn(rs, start)
		p.RemindAt = &at
	}
	return nil
}

// calendarPatchEmpty: the PATCH changes nothing.
func calendarPatchEmpty(p store.CalendarPatch) bool {
	return p.Title == nil && p.Description == nil && p.Kind == nil && p.StartsAt == nil && p.EndsAt == nil &&
		p.AllDay == nil && p.Audience == nil && p.Mentions == nil && p.RemindAt == nil && p.TopicID == nil &&
		p.ReleaseVersion == nil && p.Props == nil && p.TimeZone == nil && p.RRule == nil && p.Guests == nil
}

// calendarGuestList checks the body's guests (trimmed, no repeats, at most 50)
// and drops the event's owner, who is never a guest of their own event.
func calendarGuestList(in []calendarGuestIn, owner, actor string) ([]store.CalendarGuest, *issueErr) {
	out := []store.CalendarGuest{}
	for _, g := range in {
		g.Type, g.ID = strings.TrimSpace(g.Type), strings.TrimSpace(g.ID)
		switch {
		case g.Type != "human" && g.Type != "agent":
			return nil, badCalendar("a guest's type is human or agent")
		case g.ID == "" || utf8.RuneCountInString(g.ID) > calendarMentionMax:
			return nil, badCalendar("a guest's id is 1..64 characters")
		case g.ID == owner || slices.ContainsFunc(out, func(x store.CalendarGuest) bool { return x.ID == g.ID }):
			continue
		}
		out = append(out, store.CalendarGuest{Type: g.Type, ID: g.ID, InvitedBy: actor})
	}
	if len(out) > calendarMaxMentions {
		return nil, badCalendar("an event has at most 50 guests")
	}
	return out, nil
}

// patchGuests sets p.Guests and keeps mentions in step (spec 3.2): a dropped
// guest leaves mentions, a new one joins them. cur is the event as stored
// (zero for a create, whose owner is actor).
func (q calendarRequest) patchGuests(cur store.CalendarEvent, actor string, p *store.CalendarPatch) *issueErr {
	if q.Guests == nil {
		return nil
	}
	owner := cur.CreatorID
	if owner == "" {
		owner = actor
	}
	gs, ie := calendarGuestList(*q.Guests, owner, actor)
	if ie != nil {
		return ie
	}
	mentions := cur.Mentions
	if p.Mentions != nil {
		mentions = *p.Mentions
	}
	keep := func(id string) bool {
		return slices.ContainsFunc(gs, func(g store.CalendarGuest) bool { return g.ID == id })
	}
	next := slices.DeleteFunc(slices.Clone(mentions), func(m string) bool {
		return !keep(m) && slices.ContainsFunc(cur.Guests, func(g store.CalendarGuest) bool { return g.ID == m })
	})
	for _, g := range gs {
		if !slices.Contains(next, g.ID) {
			next = append(next, g.ID)
		}
	}
	if len(next) > calendarMaxMentions {
		return badCalendar("an event names at most 50 mentions, its guests included")
	}
	if next == nil {
		next = []string{}
	}
	p.Guests, p.Mentions = &gs, &next
	return nil
}

// checkGuestsInWorkspace: every guest of the body is a member (human) or an
// agent of the roster (agent, as <agent_id> or <agent_id>@<box>) of tenant.
func (s *Server) checkGuestsInWorkspace(ctx context.Context, tenant string, q calendarRequest) (*issueErr, error) {
	if q.Guests == nil || len(*q.Guests) == 0 {
		return nil, nil
	}
	known := map[string]bool{}
	if md, ok := s.o.Store.(store.MemberDirectory); ok {
		ms, err := md.ListMembers(ctx, tenant)
		if err != nil {
			return nil, err
		}
		for _, m := range ms {
			known["human:"+m.HumanID] = true
		}
	}
	roster, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		return nil, err
	}
	for box, agents := range roster {
		for _, a := range agents {
			known["agent:"+a], known["agent:"+a+"@"+box] = true, true
		}
	}
	for _, g := range *q.Guests {
		if !known[strings.TrimSpace(g.Type)+":"+strings.TrimSpace(g.ID)] {
			return badCalendar("guest " + strings.TrimSpace(g.ID) + " is not a member or an agent of this workspace"), nil
		}
	}
	return nil, nil
}

// newEvent is a create: the defaults of spec 6.1.2 (kind other, audience
// public) under the request's fields; the caller is the owner.
func (q calendarRequest) newEvent(actor string) (store.CalendarEvent, *issueErr) {
	if q.Title == nil || q.StartsAt == nil || q.EndsAt == nil {
		return store.CalendarEvent{}, badCalendar("title, starts_at and ends_at are required")
	}
	start, ie := optCalTimePtr("starts_at", q.StartsAt, false)
	if ie != nil {
		return store.CalendarEvent{}, ie
	}
	p, ie := q.patch(store.CalendarEvent{StartsAt: *start})
	if ie == nil {
		ie = q.patchGuests(store.CalendarEvent{}, actor, &p)
	}
	if ie != nil {
		return store.CalendarEvent{}, ie
	}
	e := store.CalendarEvent{Kind: calendarDefaultKind, Audience: store.CalendarPublic, Mentions: []string{},
		CreatorType: "human", CreatorID: actor, StartsAt: *p.StartsAt, EndsAt: *p.EndsAt, TimeZone: store.CalendarUTC}
	if p.Props != nil {
		e.Props = *p.Props
	}
	if p.TimeZone != nil {
		e.TimeZone = *p.TimeZone
	}
	if p.RRule != nil {
		e.RRule = *p.RRule
	}
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
	if p.Guests != nil {
		e.Guests = *p.Guests
	}
	return e, nil
}

func decodeCalendarRequest(w http.ResponseWriter, r *http.Request) (calendarRequest, bool) {
	var q calendarRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, calendarMaxBody))
	dec.DisallowUnknownFields()
	dec.UseNumber() // a reminder's amount: 1.5 and "10" stay distinguishable from 10
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
	case errors.Is(err, store.ErrEditConflict):
		return &issueErr{http.StatusConflict, "edit_conflict", calendarConflictDetail}
	case errors.Is(err, store.ErrNotAGuest):
		return &issueErr{http.StatusForbidden, "not_a_guest", "only a guest of the event answers it, for themselves"}
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

// calendarFail answers a failed read: too many occurrences is the caller's
// range (400 bad_range), anything else a 500.
func (s *Server) calendarFail(w http.ResponseWriter, tenant, what string, err error) {
	if errors.Is(err, store.ErrCalendarTooMany) {
		writeIssueErr(w, badCalendarRange("the range holds more than 2000 occurrences; narrow the range"))
		return
	}
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

// calendarSourceKeyPrefixRe is a ?source_key= prefix: a key family and the
// start of a key (store calendar_sync.go's key characters).
var calendarSourceKeyPrefixRe = regexp.MustCompile(`^(goal|spec|release|db):[A-Za-z0-9._:-]{0,200}$`)

// handleCalendarSourced is GET /v1/calendar/events?source_key=<prefix>
// (specs/112 4.2 "Lookup"): the synced events whose key starts with it, so
// the WUI never guesses an event id. start and end are optional here; given,
// they bound the answer as on the range read. No issue deadline joins it.
func (s *Server) handleCalendarSourced(w http.ResponseWriter, r *http.Request, t store.Tenant, prefix string) {
	if !calendarSourceKeyPrefixRe.MatchString(prefix) {
		writeIssueErr(w, badCalendarRange("source_key must be goal:, spec:, release: or db: and the start of a key"))
		return
	}
	var rg *store.CalendarRange
	if q := r.URL.Query(); q.Has("start") || q.Has("end") {
		x, ie := calendarRange(r, "start", "end", calendarMaxRangeDays)
		if ie != nil {
			writeIssueErr(w, ie)
			return
		}
		rg = &x
	}
	viewer, demo := s.calendarViewer(r, t)
	out, now := []calendarEventJSON{}, s.o.Now()
	if src, ok := s.o.Store.(store.CalendarSourced); ok {
		evs, err := src.CalendarBySourceKey(r.Context(), t.ID, viewer, prefix)
		if err != nil {
			s.calendarFail(w, t.ID, "source_key", err)
			return
		}
		for _, e := range visibleTo(evs, demo) {
			if rg == nil || (e.StartsAt.Before(rg.End) && !e.EndsAt.Before(rg.Start)) {
				out = append(out, toCalendarJSON(e, now, viewer))
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"source_key": prefix, "events": out})
}

// GET /v1/calendar/events?start=&end=, or ?source_key= (handleCalendarSourced)
func (s *Server) handleCalendarEvents(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	if r.URL.Query().Has("source_key") {
		s.handleCalendarSourced(w, r, t, r.URL.Query().Get("source_key"))
		return
	}
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
	out, now := make([]calendarEventJSON, 0, len(evs)+len(dls)), s.o.Now()
	for _, e := range evs {
		out = append(out, toCalendarJSON(e, now, viewer))
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

// reminderEvents is every event that may remind the viewer inside rg: they
// own it or are named on it (D4), it starts in [rg.Start, rg.End + 4 weeks)
// (the reminder cap, spec 4.3), plus any 089 remind_at the store finds in rg.
func (s *Server) reminderEvents(ctx context.Context, tenant, viewer string, demo bool, rg store.CalendarRange) ([]store.CalendarEvent, error) {
	c := s.calendarStore()
	wide, err := c.ListCalendarEvents(ctx, tenant, viewer, store.CalendarRange{Start: rg.Start, End: rg.End.Add(calendarReminderMax)})
	if err != nil {
		return nil, err
	}
	legacy, err := c.CalendarReminders(ctx, tenant, viewer, rg)
	if err != nil {
		return nil, err
	}
	seen, out := map[string]bool{}, []store.CalendarEvent{}
	for _, e := range append(wide, legacy...) {
		if seen[e.ID] || (e.CreatorID != viewer && !slices.Contains(e.Mentions, viewer)) {
			continue
		}
		seen[e.ID] = true
		out = append(out, e)
	}
	return visibleTo(out, demo), nil
}

// GET /v1/calendar/reminders?from=&to=: one item per reminder that fires in
// the window, its remind_at the fire time (089 T006's pop-up reads it).
func (s *Server) handleCalendarReminders(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	rg, ie := calendarRange(r, "from", "to", calendarMaxReminderDays)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	viewer, demo := s.calendarViewer(r, t)
	out, now := []calendarEventJSON{}, s.o.Now()
	if s.calendarStore() != nil && viewer != "" {
		evs, err := s.reminderEvents(r.Context(), t.ID, viewer, demo, rg)
		if err != nil {
			s.calendarFail(w, t.ID, "reminders", err)
			return
		}
		for _, e := range evs {
			for _, f := range reminderFires(e) {
				if !f.Before(rg.Start) && f.Before(rg.End) {
					item := toCalendarJSON(e, now, viewer)
					item.RemindAt = rfc(f)
					out = append(out, item)
				}
			}
		}
	}
	sort.SliceStable(out, func(a, b int) bool {
		if out[a].RemindAt != out[b].RemindAt {
			return out[a].RemindAt < out[b].RemindAt
		}
		return out[a].ID < out[b].ID
	})
	writeJSON(w, http.StatusOK, map[string]any{"from": rfc(rg.Start), "to": rfc(rg.End), "reminders": out})
}

// GET /v1/calendar/trash: the events the viewer deleted in the last 30 days,
// newest deletion first (spec 4.8). A demo visitor deletes nothing.
func (s *Server) handleCalendarTrash(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	viewer, demo := s.calendarViewer(r, t)
	out, now := []calendarEventJSON{}, s.o.Now()
	if c := s.calendarStore(); c != nil && viewer != "" && !demo {
		evs, err := c.CalendarTrash(r.Context(), t.ID, viewer, now.Add(-calendarTrashDays*24*time.Hour))
		if err != nil {
			s.calendarFail(w, t.ID, "trash", err)
			return
		}
		for _, e := range evs {
			out = append(out, toCalendarJSON(e, now, viewer))
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": out})
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
	if !s.calendarGuestsOK(w, r, t.ID, q) {
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
	writeJSON(w, http.StatusCreated, map[string]any{"event": toCalendarJSON(out, s.o.Now(), actor)})
}

// calendarGuestsOK answers 400 for a guest outside the workspace (spec 4.5).
func (s *Server) calendarGuestsOK(w http.ResponseWriter, r *http.Request, tenant string, q calendarRequest) bool {
	ie, err := s.checkGuestsInWorkspace(r.Context(), tenant, q)
	if err != nil {
		s.writeCalendarErr(w, tenant, "guests", err)
		return false
	}
	if ie != nil {
		writeIssueErr(w, ie)
		return false
	}
	return true
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

const calendarConflictDetail = "the event changed since it was read; event is the current one"

// calendarScope reads ?scope= of a PATCH or DELETE (spec 4.4); "" leaves the
// store's default (this for an occurrence id, all for a series id).
func calendarScope(r *http.Request) (string, *issueErr) {
	switch v := r.URL.Query().Get("scope"); v {
	case "", store.CalendarScopeThis, store.CalendarScopeFollowing, store.CalendarScopeAll:
		return v, nil
	}
	return "", badCalendar("scope must be this, following or all")
}

// ifMatch reads If-Match: "<updated_at>" (spec 4.2); zero when absent.
func ifMatch(r *http.Request) (time.Time, *issueErr) {
	v := strings.TrimSpace(r.Header.Get("If-Match"))
	if v == "" {
		return time.Time{}, nil
	}
	t, err := time.Parse(time.RFC3339Nano, strings.Trim(strings.TrimPrefix(v, "W/"), `"`))
	if err != nil {
		return time.Time{}, badCalendar(`If-Match must be the event's updated_at in quotes, e.g. "2026-10-06T09:00:00.123456Z"`)
	}
	return t.UTC(), nil
}

// writeCalendarConflict is 409 edit_conflict with the current event.
func (s *Server) writeCalendarConflict(w http.ResponseWriter, cur store.CalendarEvent, viewer string) {
	writeJSON(w, http.StatusConflict, map[string]any{"error": "edit_conflict", "detail": calendarConflictDetail,
		"event": toCalendarJSON(cur, s.o.Now(), viewer)})
}

// patchCalendarOnce reads the event, builds the patch against it and writes
// it under the precondition: the caller's If-Match, else the version read.
func (s *Server) patchCalendarOnce(r *http.Request, c store.Calendar, tenant, actor string, q calendarRequest,
	want time.Time, scope string) (store.CalendarEvent, *issueErr, error) {
	id := r.PathValue("id")
	cur, err := c.GetCalendarEvent(r.Context(), tenant, actor, id)
	if err != nil {
		return cur, nil, err
	}
	if cur.SourceKey != "" {
		return cur, calendarSyncedReadOnly(), nil
	}
	if !want.IsZero() && !want.Equal(cur.UpdatedAt) {
		return cur, nil, store.ErrEditConflict
	}
	p, ie := q.patch(cur)
	if ie == nil {
		ie = q.patchGuests(cur, actor, &p)
	}
	if ie == nil && calendarPatchEmpty(p) {
		ie = badCalendar("nothing to change")
	}
	if ie == nil {
		ie = privateOwnerOnly(cur, p, actor)
	}
	if ie != nil {
		return cur, ie, nil
	}
	p.IfUpdatedAt, p.Scope = cur.UpdatedAt, scope
	out, err := c.UpdateCalendarEvent(r.Context(), tenant, actor, id, p, s.o.Now())
	return out, nil, err
}

// calendarSyncedReadOnly is spec 112 4.1: a synced event (source_key set) is
// changed in the repo only; the next sync would revert a calendar edit.
func calendarSyncedReadOnly() *issueErr {
	return &issueErr{http.StatusConflict, "synced_read_only", "this event is synced from the repo; change it there"}
}

// calendarWriteArgs reads If-Match and ?scope= of a PATCH or DELETE.
func calendarWriteArgs(w http.ResponseWriter, r *http.Request) (time.Time, string, bool) {
	want, ie := ifMatch(r)
	if ie == nil {
		var scope string
		if scope, ie = calendarScope(r); ie == nil {
			return want, scope, true
		}
	}
	writeIssueErr(w, ie)
	return time.Time{}, "", false
}

// PATCH /v1/calendar/events/{id}?scope=
func (s *Server) handlePatchCalendarEvent(w http.ResponseWriter, r *http.Request) {
	t, actor, c, ok := s.calendarWriter(w, r)
	if !ok {
		return
	}
	q, ok := decodeCalendarRequest(w, r)
	if !ok {
		return
	}
	want, scope, ok := calendarWriteArgs(w, r)
	if !ok || !s.calendarGuestsOK(w, r, t.ID, q) {
		return
	}
	var out store.CalendarEvent
	var ie *issueErr
	var err error
	for try := 0; try < calendarPatchTries; try++ {
		out, ie, err = s.patchCalendarOnce(r, c, t.ID, actor, q, want, scope)
		if !errors.Is(err, store.ErrEditConflict) || !want.IsZero() {
			break // without If-Match, a race with another write re-reads
		}
	}
	switch {
	case ie != nil:
		writeIssueErr(w, ie)
	case errors.Is(err, store.ErrEditConflict) && !want.IsZero():
		s.writeCalendarConflict(w, out, actor)
	case err != nil:
		s.writeCalendarErr(w, t.ID, "update", err)
	default:
		writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(out, s.o.Now(), actor)})
	}
}

// DELETE /v1/calendar/events/{id}?scope=: a soft delete (spec 4.8), 200 with
// the event, its deleted_at set; If-Match as on PATCH. On a series, this
// cancels one occurrence and following ends the series before it (4.4).
func (s *Server) handleDeleteCalendarEvent(w http.ResponseWriter, r *http.Request) {
	t, actor, c, ok := s.calendarWriter(w, r)
	if !ok {
		return
	}
	want, scope, ok := calendarWriteArgs(w, r)
	if !ok {
		return
	}
	if cur, err := c.GetCalendarEvent(r.Context(), t.ID, actor, r.PathValue("id")); err == nil && cur.SourceKey != "" {
		writeIssueErr(w, calendarSyncedReadOnly())
		return
	}
	out, err := c.TrashCalendarScope(r.Context(), t.ID, actor, r.PathValue("id"), scope, want, s.o.Now())
	switch {
	case errors.Is(err, store.ErrEditConflict):
		s.writeCalendarConflict(w, out, actor)
	case err != nil:
		s.writeCalendarErr(w, t.ID, "delete", err)
	default:
		writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(out, s.o.Now(), actor)})
	}
}

// POST /v1/calendar/events/{id}/restore: the caller's own deletion back,
// same id (spec 4.8, the WUI's Undo).
func (s *Server) handleRestoreCalendarEvent(w http.ResponseWriter, r *http.Request) {
	t, actor, c, ok := s.calendarWriter(w, r)
	if !ok {
		return
	}
	out, err := c.RestoreCalendarEvent(r.Context(), t.ID, actor, r.PathValue("id"))
	if err != nil {
		s.writeCalendarErr(w, t.ID, "restore", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(out, s.o.Now(), actor)})
}

// calendarRSVPRequest is the body of POST .../rsvp (spec 4.5).
type calendarRSVPRequest struct {
	Response string `json:"response"`
	Comment  string `json:"comment"`
	Scope    string `json:"scope"`
}

// POST /v1/calendar/events/{id}/rsvp: the caller answers for themselves;
// a caller who is not a guest is 403 not_a_guest. On an occurrence id,
// scope this (the default) answers that occurrence, all the series.
func (s *Server) handleRSVPCalendarEvent(w http.ResponseWriter, r *http.Request) {
	t, actor, c, ok := s.calendarWriter(w, r)
	if !ok {
		return
	}
	g, ok := c.(store.CalendarGuests)
	if !ok {
		writeIssueErr(w, calendarUnavailable())
		return
	}
	var q calendarRSVPRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, calendarMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", `body must be {"response": "yes|no|maybe", "comment": "", "scope": "this|all"}`)
		return
	}
	out, err := g.RespondCalendarEvent(r.Context(), t.ID, actor, r.PathValue("id"),
		store.CalendarRSVP{Response: strings.TrimSpace(q.Response), Comment: q.Comment, Scope: strings.TrimSpace(q.Scope)}, s.o.Now())
	if err != nil {
		s.writeCalendarErr(w, t.ID, "rsvp", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(out, s.o.Now(), actor)})
}

func (s *Server) calendarPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale, If-Match")
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
	mux.HandleFunc("POST /v1/calendar/events/{id}/restore", s.handleRestoreCalendarEvent)
	mux.HandleFunc("POST /v1/calendar/events/{id}/rsvp", s.handleRSVPCalendarEvent)
	mux.HandleFunc("GET /v1/calendar/trash", s.viewHandler(s.handleCalendarTrash))
	mux.HandleFunc("PUT /v1/calendar/sync", s.handleCalendarSync) // specs/112 HUB-1, calendar_sync.go
	mux.HandleFunc("OPTIONS /v1/calendar/events", s.calendarPreflight)
	mux.HandleFunc("OPTIONS /v1/calendar/events/{id}", s.calendarPreflight)
	mux.HandleFunc("OPTIONS /v1/calendar/marks", s.calendarPreflight)
	mux.HandleFunc("OPTIONS /v1/calendar/reminders", s.calendarPreflight)
	mux.HandleFunc("OPTIONS /v1/calendar/events/{id}/restore", s.calendarPreflight)
	mux.HandleFunc("OPTIONS /v1/calendar/events/{id}/rsvp", s.calendarPreflight)
	mux.HandleFunc("OPTIONS /v1/calendar/trash", s.calendarPreflight)
	s.routeCalendarSearch(mux) // specs/097 T009
}

// routeWorkItems registers the issues (specs/039) and the calendar that
// shows their deadlines (specs/089), one line in Handler.
func (s *Server) routeWorkItems(mux *http.ServeMux) {
	s.routeIssues(mux)
	s.routeCalendar(mux)
}
