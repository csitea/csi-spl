package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Discussion loops (spec 182 v0.3 section 4.1 and 7.1.2, row L2,
// SPL-6032): the routes of the "Discussion loops…" dialog. The store is
// row L1's store.TopicLoopStore, an optional interface: a store without it
// answers 501 not_implemented and fires nothing (7.1.1 point 4).
//
//   - GET    /v1/topics/{task_id}/loops: the list, for any member who can
//     read the topic (the read door: 404 otherwise), with may_edit;
//   - POST   /v1/topics/{task_id}/loops: add, 201;
//   - PUT    /v1/topics/{task_id}/loops/{loop_id}: edit, pause, resume;
//   - DELETE /v1/topics/{task_id}/loops/{loop_id}: idempotent 200.
//
// Every write needs the workspace's "Who can archive topics" right (answer
// 5 A, the priority route's checks), writes no message in the topic
// (answer 7 C) and sends the topic's open views one topic_loops frame.
// The fire is topic_loop_fire.go.

const topicLoopsFrame = "topic_loops"

// topicLoopBitTTL is how long a tenant's cached "has loops" bit is trusted
// (7.1.1 point 2): another hub instance's first loop is seen within it.
const topicLoopBitTTL = 30 * time.Second

func (s *Server) routeTopicLoops(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/topics/{task_id}/loops", s.handleTopicLoopsGet)
	mux.HandleFunc("POST /v1/topics/{task_id}/loops", s.handleTopicLoopAdd)
	mux.HandleFunc("PUT /v1/topics/{task_id}/loops/{loop_id}", s.handleTopicLoopEdit)
	mux.HandleFunc("DELETE /v1/topics/{task_id}/loops/{loop_id}", s.handleTopicLoopDelete)
	mux.HandleFunc("OPTIONS /v1/topics/{task_id}/loops", s.topicLoopsPreflight)
	mux.HandleFunc("OPTIONS /v1/topics/{task_id}/loops/{loop_id}", s.topicLoopsPreflight)
}

func (s *Server) topicLoopsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// topicLoopBit is one tenant's cached answer of TenantHasTopicLoops.
type topicLoopBit struct {
	has bool
	at  time.Time
}

// topicLoopBits caches the bits per server and tenant, the way the members
// memo is kept off the Server struct.
var topicLoopBits sync.Map // [2]any{*Server, tenant} -> topicLoopBit

// topicLoopsMaybe: tenant may have a loop. A fresh cached false answers
// with no round trip, so a tenant with no loop pays nothing per post
// (4.2 step 6, TestRoundTripsPerRequest).
func (s *Server) topicLoopsMaybe(ctx context.Context, ls store.TopicLoopStore, tenant string) bool {
	k := [2]any{s, tenant}
	if v, ok := topicLoopBits.Load(k); ok {
		if b := v.(topicLoopBit); s.o.Now().Sub(b.at) < topicLoopBitTTL {
			return b.has
		}
	}
	has, err := ls.TenantHasTopicLoops(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("topic loop: has-loops read")
		return true // the probe of the topic decides
	}
	topicLoopBits.Store(k, topicLoopBit{has, s.o.Now()})
	return has
}

// topicLoopsWrote refreshes the bit after this hub's own write: an add sets
// it, a delete makes the next post read it again.
func (s *Server) topicLoopsWrote(tenant string, added bool) {
	k := [2]any{s, tenant}
	if added {
		topicLoopBits.Store(k, topicLoopBit{true, s.o.Now()})
		return
	}
	topicLoopBits.Delete(k)
}

// loopIdle is why an `on` loop would not fire for its author (7.1.2 idle):
// "author_left" (not a member now) or "author_no_right" (the archive policy
// no longer lets them edit loops); "" = it may. card is the topic's
// opening card when the caller has it (nil: read it if the policy needs it).
func (s *Server) loopIdle(ctx context.Context, l store.TopicLoop, card *store.EditableMessage) string {
	if _, err := s.access(ctx, l.SetBy, l.TenantID); err != nil {
		return "author_left"
	}
	t, err := s.o.Store.GetTenant(ctx, l.TenantID)
	if err != nil {
		return "author_no_right"
	}
	policy := s.archivePolicy(t)
	change := false
	if policy == store.ArchivePolicyStarter {
		if card == nil {
			c, found, err := s.openingCard(ctx, l.TenantID, l.TaskID)
			if err != nil || !found {
				return "author_no_right"
			}
			card = &c
		}
		change = s.mayChangeTopic(ctx, l.TenantID, l.SetBy, s.loopFrom(l), card.FromID)
	}
	if !s.mayArchiveByPolicy(ctx, l.TenantID, l.SetBy, policy, change) {
		return "author_no_right"
	}
	return ""
}

// dropTopicLoops deletes the loops of tasks when their topic is archived
// or deleted (4.5, v0.5). A failed delete is logged and the caller still
// answers: an archived topic's loops fire nothing (4.2 step 7). A lobby
// card's topic is no task of its own (ownTask ""), so the lobby's loops stay.
func (s *Server) dropTopicLoops(ctx context.Context, tenant string, tasks ...string) {
	ls, ok := s.o.Store.(store.TopicLoopStore)
	if !ok {
		return
	}
	for _, task := range tasks {
		if task == "" || task == s.o.LobbyTaskID {
			continue
		}
		if _, err := ls.DeleteTopicLoops(ctx, tenant, task); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Str("task", task).Msg("topic loops not deleted")
		}
	}
}

