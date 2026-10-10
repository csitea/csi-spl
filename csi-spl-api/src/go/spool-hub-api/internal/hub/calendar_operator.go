package hub

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator twin of POST /v1/calendar/events (owner HUM-10, msg b13c164c:
// "add those payments as an event on the due date in the calendar of this
// workspace"): an agent puts an event into one workspace's calendar with no
// member session (do_spl_calendar_event_add).
//
//	POST /v1/operator/calendar/events {tenant, agent_id, ordered_by?, <event>}
//	GET  /v1/operator/calendar/events/{id}?tenant=<slug>   (the read-back)
//
//   - Who: the env service account's Google ID token on the operator
//     allow-list (operatorAuth), as the other /v1/operator routes. A member
//     session is not enough.
//   - Creator: the agent the body names (creator_type 'agent'), never a human.
//   - One workspace: the body's tenant, written by the same store call as the
//     member create (RLS inside that tenant). A Host or X-Spool-Tenant naming
//     another workspace is 403 tenant_mismatch, and topic_id must be a topic
//     of that workspace (400 bad_event), so one workspace's request never
//     lands in or points into another.
//   - The event body is the member create's (calendarRequest, spec 6.1.2)
//     less guests: an agent invites nobody.

// operatorCalendarRequest is the create body: the target and the event.
type operatorCalendarRequest struct {
	Tenant    string `json:"tenant"`
	AgentID   string `json:"agent_id"`
	OrderedBy string `json:"ordered_by"`
	calendarRequest
}

// operatorCalendarTarget loads the workspace an authorised operator call
// names; it writes the error itself.
func (s *Server) operatorCalendarTarget(w http.ResponseWriter, r *http.Request, tenant string) (store.Tenant, store.Calendar, bool) {
	tenant = strings.ToLower(strings.TrimSpace(tenant))
	if !msg.ValidTenantID(tenant) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "tenant must be a valid slug")
		return store.Tenant{}, nil, false
	}
	if !s.tenantConsistent(w, r, tenant) {
		return store.Tenant{}, nil, false
	}
	t, ok := s.loadTenant(w, r, tenant)
	if !ok {
		return t, nil, false
	}
	c := s.calendarStore()
	if c == nil {
		writeIssueErr(w, calendarUnavailable())
		return t, nil, false
	}
	return t, c, true
}

func (s *Server) handleOperatorCalendarCreate(w http.ResponseWriter, r *http.Request) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	var q operatorCalendarRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, calendarMaxBody))
	dec.DisallowUnknownFields()
	dec.UseNumber()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {tenant, agent_id, ordered_by?, <calendar event>}")
		return
	}
	t, c, ok := s.operatorCalendarTarget(w, r, q.Tenant)
	if !ok {
		return
	}
	agent := strings.TrimSpace(q.AgentID)
	orderedBy := strings.TrimSpace(q.OrderedBy)
	switch {
	case !agentid.IsAgent(agent):
		writeErr(w, http.StatusBadRequest, "bad_agent_id", "agent_id must be an agent id, e.g. c-042")
		return
	case orderedBy != "" && !humanIDRe.MatchString(orderedBy):
		writeErr(w, http.StatusBadRequest, "bad_ordered_by", "ordered_by must be a HUM-* id")
		return
	case q.Guests != nil:
		writeIssueErr(w, badCalendar("an agent's event has no guests"))
		return
	case !billing.AllowsWrite(t.BillingStatus):
		writeUnpaid(w)
		return
	}
	if !s.operatorCalendarTopicOK(w, r, t.ID, q.TopicID) {
		return
	}
	e, ie := q.newEvent(agent)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	e.CreatorType = "agent"
	out, err := c.CreateCalendarEvent(r.Context(), t.ID, e, s.o.Now())
	if err != nil {
		s.writeCalendarErr(w, t.ID, "operator create", err)
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("event", out.ID).Str("agent", agent).Str("operator", op).
		Str("ordered_by", orderedBy).Msg("operator.calendar_event_created")
	writeJSON(w, http.StatusCreated, map[string]any{"event": toCalendarJSON(out, s.o.Now(), agent)})
}

// operatorCalendarTopicOK: a topic_id must name a topic of tenant.
func (s *Server) operatorCalendarTopicOK(w http.ResponseWriter, r *http.Request, tenant string, topic *string) bool {
	if topic == nil || strings.TrimSpace(*topic) == "" {
		return true
	}
	envs, err := s.o.Store.TaskEnvelopes(r.Context(), tenant, strings.TrimSpace(*topic))
	if err != nil {
		s.writeCalendarErr(w, tenant, "operator topic", err)
		return false
	}
	if len(envs) == 0 {
		writeIssueErr(w, badCalendar("topic_id is not a topic of this workspace"))
		return false
	}
	return true
}

// handleOperatorCalendarGet reads one event back as the operator sees it:
// workspace and internal events, never a private one.
func (s *Server) handleOperatorCalendarGet(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	t, c, ok := s.operatorCalendarTarget(w, r, r.URL.Query().Get("tenant"))
	if !ok {
		return
	}
	e, err := c.GetCalendarEvent(r.Context(), t.ID, "", r.PathValue("id"))
	if err != nil {
		s.writeCalendarErr(w, t.ID, "operator get", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"event": toCalendarJSON(e, s.o.Now(), "")})
}

func (s *Server) routeOperatorCalendar(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/calendar/events", s.handleOperatorCalendarCreate)
	mux.HandleFunc("GET /v1/operator/calendar/events/{id}", s.handleOperatorCalendarGet)
}
