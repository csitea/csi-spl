package hub

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Merge a whole topic into another topic (drag a topic's opening card onto a
// topic, prd t1 714c7028). Owner, verbatim: "drag topic_level messages as into
// other topics, then all of the messages in the topic including the first msg
// should go into the target topic, and the order should be based on the
// timestamps".
//
//	POST /v1/messages/{msg_id}/merge-topic
//	  merge: {"to_task":"<uuid>"}   {msg_id} is the source topic's card
//	  undo:  {"undo":{"from_task":"<uuid>","msg_ids":[...]}}  the merge answer's undo
//
// Who may: 041's rule on the SOURCE card (author / owner / admin) AND a target
// the mover may post in - the same gate as specs/045's message move, run by
// resolveMove. The refusals reuse the move tokens (moveRefusals). Every route
// is a member-session browser route: an agent has none.

const (
	topicMergedFrame   = "topic_merged"
	topicUnmergedFrame = "topic_unmerged"
)

// mergeTopicRequest is the POST body: a merge (to_task) or an undo.
type mergeTopicRequest struct {
	ToTask string     `json:"to_task,omitempty"`
	Undo   *mergeUndo `json:"undo,omitempty"`
}

// mergeUndo is the merge answer's undo, played back to reverse it.
type mergeUndo struct {
	FromTask string   `json:"from_task"`
	MsgIDs   []string `json:"msg_ids"`
}

// routeMoves registers the move (specs/045) and topic-merge (714c7028) routes:
// dragging a topic to a channel, a message into a topic, or a whole topic into
// another topic, each with its CORS preflight.
func (s *Server) routeMoves(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/messages/{msg_id}/move", s.handleMove)
	mux.HandleFunc("OPTIONS /v1/messages/{msg_id}/move", s.movePreflight)
	mux.HandleFunc("POST /v1/messages/{msg_id}/merge-topic", s.handleMergeTopic)
	mux.HandleFunc("OPTIONS /v1/messages/{msg_id}/merge-topic", s.mergeTopicPreflight)
}

// POST /v1/messages/{msg_id}/merge-topic.
func (s *Server) handleMergeTopic(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	mr, ok := s.resolveMove(w, r, true)
	if !ok {
		return
	}
	var body mergeTopicRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || (body.ToTask == "") == (body.Undo == nil) {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {to_task} or {undo}")
		return
	}
	if body.Undo != nil {
		s.unmergeTopic(w, r, mr, body.Undo)
		return
	}
	s.mergeTopic(w, r, mr, strings.ToLower(body.ToTask))
}

// mergeTopic folds the source card's whole topic into task.
func (s *Server) mergeTopic(w http.ResponseWriter, r *http.Request, mr moveRow, task string) {
	c := mr.card
	switch {
	case !uuidRe.MatchString(task):
		writeErr(w, http.StatusBadRequest, "bad_json", "to_task must be a UUID")
		return
	case mr.refusal != "":
		writeRefusal(w, mr.refusal)
		return
	case !mr.isCard:
		writeRefusal(w, "not_a_card")
		return
	case !c.may:
		writeErr(w, http.StatusForbidden, "not_allowed", "only the author, the tenant owner or an admin may merge this topic")
		return
	case task == c.m.TaskID:
		writeRefusal(w, "same_place")
		return
	case s.o.LobbyTaskID != "" && task == s.o.LobbyTaskID:
		writeRefusal(w, "lobby")
		return
	}
	now := s.o.Now()
	card, ok := s.moveTarget(w, r, mr, task, now, "merge")
	if !ok {
		return
	}
	at := now.UTC().Truncate(time.Second)
	res, err := s.o.Store.MergeTopic(r.Context(), c.t.ID, c.m.MsgID, c.m.TaskID, task, card.Channel, c.from, at)
	if errors.Is(err, store.ErrMergeCycle) {
		writeRefusal(w, "cycle")
		return
	}
	if !s.moveStored(w, err, c.m.MsgID) {
		return
	}
	s.o.Log.Info().Str("tenant", c.t.ID).Str("msg_id", c.m.MsgID).Str("by", c.from).Str("from_task", c.m.TaskID).
		Str("task_id", task).Int("rows", len(res.MsgIDs)).Msg("topic merged")
	out := map[string]any{"kind": "merge", "msg_id": c.m.MsgID, "task_id": task, "from_task": c.m.TaskID,
		"channel": card.Channel, "from_channel": c.m.Channel, "merged": len(res.MsgIDs), "moved_by": c.from,
		"moved_at": rfc(at), "msg_ids": res.MsgIDs, "undo": mergeUndo{FromTask: c.m.TaskID, MsgIDs: res.MsgIDs}}
	to := c.m
	to.Channel, to.TaskID = card.Channel, task
	s.fanoutMove(r.Context(), c.t.ID, c.m, to, mergeFrame(topicMergedFrame, out))
	writeJSON(w, http.StatusOK, out)
}

// unmergeTopic reverses a merge from its answer's undo payload.
func (s *Server) unmergeTopic(w http.ResponseWriter, r *http.Request, mr moveRow, u *mergeUndo) {
	c := mr.card
	from, ids, ok := undoRows(w, c.may, u.FromTask, u.MsgIDs, "merge")
	if !ok {
		return
	}
	if err := s.o.Store.UnmergeTopic(r.Context(), c.t.ID, c.m.MsgID, ids); !s.moveStored(w, err, c.m.MsgID) {
		return
	}
	s.o.Log.Info().Str("tenant", c.t.ID).Str("msg_id", c.m.MsgID).Str("by", c.from).Str("to_task", from).
		Int("rows", len(ids)).Msg("topic merge undone")
	out := map[string]any{"kind": "unmerge", "msg_id": c.m.MsgID, "task_id": from, "from_task": c.m.TaskID,
		"channel": c.m.Move.FromChannel, "from_channel": c.m.Channel, "unmerged": len(ids), "moved_by": c.from,
		"msg_ids": ids}
	to := c.m
	to.TaskID, to.Channel = from, c.m.Move.FromChannel
	s.fanoutMove(r.Context(), c.t.ID, c.m, to, mergeFrame(topicUnmergedFrame, out))
	writeJSON(w, http.StatusOK, out)
}

// maxUndoRows caps an undo's msg_ids: a topic deeper than the delete walk is a
// bug, and this bounds the ANY() array the store binds.
const maxUndoRows = 4096

// mergeFrame is the answer as a frame: the type added, undo and kind left out.
func mergeFrame(typ string, out map[string]any) map[string]any {
	f := map[string]any{"type": typ}
	for k, v := range out {
		if k != "undo" && k != "kind" {
			f[k] = v
		}
	}
	return f
}

// mergeTopicPreflight answers CORS preflight for POST .../merge-topic.
func (s *Server) mergeTopicPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
