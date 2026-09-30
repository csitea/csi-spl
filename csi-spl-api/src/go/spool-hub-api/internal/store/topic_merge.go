package store

import (
	"context"
	"errors"
	"time"
)

// Merging a whole topic into another topic (drag a topic card onto a topic,
// prd t1 714c7028). Owner, verbatim: "drag topic_level messages as into other
// topics, then all of the messages in the topic including the first msg should
// go into the target topic, and the order should be based on the timestamps".
//
// A merge re-homes every TOP-LEVEL row of the source topic (task_id = the
// source task) into the target task and demotes the source opener to a normal
// reply (is_parent 0); message-rooted sub-threads keep their own task_id but
// their parent_task_id is repointed off the source task onto the target, so a
// later delete of the (now empty) source task cannot take them. received_at is
// left untouched: the target's flat reply list interleaves the merged rows by
// their original timestamps, and the target's opener stays the earliest
// is_parent=1 row = the card (the reconciliation the owner asked for). The
// move columns record the home (moved_from_*, exactly as specs/045's move) so
// an undo can put the source topic back and re-seat its card - the opener
// invariant that keeps the restored topic archivable (prd t1 e802196b).

// ErrMergeCycle: the target task is the source topic itself or inside it.
var ErrMergeCycle = errors.New("store: merge a topic into itself or its own thread")

// MergeResult is what a merge changed.
type MergeResult struct {
	MsgIDs  []string  // every row merged: the source opener first
	TaskIDs []string  // the source tasks the walk covered
	At      time.Time // the source opener's received_at (unchanged by the merge)
}

// TopicMerge is the merge half of the store contract (714c7028).
type TopicMerge interface {
	// MergeTopic folds srcMsgID's whole topic (its own task srcTask) into
	// targetTask in ONE transaction, re-channelling every moved row to
	// toChannel and stamping the move columns. ErrNotFound when the source
	// card is gone, ErrMergeCycle when targetTask is inside the source topic.
	MergeTopic(ctx context.Context, tenantID, srcMsgID, srcTask, targetTask, toChannel, by string, at time.Time) (MergeResult, error)
	// UnmergeTopic reverses a merge: it takes msgIDs (the set MergeTopic
	// returned) back home from the move columns, clears the marks and re-seats
	// srcMsgID as its topic's card (is_parent 1). A best-effort undo: a row
	// already gone is skipped.
	UnmergeTopic(ctx context.Context, tenantID, srcMsgID string, msgIDs []string) error
}

// ---- Memory driver -----------------------------------------------------------

func (s *Memory) MergeTopic(_ context.Context, tenant, srcMsgID, srcTask, targetTask, toChannel, by string, at time.Time) (MergeResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.messages[[2]string{tenant, srcMsgID}]; !ok {
		return MergeResult{}, ErrNotFound
	}
	set, err := s.topicLocked(tenant, srcMsgID, srcTask)
	if err != nil {
		return MergeResult{}, err
	}
	for _, tk := range set.TaskIDs {
		if tk == targetTask {
			return MergeResult{}, ErrMergeCycle
		}
	}
	// recordHome saves task_id / parent_task_id into the move columns before
	// the row is re-homed - the first move keeps the home (markRow's rule).
	recordHome := func(m *Message) {
		if m.Move.FromTask == "" {
			m.Move.FromTask, m.Move.FromParent = m.TaskID, m.ParentTaskID
		}
	}
	for _, id := range set.MsgIDs {
		m := s.messages[[2]string{tenant, id}]
		switch {
		case m.TaskID == srcTask: // a top-level row of the source topic
			recordHome(m)
			m.TaskID, m.ParentTaskID, m.IsParent = targetTask, "", 0
		case m.ParentTaskID == srcTask: // a sub-thread / sub-task hung off the source task
			recordHome(m)
			m.ParentTaskID = targetTask
		}
		markRow(m, toChannel, by, at, false)
	}
	s.anyMoved = true
	opener := s.messages[[2]string{tenant, srcMsgID}]
	return MergeResult{MsgIDs: set.MsgIDs, TaskIDs: set.TaskIDs, At: opener.ReceivedAt}, nil
}

func (s *Memory) UnmergeTopic(_ context.Context, tenant, srcMsgID string, msgIDs []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, id := range msgIDs {
		m, ok := s.messages[[2]string{tenant, id}]
		if !ok {
			continue
		}
		if m.Move.FromTask != "" {
			m.TaskID, m.ParentTaskID = m.Move.FromTask, m.Move.FromParent
		}
		if !m.Move.At.IsZero() {
			m.Channel = m.Move.FromChannel
		}
		m.Move = MoveMark{}
	}
	if m, ok := s.messages[[2]string{tenant, srcMsgID}]; ok {
		m.IsParent = 1
	}
	return nil
}
