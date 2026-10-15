package hub

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A box agent moves ONE message (and its thread) into another topic by its
// msg id (SPL-1988; owner HUM-10, t1 69fd5022: "Create a new discussion ...
// and move those messages there"). It is the box twin of the browser's POST
// /v1/messages/{msg_id}/move {to_task} (spec 045 §3): the same refusals and
// the same write, storeMessageMove - MoveMessage, the moved_by mark, the log
// line, the message_moved frame - and the same move notice to the agents that
// hold the message.
//
// Who may is spec 045's rule read for an agent, as box_move.go reads it for a
// topic:
//   - an agent's message (its author included): any agent that reaches it -
//     its box reads the message (the tail rule) or the agent is a member of
//     its channel (owner, t1 ffc3b83c: the bots' messages move freely);
//   - a person's message: only an agent acting for (typed_by) a HUM-* bound
//     as an operator of this box (specs/036 FR-010) who is the tenant owner
//     or an admin.
//
// The target topic must be one the mover reaches the same way (else
// not_found), open with a card in a channel (not_in_channel, issue_topic,
// lobby), and its channel one the mover may post in (unknown_channel). A
// topic with no card answers not_found here, where the browser says
// not_a_card. moved_by is the acting agent; the human it acts for is logged
// as acting_for.

// boxMessageMove resolves and gates the message and the target topic, then
// moves it.
func (s *Server) boxMessageMove(ctx context.Context, x *session, f wire.Frame) (map[string]any, *issueErr) {
	id, task := f.MoveMsg, f.MoveToTask
	if !lowerUUID(id) || !lowerUUID(task) || f.MoveTo != "" {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame",
			"a message move frame needs move_msg and move_to_task, the lowercase UUIDs of the message and the target topic, and no move_to"}
	}
	hum, ie := s.boxMoverGate(ctx, x, f)
	if ie != nil {
		return nil, ie
	}
	now := s.o.Now()
	m, err := s.o.Store.GetEditable(ctx, x.tenant, id, now)
	var st store.CardState
	if err == nil {
		st, err = s.o.Store.CardState(ctx, x.tenant, id, now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such message"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("box message move lookup")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "message unavailable"}
	}
	if !s.boxReachesMsg(ctx, x, m, f.As, hum) {
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such message"}
	}
	if token := s.boxMessageRefusal(m, st, task); token != "" {
		return nil, &issueErr{http.StatusConflict, token, moveRefusals[token]}
	}
	if !agentid.IsAgent(m.FromID) && (hum == "" || !s.mayChangeTopic(ctx, x.tenant, hum, "", "")) {
		return nil, &issueErr{http.StatusForbidden, "not_allowed",
			"a person's message moves only for an agent acting for a workspace owner or admin"}
	}
	card, ie := s.boxMoveTarget(ctx, x, task, f.As, hum)
	if ie != nil {
		return nil, ie
	}
	out, ie := s.storeMessageMove(ctx, x.tenant, m, task, card, f.As, hum)
	if ie != nil {
		return nil, ie
	}
	s.moveNotice(ctx, x.tenant, m, task, card.Channel, f.As)
	return out, nil
}

// boxMessageRefusal is the browser's row refusals for a message moving to
// task, in its order ("" = none): the lobby, a DM, an issue's discussion, a
// topic's opening card, the same topic, into the lobby.
func (s *Server) boxMessageRefusal(m store.EditableMessage, st store.CardState, task string) string {
	lobby := s.o.LobbyTaskID != "" && m.TaskID == s.o.LobbyTaskID
	switch {
	case lobby:
		return "lobby"
	case m.Channel == "":
		return "not_in_channel"
	case st.IssueTopic:
		return "issue_topic"
	case st.IsParent == 1 && st.FirstOfTask:
		return "is_card"
	case task == m.TaskID:
		return "same_place"
	case s.o.LobbyTaskID != "" && task == s.o.LobbyTaskID:
		return "lobby"
	}
	return ""
}

// boxMoveTarget is moveTarget for an agent: the target topic opens with a
// card the mover reaches, in a channel that is not the lobby nor an issue's
// discussion, and the mover may post in that channel.
func (s *Server) boxMoveTarget(ctx context.Context, x *session, task, as, hum string) (store.TaskCard, *issueErr) {
	now := s.o.Now()
	card, err := s.o.Store.TaskCard(ctx, x.tenant, task, now)
	var cm store.EditableMessage
	if err == nil {
		cm, err = s.o.Store.GetEditable(ctx, x.tenant, card.MsgID, now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return card, &issueErr{http.StatusNotFound, "not_found", "no such topic"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("box message move target")
		return card, &issueErr{http.StatusInternalServerError, "internal", "topic unavailable"}
	case !s.boxReachesMsg(ctx, x, cm, as, hum):
		return card, &issueErr{http.StatusNotFound, "not_found", "no such topic"}
	}
	token := ""
	switch {
	case card.Channel == "":
		token = "not_in_channel"
	case card.IssueTopic:
		token = "issue_topic"
	case card.Channel == store.ChannelLobby:
		token = "lobby"
	}
	if token != "" {
		return card, &issueErr{http.StatusConflict, token, moveRefusals[token]}
	}
	return card, s.targetChannel(ctx, x.tenant, card.Channel, func() (bool, error) {
		in, err := s.agentInChannel(ctx, x.tenant, card.Channel, x.box, as)
		if err != nil || in || hum == "" {
			return in, err
		}
		return s.canReadChannel(ctx, x.tenant, card.Channel, hum)
	})
}

// boxReachesMsg is the read door on one row for an agent: boxMoverReads (the
// box's tail rule, or the acted-for human's channel door), or the agent is a
// member of the row's channel.
func (s *Server) boxReachesMsg(ctx context.Context, x *session, m store.EditableMessage, as, hum string) bool {
	if s.boxMoverReads(ctx, x, m, hum) {
		return true
	}
	if m.Channel == "" {
		return false
	}
	in, err := s.agentInChannel(ctx, x.tenant, m.Channel, x.box, as)
	return err == nil && in
}

// lowerUUID reports whether id is a lowercase UUID.
func lowerUUID(id string) bool {
	return uuidRe.MatchString(id) && id == strings.ToLower(id)
}
