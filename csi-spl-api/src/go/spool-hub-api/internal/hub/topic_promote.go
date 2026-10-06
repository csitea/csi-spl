package hub

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Promote a thread message to a topic of its own (drag a reply into the topics
// list, prd t1 8f588edd). Owner, verbatim: "there should be the feature to
// 'promote' a thread msg to a 'topic' msg by simply dragging it between 2 topic
// msgs or to the top of the topic msgs".
//
//	POST /v1/messages/{msg_id}/promote-topic
//	  promote: {}                                          {msg_id} is a reply
//	  undo:    {"undo":{"from_task":"<uuid>","msg_ids":[...]}}  the answer's undo
//
// The message becomes the opening card of a NEW topic in its own channel; its
// sub-thread moves with it, and the source topic keeps the rest. Who may is
// 041's rule on the source row (author / owner / admin) run by resolveMove,
// or any member for an agent's reply - the same gate as specs/045's message
// move (mayReply); a card cannot be promoted (it is
// already a topic). The new task_id is minted here: it is hub metadata (a move
// re-homes task_id freely), so nothing signs it and a fresh UUID cannot collide
// with an existing topic. The refusals reuse the move tokens (moveRefusals).
// Every route is a member-session browser route: an agent has none.

const (
	topicPromotedFrame = "topic_promoted"
	topicDemotedFrame  = "topic_demoted"
)

// promoteRequest is the POST body: a promote (empty) or an undo.
type promoteRequest struct {
	Undo *promoteUndo `json:"undo,omitempty"`
}

// promoteUndo is the promote answer's undo, played back to reverse it.
// FromTask is the new topic (where the card sits now); the old topic is read
// back from the row's move columns.
type promoteUndo struct {
	FromTask string   `json:"from_task"`
	MsgIDs   []string `json:"msg_ids"`
}

// routePromote registers the promote (8f588edd) route and its CORS preflight.
func (s *Server) routePromote(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/messages/{msg_id}/promote-topic", s.handlePromoteTopic)
	mux.HandleFunc("OPTIONS /v1/messages/{msg_id}/promote-topic", s.promotePreflight)
}

// POST /v1/messages/{msg_id}/promote-topic.
func (s *Server) handlePromoteTopic(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	mr, ok := s.resolveMove(w, r, true)
	if !ok {
		return
	}
	var body promoteRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {} or {undo}")
		return
	}
	if body.Undo != nil {
		s.demoteTopic(w, r, mr, body.Undo)
		return
	}
	s.promoteMessage(w, r, mr)
}

// promoteMessage splits a reply out into a new topic of its own.
func (s *Server) promoteMessage(w http.ResponseWriter, r *http.Request, mr moveRow) {
	c := mr.card
	switch {
	case mr.refusal != "":
		writeRefusal(w, mr.refusal)
		return
	case mr.isCard:
		writeRefusal(w, "is_card")
		return
	case !mr.mayReply():
		writeErr(w, http.StatusForbidden, "not_allowed", "only the author, the tenant owner or an admin may promote a person's message")
		return
	}
	newTask := uuid.NewString()
	at := s.o.Now().UTC().Truncate(time.Second)
	res, err := s.o.Store.PromoteMessage(r.Context(), c.t.ID, c.m.MsgID, c.m.TaskID, newTask, c.from, at)
	if errors.Is(err, store.ErrMoveCycle) {
		writeRefusal(w, "cycle")
		return
	}
	if !s.moveStored(w, err, c.m.MsgID) {
		return
	}
	s.o.Log.Info().Str("tenant", c.t.ID).Str("msg_id", c.m.MsgID).Str("by", c.from).Str("from_task", c.m.TaskID).
		Str("task_id", newTask).Int("rows", len(res.MsgIDs)).Msg("message promoted")
	out := map[string]any{"kind": "promote", "msg_id": c.m.MsgID, "task_id": newTask, "from_task": c.m.TaskID,
		"channel": c.m.Channel, "from_channel": c.m.Channel, "moved_by": c.from, "moved_at": rfc(at),
		"received_at": rfc(res.ReceivedAt), "msg_ids": res.MsgIDs,
		"undo": promoteUndo{FromTask: newTask, MsgIDs: res.MsgIDs}}
	to := c.m
	to.TaskID = newTask
	s.fanoutMove(r.Context(), c.t.ID, c.m, to, promoteFrame(topicPromotedFrame, out))
	writeJSON(w, http.StatusOK, out)
}

// demoteTopic reverses a promote from its answer's undo payload.
func (s *Server) demoteTopic(w http.ResponseWriter, r *http.Request, mr moveRow, u *promoteUndo) {
	c := mr.card
	from, ids, ok := undoRows(w, mr.mayReply(), u.FromTask, u.MsgIDs, "promote")
	if !ok {
		return
	}
	home := c.m.Move.FromTask // the topic the message came from (recorded by the promote)
	if err := s.o.Store.DemoteTopic(r.Context(), c.t.ID, c.m.MsgID, ids); !s.moveStored(w, err, c.m.MsgID) {
		return
	}
	s.o.Log.Info().Str("tenant", c.t.ID).Str("msg_id", c.m.MsgID).Str("by", c.from).Str("to_task", home).
		Int("rows", len(ids)).Msg("message promote undone")
	out := map[string]any{"kind": "demote", "msg_id": c.m.MsgID, "task_id": home, "from_task": from,
		"channel": c.m.Channel, "from_channel": c.m.Channel, "msg_ids": ids}
	to := c.m
	to.TaskID = home
	s.fanoutMove(r.Context(), c.t.ID, c.m, to, promoteFrame(topicDemotedFrame, out))
	writeJSON(w, http.StatusOK, out)
}

// promoteFrame is the answer as a frame: the type added, undo and kind left out.
func promoteFrame(typ string, out map[string]any) map[string]any {
	f := map[string]any{"type": typ}
	for k, v := range out {
		if k != "undo" && k != "kind" {
			f[k] = v
		}
	}
	return f
}

// promotePreflight answers CORS preflight for POST .../promote-topic.
func (s *Server) promotePreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
