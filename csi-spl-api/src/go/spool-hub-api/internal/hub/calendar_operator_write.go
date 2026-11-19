package hub

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator's two writes on an existing event (SPL-5453, spec 097
// section 4.10), beside the create of calendar_operator.go:
//
//	PATCH  /v1/operator/calendar/events/{id} {tenant, agent_id, ordered_by?, <fields>}
//	DELETE /v1/operator/calendar/events/{id}?tenant=&agent_id=&ordered_by=
//
//   - Who and where: as the create (operatorAuth, one workspace, a host of
//     another workspace is 403 tenant_mismatch, a workspace that may not
//     write is unpaid); agent_id and ordered_by are logged.
//   - What: a single event (not a synced one, 409 synced_read_only; not a
//     repeating one, 400 bad_event) the operator reaches: a workspace or
//     internal event, or (SPL-5720) a private event an agent created for
//     ordered_by: its creator_type is agent, ordered_by is a member of the
//     workspace and is in its mentions. A private event a human created, or
//     one ordered_by is not named in, is 404 (operatorReachesPrivate).
//   - PATCH (do_spl_calendar_event_pin, do_spl_calendar_event_update) sets
//     title, description, starts_at, ends_at, all_day, reminders and
//     props.pinned, through the member PATCH's checks (calendarRequest.patch).
//     Mentions, guests, owner, links, kind and recurrence stay the
//     members': another field is 400 bad_json, another props key 400
//     bad_event, an empty change 400 bad_event.
//   - Audience (SPL-5963, owner msg eac307d4): only "private", only on an
//     agent's entry whose owner is ordered_by (a member); a shared entry's
//     mentions become {ordered_by}, so it is private to that person
//     (operatorNarrowPrivate, do_spl_calendar_event_update AUDIENCE=private).
//     Any other value or target is 400 bad_event; nothing widens an audience.
//   - DELETE is the member delete (spec 4.8, a soft delete): the event goes
//     to the trash of ordered_by when that human is a member, so they can
//     Undo it in the WUI, else of the agent (do_spl_calendar_event_delete).
//   - Google Calendar follows the hub row: the sync's out half
//     (gcal_sync.go) patches a changed event and deletes a trashed one at
//     Google for every member who reads it (gcal_sync_agent_private_test.go).

// operatorCalendarPatchRequest is the PATCH body: the target and the fields
// an operator may change.
type operatorCalendarPatchRequest struct {
	Tenant      string         `json:"tenant"`
	AgentID     string         `json:"agent_id"`
	OrderedBy   string         `json:"ordered_by"`
	Title       *string        `json:"title"`
	Description *string        `json:"description"`
	StartsAt    *string        `json:"starts_at"`
	EndsAt      *string        `json:"ends_at"`
	AllDay      *bool          `json:"all_day"`
	Reminders   *[]any         `json:"reminders"`
	Props       map[string]any `json:"props"`
	Audience    *string        `json:"audience"`
}

// calendarRequest is the member PATCH body the operator body stands for.
func (q operatorCalendarPatchRequest) calendarRequest() calendarRequest {
	return calendarRequest{Title: q.Title, Description: q.Description, StartsAt: q.StartsAt, EndsAt: q.EndsAt,
		AllDay: q.AllDay, Reminders: q.Reminders, Props: q.Props}
}

// operatorNarrowPrivate (SPL-5963) is the one audience change an operator
// makes: an agent's entry made for o.person (its owner) becomes private to
// that person. A shared entry's mentions become {person}; an entry already
// private keeps its mentions (the person is among them, or it was 404).
func operatorNarrowPrivate(p *store.CalendarPatch, o opCalWrite, audience string) *issueErr {
	switch {
	case strings.TrimSpace(audience) != store.CalendarPrivate:
		return badCalendar("an operator PATCH sets audience to private only")
	case o.person == "" || o.cur.OwnerID != o.person:
		return badCalendar("audience private needs ordered_by, the member the entry was made for (its owner)")
	case o.cur.CreatorType != "agent":
		return badCalendar("an operator makes only an agent's entry private")
	}
	a := store.CalendarPrivate
	p.Audience = &a
	if o.cur.Audience != store.CalendarPrivate {
		ms := []string{o.person}
		p.Mentions = &ms
	}
	return nil
}

// operatorReachesPrivate (SPL-5720): a private event is the operator's only
// when an agent created it and person (ordered_by, a member) is in its
// mentions. Any other audience is reachable as before.
func operatorReachesPrivate(e store.CalendarEvent, person string) bool {
	return e.Audience != store.CalendarPrivate ||
		(person != "" && e.CreatorType == "agent" && slices.Contains(e.Mentions, person))
}

// operatorCalendarPerson answers orderedBy when that human is a member of
// tenant, else "": the viewer an operator call reads and writes as.
func (s *Server) operatorCalendarPerson(ctx context.Context, tenant, agent, orderedBy string) (string, error) {
	if orderedBy == "" {
		return "", nil
	}
	ie, err := s.calendarOwnerKnown(ctx, tenant, orderedBy, agent)
	if err != nil || ie != nil {
		return "", err
	}
	return orderedBy, nil
}

