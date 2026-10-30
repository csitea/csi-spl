package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A priority 1..5 per discussion (spec 150 v1.0 section 3.3, row B3,
// SPL-4192; the table and the store are row B1, rdb 0214). 1 is the most
// urgent; a topic nobody set reads store.TopicPriorityDefault (3, spec 150 v1.1 D7).
//
// PUT /v1/topics/{task_id}/priority, body {"priority": 1..5} (panel D10):
//   - a member session only, billing and notes.send as for an archive; a
//     demo visitor never (403);
//   - the read door first: a caller who cannot read the topic gets 404, as
//     on GET /v1/view/topics/{task_id};
//   - then the workspace policy "Who can archive topics"
//     (mayArchiveByPolicy, panel D8): 403 not_allowed otherwise;
//   - 400 bad_json outside 1..5.
//
// The rows of GET /v1/view/topics carry the value as the store reads it in
// the list's own statement (TopicRow.Priority), GET /v1/view/topics/{task_id}
// as the fused door read takes it (topicPriorityStamp), so neither pays a
// round trip of its own (TestRoundTripsPerRequest). Every open view
// of the topic gets the live frame topic_priority through fanoutTopic, as
// an archive sends topic_archived.

const topicPriorityFrame = "topic_priority"

func (s *Server) routeTopicPriority(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/topics/{task_id}/priority", s.handleTopicPriority)
	mux.HandleFunc("OPTIONS /v1/topics/{task_id}/priority", s.topicPreflight)
}

// topicPriorityReq is one resolved PUT: who asks and the topic's opening
// card (the fanout's audience and the starter policy's author).
type topicPriorityReq struct {
	t    store.Tenant
	hum  string
	from string // the caller's v:1 id, as editorID resolves it
	task string
	card store.EditableMessage
}

func (s *Server) handleTopicPriority(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	var q topicPriorityReq
	ok := s.priorityCaller(w, r, &q) && s.priorityDoor(w, r, &q) && s.priorityAllowed(w, r, q)
	if !ok {
		return
	}
	prio, ok := priorityBody(w, r)
	if !ok {
		return
	}
	ps, ok := s.o.Store.(store.TopicPriorityStore)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "priority not stored")
		return
	}
	row, err := ps.SetTopicPriority(r.Context(), q.t.ID, q.task, prio, q.from, s.o.Now().UTC().Truncate(time.Second))
	switch {
	case errors.Is(err, store.ErrBadTopicPriority):
		writeErr(w, http.StatusBadRequest, "bad_json", "priority must be 1..5")
		return
	case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrBadTopicTask):
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("task", q.task).Msg("topic priority store")
		writeErr(w, http.StatusInternalServerError, "internal", "priority not stored")
		return
	}
	s.o.Log.Info().Str("tenant", q.t.ID).Str("task", q.task).Str("by", q.from).Int("priority", row.Priority).Msg("topic priority")
	out := map[string]any{"task_id": q.task, "priority": row.Priority, "set_by": row.SetBy, "set_at": rfc(row.SetAt)}
	s.fanoutTopic(r.Context(), q.t.ID, q.card, withType(topicPriorityFrame, q.card, out))
	writeJSON(w, http.StatusOK, out)
}

// priorityCaller is who may ask: the member session, billing, then the
// notes.send permit (cardCaller's rule for a mutation). false has answered.
func (s *Server) priorityCaller(w http.ResponseWriter, r *http.Request, q *topicPriorityReq) bool {
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return false
	}
	from, ok := s.editorID(r, t.ID)
	if !ok || hum == "" {
		writeForbidden(w, rbac.NotesSend, "setting a topic's priority needs a signed-in member session")
		return false
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return false
	}
	// A demo visitor does not reorder the demo workspace's work (specs/077
	// FR-003: every mutating route refuses a demo_user unless decided).
	if s.isDemoVisitor(r.Context(), t.ID, hum) {
		writeErr(w, http.StatusForbidden, "demo_read_only", "a demo visit reads topics but does not reorder them")
		return false
	}
	q.t, q.hum, q.from = t, hum, from
	return s.permit(w, r, t.ID, hum, rbac.NotesSend)
}

// priorityDoor is the read door of the topic (canReadTopic): a topic the
// caller cannot read does not exist, 404, never 403. It then loads the
// topic's opening card. false has answered.
func (s *Server) priorityDoor(w http.ResponseWriter, r *http.Request, q *topicPriorityReq) bool {
	q.task = strings.ToLower(r.PathValue("task_id"))
	if !uuidRe.MatchString(q.task) {
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return false
	}
	may, found, err := s.canReadTopic(r.Context(), q.t.ID, q.task, q.hum)
	if err == nil && found && may {
		q.card, found, err = s.openingCard(r.Context(), q.t.ID, q.task)
	}
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("task", q.task).Msg("topic priority door")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return false
	case !found || !may:
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return false
	}
	return true
}

// openingCard is the topic's oldest stored message as an editable row.
func (s *Server) openingCard(ctx context.Context, tenant, task string) (store.EditableMessage, bool, error) {
	now := s.o.Now()
	rows, err := s.o.Store.ViewTopic(ctx, tenant, store.TopicMsgQuery{TaskID: task, Limit: 1, Now: now})
	if err != nil || len(rows) == 0 {
		return store.EditableMessage{}, false, err
	}
	m, err := s.o.Store.GetEditable(ctx, tenant, rows[0].MsgID, now)
	if errors.Is(err, store.ErrNotFound) {
		return m, false, nil
	}
	return m, err == nil, err
}

// priorityAllowed applies "Who can archive topics" (panel D8): the starter
// policy's author is the opening card's. false has answered 403.
func (s *Server) priorityAllowed(w http.ResponseWriter, r *http.Request, q topicPriorityReq) bool {
	change := s.mayChangeTopic(r.Context(), q.t.ID, q.hum, q.from, q.card.FromID)
	if !s.mayArchiveByPolicy(r.Context(), q.t.ID, q.hum, s.archivePolicy(q.t), change) {
		writeErr(w, http.StatusForbidden, "not_allowed", "this workspace does not let you set this topic's priority")
		return false
	}
	return true
}

// priorityBody reads {"priority": 1..5}; false has answered 400.
func priorityBody(w http.ResponseWriter, r *http.Request) (int, bool) {
	var in struct {
		Priority *int `json:"priority"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10))
	if err := dec.Decode(&in); err != nil || in.Priority == nil ||
		*in.Priority < store.TopicPriorityMin || *in.Priority > store.TopicPriorityMax {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {\"priority\": 1..5}")
		return 0, false
	}
	return *in.Priority, true
}

// topicPriorityStamp sets one topic read's priority: door is the value the
// fused door read took in the page's batch (Postgres, no round trip of its
// own); 0 = not read there, so it is read here. false has answered 500.
func (s *Server) topicPriorityStamp(w http.ResponseWriter, r *http.Request, tenant string, door int, body *topicBody) bool {
	body.Priority = store.TopicPriorityDefault
	if door != 0 {
		body.Priority = door
		return true
	}
	ps, ok := s.o.Store.(store.TopicPriorityStore)
	if !ok {
		return true
	}
	got, err := ps.TopicPriorities(r.Context(), tenant, []string{body.TaskID})
	if err != nil {
		s.o.Log.Error().Err(err).Str("task", body.TaskID).Msg("topic priority")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return false
	}
	if p, ok := got[body.TaskID]; ok {
		body.Priority = p
	}
	return true
}