// loopJSON is one loop as every route answers it (7.1.2).
func (s *Server) loopJSON(ctx context.Context, l store.TopicLoop, card *store.EditableMessage) map[string]any {
	out := map[string]any{"loop_id": l.LoopID, "task_id": l.TaskID, "prompt": l.Prompt, "triggers": l.Triggers,
		"state": l.State, "set_by": s.loopFrom(l), "set_at": rfc(l.SetAt), "fires_in_hour": l.FiresInHour, "idle": ""}
	if l.Triggers == nil {
		out["triggers"] = []string{}
	}
	if l.IntervalMin > 0 {
		out["interval_min"] = l.IntervalMin
	}
	if !l.NextDueAt.IsZero() {
		out["next_due_at"] = rfc(l.NextDueAt)
	}
	loopJSONv04(out, l)
	if until := l.HourStart.Add(time.Hour); l.FiresInHour >= s.topicLoopCap() && until.After(s.o.Now()) {
		out["held_until"] = rfc(until)
	}
	if l.State == store.TopicLoopOn {
		out["idle"] = s.loopIdle(ctx, l, card)
	}
	return out
}

// loopJSONv04 adds the v0.4 fields (7.1.2), each present exactly with its
// box; the idle due time is not sent.
func loopJSONv04(out map[string]any, l store.TopicLoop) {
	if l.Keyword != "" {
		out["keyword"] = l.Keyword
	}
	if l.IdleMin > 0 {
		out["idle_min"] = l.IdleMin
	}
	if l.DailyAt != "" {
		tz := l.DailyTZ
		if tz == "" {
			tz = "UTC"
		}
		out["daily_at"], out["daily_tz"] = l.DailyAt, tz
		if !l.DailyDueAt.IsZero() {
			out["daily_due_at"] = rfc(l.DailyDueAt)
		}
	}
}

// loopsJSON is the list of loops.
func (s *Server) loopsJSON(ctx context.Context, loops []store.TopicLoop, card *store.EditableMessage) []map[string]any {
	out := make([]map[string]any, 0, len(loops))
	for _, l := range loops {
		out = append(out, s.loopJSON(ctx, l, card))
	}
	return out
}

// loopStoreOr501 is the store's loops; false has answered 501.
func (s *Server) loopStoreOr501(w http.ResponseWriter) (store.TopicLoopStore, bool) {
	ls := s.loopStore()
	if ls == nil {
		writeErr(w, http.StatusNotImplemented, "not_implemented", "this hub's store keeps no discussion loops")
		return nil, false
	}
	return ls, true
}

