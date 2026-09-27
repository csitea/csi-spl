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

// Move a topic to another channel and a message to another topic (SPL-1024,
// specs/045 contracts/move-v1.md).
//
// The owner, 2026-09-27: "a starter of a topic should be able to just drag it
// to a different channel, provided he has access to this channel", and
// "thread level msgs / cards should be draggable to a different topic". Who
// may is 041's rule (the author, the tenant owner, an admin); the target must
// be a channel the mover may post in. Every route is a member-session browser
// route: an agent has none.

const (
	topicMovedFrame   = "topic_moved"
	messageMovedFrame = "message_moved"
)

// moveRequest is the POST body: exactly one target.
type moveRequest struct {
	ToChannel string `json:"to_channel,omitempty"`
	ToTask    string `json:"to_task,omitempty"`
}

// moveRow is one resolved request on a row (contract §1 checks 1-6).
type moveRow struct {
	card    topicCard // t, from, m, st; may = the §3.4 author / owner / admin rule
	hum     string
	lobby   bool // the row is on the lobby task
	isCard  bool // the row opens its task (a topic's card)
	refusal string
}

// resolveMove runs contract §1 checks 1-6 and works out check 7 for both
// kinds of move. ok=false means it answered.
func (s *Server) resolveMove(w http.ResponseWriter, r *http.Request, mutate bool) (moveRow, bool) {
	var mr moveRow
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return mr, false
	}
	from, ok := s.editorID(r, t.ID)
	if !ok || hum == "" {
		writeForbidden(w, rbac.NotesSend, "moving a topic or a message needs a signed-in member session")
		return mr, false
	}
	perm := rbac.TopicsRead
	if mutate {
		if !billing.AllowsWrite(t.BillingStatus) {
			writeUnpaid(w)
			return mr, false
		}
		perm = rbac.NotesSend
	}
	if !s.permit(w, r, t.ID, hum, perm) {
		return mr, false
	}
	id := strings.ToLower(r.PathValue("msg_id"))
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_json", "msg_id must be a UUID")
		return mr, false
	}
	now := s.o.Now()
	m, err := s.o.Store.GetEditable(r.Context(), t.ID, id, now)
	var st store.CardState
	if err == nil {
		st, err = s.o.Store.CardState(r.Context(), t.ID, id, now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return mr, false
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("move lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return mr, false
	}
	if !s.messageDoor(w, r, t.ID, m) {
		return mr, false
	}
	mr.card = topicCard{t: t, from: from, m: m, st: st, ownTask: m.TaskID}
	mr.hum = hum
	mr.lobby = s.o.LobbyTaskID != "" && m.TaskID == s.o.LobbyTaskID
	mr.isCard = st.IsParent == 1 && st.FirstOfTask && !mr.lobby
	mr.card.may = s.mayChangeTopic(r.Context(), t.ID, hum, from, m.FromID)
	switch {
	case mr.lobby:
		mr.refusal = "lobby"
	case m.Channel == "":
		mr.refusal = "not_in_channel"
	case st.IssueTopic:
		mr.refusal = "issue_topic"
	}
	return mr, true
}

var moveRefusals = map[string]string{
	"lobby":          "the lobby is one shared topic: nothing moves into or out of it",
	"not_in_channel": "only a channel's topics and messages move; a direct message stays where it is",
	"issue_topic":    "an issue's discussion stays with its issue",
	"not_a_card":     "only a topic's opening card moves a topic to another channel",
	"is_card":        "a topic's opening card moves with its whole topic: move the topic to another channel instead",
	"same_place":     "it is already there",
	"cycle":          "a message cannot move into its own thread",
}

func writeRefusal(w http.ResponseWriter, token string) {
	writeErr(w, http.StatusConflict, token, moveRefusals[token])
}

// postableChannel is the target door (spec 045 §3.4): the channel exists, is
// not deleted or reserved, and the caller may read it - the rdb 0028 answer
// for a members-only channel they are not in is the same 404 as a missing
// one. ok=false means it answered.
func (s *Server) postableChannel(w http.ResponseWriter, ctx context.Context, tenant, channel, hum string) bool {
	missing := func() bool {
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+channel+" in this tenant")
		return false
	}
	if !store.ValidChannelID(channel) || channel == store.ChannelIssues || channel == store.ChannelTasks {
		return missing()
	}
	known, err := s.o.Store.ChannelKnown(ctx, tenant, channel)
	if err == nil && known {
		known, err = s.canReadChannel(ctx, tenant, channel, hum)
	}
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("channel", channel).Msg("move target channel")
		writeErr(w, http.StatusInternalServerError, "internal", "channel lookup failed")
		return false
	case !known:
		return missing()
	}
	return true
}

