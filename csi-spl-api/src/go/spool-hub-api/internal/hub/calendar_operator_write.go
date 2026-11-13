package hub

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator's two writes on an existing event (SPL-5453, spec 097
// section 4.10), beside the create of calendar_operator.go:
//
//	PATCH  /v1/operator/calendar/events/{id} {tenant, agent_id, ordered_by?, props: {pinned}}
//	DELETE /v1/operator/calendar/events/{id}?tenant=&agent_id=&ordered_by=
//
//   - Who and where: as the create (operatorAuth, one workspace, a host of
//     another workspace is 403 tenant_mismatch, a workspace that may not
//     write is unpaid); agent_id and ordered_by are logged.
//   - What: a single event the operator can read (workspace or internal,
//     never private), not a synced one (409 synced_read_only) and not a
//     repeating one (400 bad_event).
//   - PATCH sets only props.pinned (do_spl_calendar_event_pin); any other
//     field of the body or of props is 400.
//   - DELETE is the member delete (spec 4.8, a soft delete): the event goes
//     to the trash of ordered_by when that human is a member, so they can
//     Undo it in the WUI, else of the agent (do_spl_calendar_event_delete).

// operatorCalendarPinRequest is the PATCH body.
type operatorCalendarPinRequest struct {
	Tenant    string         `json:"tenant"`
	AgentID   string         `json:"agent_id"`
	OrderedBy string         `json:"ordered_by"`
	Props     map[string]any `json:"props"`
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
// tenant t; it writes the error itself.
func (s *Server) operatorCalendarSingle(w http.ResponseWriter, r *http.Request, t store.Tenant, c store.Calendar) (store.CalendarEvent, bool) {
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return store.CalendarEvent{}, false
	}
	e, err := c.GetCalendarEvent(r.Context(), t.ID, "", r.PathValue("id"))
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

func (s *Server) handleOperatorCalendarPin(w http.ResponseWriter, r *http.Request) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	var q operatorCalendarPinRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, calendarMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", `body must be {tenant, agent_id, ordered_by?, props: {"pinned": true|false}}`)
		return
	}
	if _, set := q.Props[calPropPinned]; !set || len(q.Props) != 1 {
		writeIssueErr(w, badCalendar("an operator PATCH sets props.pinned and nothing else"))
		return
	}
	agent, orderedBy, ok := operatorCalendarWho(w, q.AgentID, q.OrderedBy)
	if !ok {
		return
	}
	t, c, ok := s.operatorCalendarTarget(w, r, q.Tenant)
	if !ok {
		return
	}
	cur, ok := s.operatorCalendarSingle(w, r, t, c)
	if !ok {
		return
	}
	merged, ie := mergeCalendarProps(cur.Props, q.Props)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	out, err := c.UpdateCalendarEvent(r.Context(), t.ID, "", cur.ID,
		store.CalendarPatch{Props: &merged, IfUpdatedAt: cur.UpdatedAt}, s.o.Now())
	if err != nil {
		s.writeCalendarErr(w, t.ID, "operator pin", err)
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("event", out.ID).Str("agent", agent).Str("operator", op).
		Str("ordered_by", orderedBy).Bool("pinned", propsPinned(out)).Msg("operator.calendar_event_pinned")
	writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(out, s.o.Now(), "")})
}

func (s *Server) handleOperatorCalendarDelete(w http.ResponseWriter, r *http.Request) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	qs := r.URL.Query()
	agent, orderedBy, ok := operatorCalendarWho(w, qs.Get("agent_id"), qs.Get("ordered_by"))
	if !ok {
		return
	}
	t, c, ok := s.operatorCalendarTarget(w, r, qs.Get("tenant"))
	if !ok {
		return
	}
	cur, ok := s.operatorCalendarSingle(w, r, t, c)
	if !ok {
		return
	}
	by := agent
	if orderedBy != "" {
		ie, err := s.calendarOwnerKnown(r.Context(), t.ID, orderedBy, agent)
		if err != nil {
			s.writeCalendarErr(w, t.ID, "operator delete", err)
			return
		}
		if ie == nil {
			by = orderedBy
		}
	}
	out, err := c.TrashCalendarScope(r.Context(), t.ID, by, cur.ID, "", cur.UpdatedAt, s.o.Now())
	if err != nil {
		s.writeCalendarErr(w, t.ID, "operator delete", err)
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("event", out.ID).Str("agent", agent).Str("operator", op).
		Str("ordered_by", orderedBy).Str("deleted_by", by).Msg("operator.calendar_event_trashed")
	writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(out, s.o.Now(), "")})
}
