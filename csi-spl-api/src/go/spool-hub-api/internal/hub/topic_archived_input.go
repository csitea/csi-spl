package hub

import (
	"context"
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A person's input stops at the archive (SPL-4954, spec 041 §3.1; owner
// HUM-10, msg 51465f86: "the humans should not be able to insert any input
// anymore to the archived discussions"). The refusal sits on the human routes
// only: a browser send (post, reply, poll answer, attachment: all one frame),
// an edit, an added emoji, a move or a merge into the topic, the undo of a
// promote or a merge back into it, a visitor's embed post, and since SPL-4993
// a fold, a kind change, a priority, a delete and a merge of the topic itself
// (owner, msg f305bf70). A box send never comes here, so an agent that finishes after the
// archive still reports, and Unarchive lifts the refusal with the stamp.

const (
	topicArchivedToken  = "topic_archived"
	topicArchivedDetail = "this topic is archived: unarchive it to add to it"
)

// topicClosed answers whether any of ids names an archived topic, a card or
// its thread, or anything under one, at any depth: a thread opened on a reply
// has that reply's msg_id for its task, and a child task has the topic for its
// parent. One read for all of them; a top-level post in the lobby reads
// nothing, because the lobby itself never carries the stamp.
func (s *Server) topicClosed(ctx context.Context, tenant string, ids ...string) (bool, error) {
	asked := make([]string, 0, len(ids))
	for _, id := range ids {
		if id != "" && id != s.o.LobbyTaskID {
			asked = append(asked, id)
		}
	}
	if len(asked) == 0 {
		return false, nil
	}
	return s.o.Store.AnyTopicArchived(ctx, tenant, s.o.LobbyTaskID, asked)
}

// wuiArchivedRefusal refuses a browser send into an archived topic, before
// anything is stored or delivered. The resend of a msg_id already stored
// passes: it adds nothing, and its ack may be all the sender is missing.
func (s *Server) wuiArchivedRefusal(ctx context.Context, tenant string, m *msg.Message, parent string) *frameRefusal {
	closed, err := s.topicClosed(ctx, tenant, m.TaskID, parent)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", m.TaskID).Msg("wui send archive check")
		return &frameRefusal{"internal", http.StatusInternalServerError, "topic unavailable"}
	}
	if !closed {
		return nil
	}
	if _, _, err := s.o.Store.MessageTimes(ctx, tenant, m.MsgID); err == nil {
		return nil
	}
	return &frameRefusal{topicArchivedToken, http.StatusConflict, topicArchivedDetail}
}

// topicTreeOpenDoor is topicOpenDoor for a write that takes the card's whole
// topic with it: an archived child below the card closes it too. No such card
// passes, for the write to answer 404. false means it answered.
func (s *Server) topicTreeOpenDoor(w http.ResponseWriter, r *http.Request, tenant string, card store.EditableMessage, ownTask string) bool {
	set, err := s.o.Store.TopicOf(r.Context(), tenant, card.MsgID, ownTask)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.o.Log.Error().Err(err).Str("msg_id", card.MsgID).Msg("topic tree archive check")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return false
	}
	return s.topicOpenDoor(w, r, tenant, append([]string{card.MsgID, card.TaskID}, set.TaskIDs...)...)
}

// topicOpenDoor is the same check on a person's HTTP route. false means it
// answered: 409 topic_archived, or 500 when the stamp cannot be read.
func (s *Server) topicOpenDoor(w http.ResponseWriter, r *http.Request, tenant string, ids ...string) bool {
	closed, err := s.topicClosed(r.Context(), tenant, ids...)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Strs("ids", ids).Msg("topic archive check")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return false
	case closed:
		writeErr(w, http.StatusConflict, topicArchivedToken, topicArchivedDetail)
		return false
	}
	return true
}