// POST /v1/messages/{msg_id}/move (contract §2, §3).
func (s *Server) handleMove(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	mr, ok := s.resolveMove(w, r, true)
	if !ok {
		return
	}
	var body moveRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || (body.ToChannel == "") == (body.ToTask == "") {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {to_channel} or {to_task}")
		return
	}
	if body.ToChannel != "" {
		s.moveTopic(w, r, mr, store.NormalizeChannel(strings.ToLower(strings.TrimPrefix(body.ToChannel, "#"))))
		return
	}
	s.moveMessage(w, r, mr, strings.ToLower(body.ToTask))
}

// moveTopic is contract §2: the card's whole topic to channel ch.
func (s *Server) moveTopic(w http.ResponseWriter, r *http.Request, mr moveRow, ch string) {
	c := mr.card
	switch {
	case mr.refusal != "":
		writeRefusal(w, mr.refusal)
		return
	case !mr.isCard:
		writeRefusal(w, "not_a_card")
		return
	case !c.may:
		writeErr(w, http.StatusForbidden, "not_allowed", "only the author, the tenant owner or an admin may move this topic")
		return
	case ch == store.ChannelLobby:
		writeRefusal(w, "lobby")
		return
	case ch == c.m.Channel:
		writeRefusal(w, "same_place")
		return
	}
	if !s.postableChannel(w, r.Context(), c.t.ID, ch, mr.hum) {
		return
	}
	now := s.o.Now().UTC().Truncate(time.Second)
	res, err := s.o.Store.MoveTopic(r.Context(), c.t.ID, c.m.MsgID, c.m.TaskID, ch, c.from, now)
	if !s.moveStored(w, err, c.m.MsgID) {
		return
	}
	s.o.Log.Info().Str("tenant", c.t.ID).Str("msg_id", c.m.MsgID).Str("by", c.from).Str("from_channel", c.m.Channel).
		Str("channel", ch).Int("rows", len(res.MsgIDs)).Msg("topic moved")
	out := map[string]any{"kind": "topic", "msg_id": c.m.MsgID, "task_id": c.m.TaskID, "channel": ch,
		"from_channel": c.m.Channel, "moved": res.Moved, "moved_by": c.from, "moved_at": rfc(now),
		"msg_ids": res.MsgIDs, "undo": map[string]string{"to_channel": c.m.Channel}}
	to := c.m
	to.Channel = ch
	s.fanoutMove(r.Context(), c.t.ID, c.m, to, moveFrame(topicMovedFrame, out))
	writeJSON(w, http.StatusOK, out)
}

