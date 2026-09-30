package store

import (
	"context"
	"time"
)

// Promoting a thread message to a topic (drag a reply into the topics list,
// prd t1 8f588edd). Owner, verbatim: "there should be the feature to 'promote'
// a thread msg to a 'topic' msg by simply dragging it between 2 topic msgs or
// to the top of the topic msgs".
//
// A promote is the inverse of a merge (topic_merge.go): instead of folding a
// topic INTO another, it splits a single reply OUT of its topic into a NEW
// topic of its own. srcMsgID (a reply, never a card) becomes the opening card
// (is_parent 1) of a fresh task in the SAME channel, and its own sub-thread
// moves with it - the message-rooted rows keep their task_id, their
// parent_task_id is repointed off the source topic onto the new one. The
// channel does not change, so only the promoted card carries a move mark (the
// "moved from topic X" provenance, specs/045); the repointed sub-thread rows
// record their home in the move columns (for the undo) but stay unmarked, so
// they show no provenance. received_at is left untouched: the new topic sorts
// by its own time, wherever the drop landed (the drop position is visual only).
//
// The new card is is_parent 1 and first of its task, so the new topic is
// archivable at once (the e802196b-shaped opener invariant); an undo re-seats
// srcMsgID as a reply and takes every moved row home from the columns.

// TopicPromote is the promote half of the store contract (8f588edd): it needs
// no schema of its own, the move columns carry the home exactly as a message
// move does.
type TopicPromote interface {
	// PromoteMessage makes srcMsgID (a reply of srcTask, not a card) the
	// opening card of the NEW topic newTask in its own channel, taking its own
	// thread along, in ONE transaction. It records the home of every re-homed
	// row and marks the new card with at/by. ErrNotFound when the row is gone,
	// ErrMoveCycle when newTask is inside srcMsgID's own thread.
	PromoteMessage(ctx context.Context, tenantID, srcMsgID, srcTask, newTask, by string, at time.Time) (MoveResult, error)
	// DemoteTopic reverses a promote: it takes msgIDs (the set PromoteMessage
	// returned) home from the move columns, clears the marks and re-seats
	// srcMsgID as a reply (is_parent 0). A best-effort undo: a row already gone
	// is skipped.
	DemoteTopic(ctx context.Context, tenantID, srcMsgID string, msgIDs []string) error
}

// ---- Memory driver -----------------------------------------------------------

func (s *Memory) PromoteMessage(_ context.Context, tenant, srcMsgID, srcTask, newTask, by string, at time.Time) (MoveResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.messages[[2]string{tenant, srcMsgID}]; !ok {
		return MoveResult{}, ErrNotFound
	}
	set, err := s.topicLocked(tenant, srcMsgID, "")
	if err != nil {
		return MoveResult{}, err
	}
	for _, tk := range set.TaskIDs {
		if tk == newTask {
			return MoveResult{}, ErrMoveCycle
		}
	}
	// recordHome saves task_id / parent_task_id into the move columns before a
	// row is re-homed - the first move keeps the home (markRow's rule).
	recordHome := func(m *Message) {
		if m.Move.FromTask == "" {
			m.Move.FromTask, m.Move.FromParent = m.TaskID, m.ParentTaskID
		}
	}
	card := s.messages[[2]string{tenant, srcMsgID}]
	recordHome(card)
	card.TaskID, card.ParentTaskID, card.IsParent = newTask, "", 1
	// A same-channel mark: markRow records moved_from_channel = the (unchanged)
	// channel and stamps at/by; the home task is set, so the mark is not cleared.
	markRow(card, card.Channel, by, at, false)
	for _, id := range set.MsgIDs[1:] {
		m := s.messages[[2]string{tenant, id}]
		if m.ParentTaskID == srcTask { // a sub-thread hung off the source topic
			recordHome(m)
			m.ParentTaskID = newTask
		}
	}
	s.anyMoved = true
	return MoveResult{MsgIDs: set.MsgIDs, TaskIDs: set.TaskIDs, Moved: true, ReceivedAt: card.ReceivedAt}, nil
}

func (s *Memory) DemoteTopic(_ context.Context, tenant, srcMsgID string, msgIDs []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, id := range msgIDs {
		m, ok := s.messages[[2]string{tenant, id}]
		if !ok || m.Move.FromTask == "" {
			continue
		}
		m.TaskID, m.ParentTaskID = m.Move.FromTask, m.Move.FromParent
		if !m.Move.At.IsZero() && m.Move.FromChannel != "" {
			m.Channel = m.Move.FromChannel
		}
		m.Move = MoveMark{}
	}
	if m, ok := s.messages[[2]string{tenant, srcMsgID}]; ok {
		m.IsParent = 0
	}
	return nil
}
