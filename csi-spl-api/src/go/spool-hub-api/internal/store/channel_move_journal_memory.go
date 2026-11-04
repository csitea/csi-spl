// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"sort"
)

// channelMoveMemory is Memory's rows of a move: rdb 0249 channel_move_redirects,
// kind task, by (src tenant, task), kind issue by src tenant, and the messages
// with copied_from set (0250).
type channelMoveMemory struct {
	redirects map[[2]string]ChannelMoveRedirect
	issues    map[string][]IssueMove
	copied    map[[2]string]bool
}

// TaskMoveState on Memory: see Postgres.
func (s *Memory) TaskMoveState(ctx context.Context, tenant, taskID string) (TaskMoveState, error) {
	first, err := s.TaskFirstChannel(ctx, tenant, taskID)
	if err != nil {
		return TaskMoveState{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := TaskMoveState{FirstChannel: first}
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == taskID {
			out.HasRows = true
			break
		}
	}
	if r, ok := s.chMove.redirects[[2]string{tenant, taskID}]; ok {
		out.Redirect = &r
	}
	return out, nil
}

// PutChannelMoveRedirect holds one row on Memory, which has no P4 to write it.
func (s *Memory) PutChannelMoveRedirect(tenant, taskID string, r ChannelMoveRedirect) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.chMove.redirects == nil {
		s.chMove.redirects = map[[2]string]ChannelMoveRedirect{}
	}
	s.chMove.redirects[[2]string{tenant, taskID}] = r
}

// IssueMoves on Memory: see Postgres.
func (s *Memory) IssueMoves(_ context.Context, tenant string) ([]IssueMove, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := append([]IssueMove{}, s.chMove.issues[tenant]...)
	sort.Slice(out, func(i, j int) bool { return out[i].OldKey < out[j].OldKey })
	return out, nil
}

// PutIssueMove holds one kind issue row on Memory, which has no P4 to write it.
func (s *Memory) PutIssueMove(tenant string, m IssueMove) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.chMove.issues == nil {
		s.chMove.issues = map[string][]IssueMove{}
	}
	s.chMove.issues[tenant] = append(s.chMove.issues[tenant], m)
}

// MessageCopied on Memory: see Postgres.
func (s *Memory) MessageCopied(_ context.Context, tenant, msgID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.chMove.copied[[2]string{tenant, msgID}], nil
}

// MarkMessageCopied holds one copied row on Memory, which has no T11 to write it.
func (s *Memory) MarkMessageCopied(tenant, msgID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.chMove.copied == nil {
		s.chMove.copied = map[[2]string]bool{}
	}
	s.chMove.copied[[2]string{tenant, msgID}] = true
}
