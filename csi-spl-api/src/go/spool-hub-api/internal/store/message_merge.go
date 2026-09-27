package store

import (
	"context"
	"errors"
)

// Merging one message into its neighbor (CLE-35064). The owner, prd t1 topic
// 04130ea2: "once the content is merged, the actual source of the merged
// content, the source card, should self-delete".
//
// The browser used to do this as two calls, an edit and then a delete, and
// on prd the second one never went out (Cloud Run request log, 2026-09-27:
// PATCH 845e637d at 20:48:59Z, no DELETE). So the store does both halves in
// ONE transaction: the kept message is edited exactly as ApplyEdit edits it
// (revision 1 captured, a new revision appended), and the source row is
// deleted, or nothing changes at all.

// ErrMergeHasReplies: the source has a thread of its own (rows whose task_id
// is its msg_id). Deleting it would orphan them, and moving them is the
// message move of specs/045, so the merge refuses instead.
var ErrMergeHasReplies = errors.New("merge source has replies")

// MergeMessages applies e to keepID and deletes dropID in one transaction,
// and returns keepID's new revision. ErrNotFound when either row is gone,
// ErrMergeHasReplies when dropID has replies.
func (s *Memory) MergeMessages(_ context.Context, tenant, keepID, dropID string, e Edit) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.messages[[2]string{tenant, keepID}]; !ok {
		return 0, ErrNotFound
	}
	if _, ok := s.messages[[2]string{tenant, dropID}]; !ok {
		return 0, ErrNotFound
	}
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == dropID && m.MsgID != dropID {
			return 0, ErrMergeHasReplies
		}
	}
	rev := s.applyEditLocked(tenant, keepID, e)
	s.deleteMessageLocked(tenant, dropID)
	return rev, nil
}
