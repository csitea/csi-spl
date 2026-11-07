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
// an edit, an added emoji, a move or a merge into the topic. A box send never
// comes here, so an agent that finishes after the archive still reports, and
// Unarchive lifts the refusal with the stamp.

const (
	topicArchivedToken  = "topic_archived"
	topicArchivedDetail = "this topic is archived: unarchive it to add to it"
)

// topicClosed answers whether any of ids names an archived topic, a card or
// its thread (store.TopicArchived, the stamp the WUI marks), or a message of
// one: a thread opened on a reply has that reply's msg_id for its task.
func (s *Server) topicClosed(ctx context.Context, tenant string, ids ...string) (bool, error) {
	for _, id := range ids {
		if id == "" {
			continue
		}
		if closed, err := s.topicStamped(ctx, tenant, id); closed || err != nil {
			return closed, err
		}
		m, err := s.o.Store.GetEditable(ctx, tenant, id, s.o.Now())
		if errors.Is(err, store.ErrNotFound) { // a task id, not a message
			continue
		}
		if err != nil {
			return false, err
		}
		if closed, err := s.topicStamped(ctx, tenant, m.TaskID, m.ParentTaskID); closed || err != nil {
			return closed, err
		}
	}
	return false, nil
}

// topicStamped answers whether any of tasks carries the archive stamp.
func (s *Server) topicStamped(ctx context.Context, tenant string, tasks ...string) (bool, error) {
	for _, task := range tasks {
		if task == "" {
			continue
		}
		at, _, err := s.o.Store.TopicArchived(ctx, tenant, task, s.o.LobbyTaskID)
		if err != nil {
			return false, err
		}
		if !at.IsZero() {
			return true, nil
		}
	}
	return false, nil
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

// topicOpenDoor is the same check on a member's HTTP route. false means it
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