func (s *Server) handleTopicLoopsGet(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	from, _ := s.editorID(r, t.ID)
	q := topicPriorityReq{t: t, hum: hum, from: from}
	if hum == "" {
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return
	}
	if !s.priorityDoor(w, r, &q) {
		return
	}
	ls, ok := s.loopStoreOr501(w)
	if !ok {
		return
	}
	loops, err := ls.TopicLoops(r.Context(), t.ID, q.task)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task", q.task).Msg("topic loops read")
		writeErr(w, http.StatusInternalServerError, "internal", "loops unavailable")
		return
	}
	change := s.mayChangeTopic(r.Context(), t.ID, hum, from, q.card.FromID)
	may := from != "" && s.mayArchiveByPolicy(r.Context(), t.ID, hum, s.archivePolicy(t), change)
	writeJSON(w, http.StatusOK, map[string]any{"task_id": q.task, "may_edit": may, "loops": s.loopsJSON(r.Context(), loops, &q.card)})
}

// loopWriter resolves a write: the caller, the topic's read door, the
// archive policy, and (open) a topic that is not archived. false has answered.
func (s *Server) loopWriter(w http.ResponseWriter, r *http.Request, open bool) (topicPriorityReq, store.TopicLoopStore, bool) {
	var q topicPriorityReq
	if !s.priorityCaller(w, r, &q) || !s.priorityDoor(w, r, &q) {
		return q, nil, false
	}
	change := s.mayChangeTopic(r.Context(), q.t.ID, q.hum, q.from, q.card.FromID)
	if !s.mayArchiveByPolicy(r.Context(), q.t.ID, q.hum, s.archivePolicy(q.t), change) {
		writeErr(w, http.StatusForbidden, "not_allowed", "this workspace does not let you change this topic's loops")
		return q, nil, false
	}
	if open && !s.topicOpenDoor(w, r, q.t.ID, q.task, q.card.MsgID) {
		return q, nil, false
	}
	ls, ok := s.loopStoreOr501(w)
	return q, ls, ok
}

// loopBody is a POST or PUT body; absent fields are nil.
type loopBody struct {
	Prompt      *string  `json:"prompt"`
	Triggers    []string `json:"triggers"`
	IntervalMin *int     `json:"interval_min"`
	State       *string  `json:"state"`
	Keyword     *string  `json:"keyword"`
	IdleMin     *int     `json:"idle_min"`
	DailyAt     *string  `json:"daily_at"`
	DailyTZ     *string  `json:"daily_tz"`
}

// readLoopBody decodes the body; false has answered 400.
func readLoopBody(w http.ResponseWriter, r *http.Request) (loopBody, bool) {
	var b loopBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_loop", "body must be {\"prompt\", \"triggers\", \"interval_min\", \"keyword\", \"idle_min\", \"daily_at\", \"daily_tz\", \"state\"}")
		return b, false
	}
	if b.DailyTZ != nil { // 5.1: a CHECK cannot load a zone, the hub does
		if _, err := time.LoadLocation(*b.DailyTZ); err != nil || *b.DailyTZ == "" {
			writeErr(w, http.StatusBadRequest, "bad_loop", "daily_tz must be an IANA time zone, e.g. Europe/Helsinki")
			return b, false
		}
	}
	return b, true
}