// operatorCalendarWho checks agent_id and ordered_by; it writes the error.
func operatorCalendarWho(w http.ResponseWriter, agent, orderedBy string) (string, string, bool) {
	agent, orderedBy = strings.TrimSpace(agent), strings.TrimSpace(orderedBy)
	switch {
	case !agentid.IsAgent(agent):
		writeErr(w, http.StatusBadRequest, "bad_agent_id", "agent_id must be an agent id, e.g. c-042")
	case orderedBy != "" && !humanIDRe.MatchString(orderedBy):
		writeErr(w, http.StatusBadRequest, "bad_ordered_by", "ordered_by must be a HUM-* id")
	default:
		return agent, orderedBy, true
	}
	return "", "", false
}

// operatorCalendarSingle loads the event {id} an operator may change in
// tenant t, read as person (operatorCalendarPerson); it writes the error.
func (s *Server) operatorCalendarSingle(w http.ResponseWriter, r *http.Request, t store.Tenant, c store.Calendar, person string) (store.CalendarEvent, bool) {
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return store.CalendarEvent{}, false
	}
	e, err := c.GetCalendarEvent(r.Context(), t.ID, person, r.PathValue("id"))
	if err == nil && !operatorReachesPrivate(e, person) {
		err = store.ErrNotFound // a human's own private event, or one not made for person
	}
	switch {
	case err != nil:
		s.writeCalendarErr(w, t.ID, "operator write", err)
	case e.SourceKey != "":
		writeIssueErr(w, calendarSyncedReadOnly())
	case e.RRule != "" || e.RecurringEventID != "":
		writeIssueErr(w, badCalendar("an operator changes a single event, not a repeating one"))
	default:
		return e, true
	}
	return e, false
}

// opCalWrite is what operatorCalendarWriteTarget loaded.
type opCalWrite struct {
	agent, orderedBy, person string
	t                        store.Tenant
	c                        store.Calendar
	cur                      store.CalendarEvent
}

// operatorCalendarWriteTarget runs the checks both writes share: who, the
// workspace, the person and the event; it writes the error.
func (s *Server) operatorCalendarWriteTarget(w http.ResponseWriter, r *http.Request, tenant, agentIn, orderedByIn string) (opCalWrite, bool) {
	var o opCalWrite
	var ok bool
	if o.agent, o.orderedBy, ok = operatorCalendarWho(w, agentIn, orderedByIn); !ok {
		return o, false
	}
	if o.t, o.c, ok = s.operatorCalendarTarget(w, r, tenant); !ok {
		return o, false
	}
	person, err := s.operatorCalendarPerson(r.Context(), o.t.ID, o.agent, o.orderedBy)
	if err != nil {
		s.writeCalendarErr(w, o.t.ID, "operator write", err)
		return o, false
	}
	o.person = person
	o.cur, ok = s.operatorCalendarSingle(w, r, o.t, o.c, person)
	return o, ok
}

func (s *Server) handleOperatorCalendarPin(w http.ResponseWriter, r *http.Request) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	var q operatorCalendarPatchRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, calendarMaxBody))
	dec.DisallowUnknownFields()
	dec.UseNumber() // a reminder's amount, as on the member PATCH
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json",
			"body must be {tenant, agent_id, ordered_by?, title?, description?, starts_at?, ends_at?, all_day?, reminders?, props?: {pinned}, audience?: private}")
		return
	}
	if _, set := q.Props[calPropPinned]; q.Props != nil && (!set || len(q.Props) != 1) {
		writeIssueErr(w, badCalendar("an operator PATCH sets props.pinned and no other props key"))
		return
	}
	o, ok := s.operatorCalendarWriteTarget(w, r, q.Tenant, q.AgentID, q.OrderedBy)
	if !ok {
		return
	}
	p, ie := q.calendarRequest().patch(o.cur)
	if ie == nil && q.Audience != nil {
		ie = operatorNarrowPrivate(&p, o, *q.Audience)
	}
	if ie == nil && calendarPatchEmpty(p) {
		ie = badCalendar("nothing to change")
	}
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	p.IfUpdatedAt = o.cur.UpdatedAt
	out, err := o.c.UpdateCalendarEvent(r.Context(), o.t.ID, o.person, o.cur.ID, p, s.o.Now())
	if err != nil {
		s.writeCalendarErr(w, o.t.ID, "operator patch", err)
		return
	}
	s.o.Log.Info().Str("tenant", o.t.ID).Str("event", out.ID).Str("agent", o.agent).Str("operator", op).
		Str("ordered_by", o.orderedBy).Str("audience", out.Audience).Bool("pinned", propsPinned(out)).Msg("operator.calendar_event_patched")
	writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(out, s.o.Now(), "")})
}

func (s *Server) handleOperatorCalendarDelete(w http.ResponseWriter, r *http.Request) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	qs := r.URL.Query()
	o, ok := s.operatorCalendarWriteTarget(w, r, qs.Get("tenant"), qs.Get("agent_id"), qs.Get("ordered_by"))
	if !ok {
		return
	}
	by := o.agent
	if o.person != "" {
		by = o.person
	}
	out, err := o.c.TrashCalendarScope(r.Context(), o.t.ID, by, o.cur.ID, "", o.cur.UpdatedAt, s.o.Now())
	if err != nil {
		s.writeCalendarErr(w, o.t.ID, "operator delete", err)
		return
	}
	s.o.Log.Info().Str("tenant", o.t.ID).Str("event", out.ID).Str("agent", o.agent).Str("operator", op).
		Str("ordered_by", o.orderedBy).Str("deleted_by", by).Msg("operator.calendar_event_trashed")
	writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(out, s.o.Now(), "")})
}