// moveMessage is contract §3: a reply (and its thread) into topic task.
func (s *Server) moveMessage(w http.ResponseWriter, r *http.Request, mr moveRow, task string) {
	c := mr.card
	switch {
	case !uuidRe.MatchString(task):
		writeErr(w, http.StatusBadRequest, "bad_json", "to_task must be a UUID")
		return
	case mr.refusal != "":
		writeRefusal(w, mr.refusal)
		return
	case mr.isCard:
		writeRefusal(w, "is_card")
		return
	case !c.may:
		writeErr(w, http.StatusForbidden, "not_allowed", "only the author, the tenant owner or an admin may move this message")
		return
	case task == c.m.TaskID:
		writeRefusal(w, "same_place")
		return
	case s.o.LobbyTaskID != "" && task == s.o.LobbyTaskID:
		writeRefusal(w, "lobby")
		return
	}
	now := s.o.Now()
	switch ok, found, err := s.canReadTopic(r.Context(), c.t.ID, task, mr.hum); {
	case err != nil:
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("move target topic")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return
	case !found || !ok:
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return
	}
	card, err := s.o.Store.TaskCard(r.Context(), c.t.ID, task, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeRefusal(w, "not_a_card")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("move target card")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return
	case card.Channel == "":
		writeRefusal(w, "not_in_channel")
		return
	case card.IssueTopic:
		writeRefusal(w, "issue_topic")
		return
	case card.Channel == store.ChannelLobby:
		writeRefusal(w, "lobby")
		return
	}
	if !s.postableChannel(w, r.Context(), c.t.ID, card.Channel, mr.hum) {
		return
	}
	at := now.UTC().Truncate(time.Second)
	res, err := s.o.Store.MoveMessage(r.Context(), c.t.ID, c.m.MsgID, task, card.Channel, c.from, at,
		card.ReceivedAt.Add(time.Millisecond))
	if errors.Is(err, store.ErrMoveCycle) {
		writeRefusal(w, "cycle")
		return
	}
	if !s.moveStored(w, err, c.m.MsgID) {
		return
	}
	s.o.Log.Info().Str("tenant", c.t.ID).Str("msg_id", c.m.MsgID).Str("by", c.from).Str("from_task", c.m.TaskID).
		Str("task_id", task).Int("rows", len(res.MsgIDs)).Msg("message moved")
	out := map[string]any{"kind": "message", "msg_id": c.m.MsgID, "task_id": task, "from_task": c.m.TaskID,
		"channel": card.Channel, "from_channel": c.m.Channel, "moved": res.Moved, "moved_by": c.from,
		"moved_at": rfc(at), "received_at": rfc(res.ReceivedAt), "msg_ids": res.MsgIDs,
		"undo": map[string]string{"to_task": c.m.TaskID}}
	to := c.m
	to.Channel, to.TaskID = card.Channel, task
	s.fanoutMove(r.Context(), c.t.ID, c.m, to, moveFrame(messageMovedFrame, out))
	writeJSON(w, http.StatusOK, out)
}

// moveStored answers a store error; ok=true when there was none.
func (s *Server) moveStored(w http.ResponseWriter, err error, msgID string) bool {
	switch {
	case err == nil:
		return true
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "too_deep", "this topic nests deeper than a move will walk")
	default:
		s.o.Log.Error().Err(err).Str("msg_id", msgID).Msg("move store")
		writeErr(w, http.StatusInternalServerError, "internal", "move not stored")
	}
	return false
}

// moveFrame is the answer as a frame: the type added, undo left out.
func moveFrame(typ string, out map[string]any) map[string]any {
	f := map[string]any{"type": typ}
	for k, v := range out {
		if k != "undo" && k != "kind" {
			f[k] = v
		}
	}
	return f
}

// GET /v1/view/messages/{msg_id}/move (contract §4).
func (s *Server) handleViewMove(w http.ResponseWriter, r *http.Request) {
	r = r.WithContext(store.WithMemo(r.Context()))
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	mr, ok := s.resolveMove(w, r, false)
	if !ok {
		return
	}
	m := mr.card.m
	out := map[string]any{"msg_id": m.MsgID, "task_id": m.TaskID, "channel": m.Channel, "is_card": mr.isCard,
		"can_move": mr.card.may && mr.refusal == ""}
	if m.Move.Moved() {
		out["moved_from_channel"] = m.Move.FromChannel
		if m.Move.FromTask != "" {
			out["moved_from_task"] = m.Move.FromTask
		}
	}
	if mr.refusal != "" {
		out["refusal"] = mr.refusal
	}
	writeJSON(w, http.StatusOK, out)
}

// fanoutMove sends frame to every browser socket that was shown the row at
// its old place or is shown it at its new one (041's fanoutTopic, twice).
func (s *Server) fanoutMove(ctx context.Context, tenant string, from, to store.EditableMessage, frame map[string]any) {
	pf := parties{from.FromID, from.FromBox, from.ToID, from.ToBox}
	oldMembers := s.channelMemberSet(ctx, tenant, from.Channel)
	newMembers := s.channelMemberSet(ctx, tenant, to.Channel)
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant != tenant {
			continue
		}
		if c.wants(from.TaskID, from.Channel, pf, oldMembers) || c.wants(from.MsgID, from.Channel, pf, oldMembers) ||
			c.wants(to.TaskID, to.Channel, pf, newMembers) || c.wants(to.MsgID, to.Channel, pf, newMembers) {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	for _, c := range targets {
		c.write(ctx, frame) //nolint:errcheck
	}
}

// movePreflight answers CORS preflight for POST /v1/messages/{msg_id}/move.
// No new request header (a new header is a new preflight; see 032).
func (s *Server) movePreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}