func (s *Server) handleTopicLoopAdd(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	q, ls, ok := s.loopWriter(w, r, true)
	if !ok {
		return
	}
	b, ok := readLoopBody(w, r)
	if !ok {
		return
	}
	l := store.TopicLoop{TaskID: q.task, Triggers: b.Triggers, SetBy: q.hum, SetAt: s.o.Now().UTC()}
	if b.Prompt != nil {
		l.Prompt = *b.Prompt
	}
	l.IntervalMin, l.IdleMin = derefInt(b.IntervalMin), derefInt(b.IdleMin)
	l.Keyword, l.DailyAt, l.DailyTZ = derefStr(b.Keyword), derefStr(b.DailyAt), derefStr(b.DailyTZ)
	got, err := ls.AddTopicLoop(r.Context(), q.t.ID, l)
	if !s.loopWriteErr(w, q, err) {
		return
	}
	s.topicLoopsWrote(q.t.ID, true)
	s.o.Log.Info().Str("tenant", q.t.ID).Str("task", q.task).Str("loop_id", got.LoopID).Str("by", q.hum).Msg("topic loop added")
	s.loopsFrame(r.Context(), ls, q)
	writeJSON(w, http.StatusCreated, s.loopJSON(r.Context(), got, &q.card))
}

func (s *Server) handleTopicLoopEdit(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	q, ls, ok := s.loopWriter(w, r, true)
	if !ok {
		return
	}
	b, ok := readLoopBody(w, r)
	if !ok {
		return
	}
	e := store.TopicLoopEdit{Prompt: b.Prompt, Triggers: b.Triggers, Interval: b.IntervalMin, State: b.State,
		Keyword: b.Keyword, IdleMin: b.IdleMin, DailyAt: b.DailyAt, DailyTZ: b.DailyTZ, By: q.hum, At: s.o.Now().UTC()}
	got, err := ls.EditTopicLoop(r.Context(), q.t.ID, q.task, r.PathValue("loop_id"), e)
	if !s.loopWriteErr(w, q, err) {
		return
	}
	s.topicLoopsWrote(q.t.ID, true)
	s.o.Log.Info().Str("tenant", q.t.ID).Str("task", q.task).Str("loop_id", got.LoopID).Str("by", q.hum).Str("state", got.State).Msg("topic loop edited")
	s.loopsFrame(r.Context(), ls, q)
	writeJSON(w, http.StatusOK, s.loopJSON(r.Context(), got, &q.card))
}

func (s *Server) handleTopicLoopDelete(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	q, ls, ok := s.loopWriter(w, r, false)
	if !ok {
		return
	}
	id := r.PathValue("loop_id")
	gone, err := ls.DeleteTopicLoop(r.Context(), q.t.ID, q.task, id)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task", q.task).Str("loop_id", id).Msg("topic loop delete")
		writeErr(w, http.StatusInternalServerError, "internal", "loop not deleted")
		return
	}
	s.topicLoopsWrote(q.t.ID, false)
	s.o.Log.Info().Str("tenant", q.t.ID).Str("task", q.task).Str("loop_id", id).Str("by", q.hum).Bool("deleted", gone).Msg("topic loop deleted")
	s.loopsFrame(r.Context(), ls, q)
	writeJSON(w, http.StatusOK, map[string]any{"loop_id": id, "deleted": gone})
}

func derefInt(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// loopWriteErr answers a store error of an add or edit; true = none.
func (s *Server) loopWriteErr(w http.ResponseWriter, q topicPriorityReq, err error) bool {
	switch {
	case err == nil:
		return true
	case errors.Is(err, store.ErrBadTopicLoop):
		writeErr(w, http.StatusBadRequest, "bad_loop", err.Error())
	case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrBadTopicTask):
		writeErr(w, http.StatusNotFound, "not_found", "no such loop")
	default:
		s.o.Log.Error().Err(err).Str("task", q.task).Msg("topic loop store")
		writeErr(w, http.StatusInternalServerError, "internal", "loop not stored")
	}
	return false
}

// loopsFrame sends the topic's open views the list's new version.
func (s *Server) loopsFrame(ctx context.Context, ls store.TopicLoopStore, q topicPriorityReq) {
	loops, err := ls.TopicLoops(ctx, q.t.ID, q.task)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task", q.task).Msg("topic loops frame read")
		return
	}
	out := map[string]any{"task_id": q.task, "loops": s.loopsJSON(ctx, loops, &q.card)}
	s.fanoutTopic(ctx, q.t.ID, q.card, withType(topicLoopsFrame, q.card, out))
}
