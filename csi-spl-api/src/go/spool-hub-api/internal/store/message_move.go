package store

import (
	"context"
	"errors"
	"sort"
	"time"
)

// Moving a topic to another channel and a message to another topic
// (SPL-1024, specs/045, rdb 0069).
//
// The signed envelope keeps where a row was stored when it arrived - its
// HOME - because a box signed it with a key the hub does not hold. A move is
// therefore hub metadata: the columns the hub reads (channel, task_id,
// parent_task_id, is_parent) change, and MoveMark says where home is. A move
// back home clears the mark, so an unmarked row is always exactly where its
// envelope says, and the view needs no override for it.

// ErrMoveCycle: the target task is inside the moved row's own thread.
var ErrMoveCycle = errors.New("store: move into its own thread")

// MoveMark is a moved row's record. Zero At = the row is at home.
type MoveMark struct {
	At          time.Time
	By          string
	FromChannel string // the home channel ("" = none)
	FromTask    string // the home task; a message move only
	FromParent  string // the home parent_task_id; a message move only
	// The row's place NOW, filled by the view reads only (the envelope
	// still names the home): the browser lets these win.
	Channel      string
	TaskID       string
	ParentTaskID string
}

// Moved reports whether the row is away from home.
func (m MoveMark) Moved() bool { return !m.At.IsZero() }

// TaskCard is the opening card of a task: its first row, which must be a
// level-1 row.
type TaskCard struct {
	MsgID      string
	Channel    string // "" = a DM
	ReceivedAt time.Time
	IssueTopic bool
}

// MoveResult is what a move changed.
type MoveResult struct {
	MsgIDs  []string // every row moved: the card / the row first
	TaskIDs []string // the tasks the walk covered
	// Moved is false when the move took the (first) row home, which clears
	// its mark.
	Moved bool
	// ReceivedAt is the first row's received_at after the move (a message
	// move may push it under the target's card, spec 045 §3.2).
	ReceivedAt time.Time
}

// Moves is the move half of the store contract (specs/045).
type Moves interface {
	// TaskCard reads a task's opening card in retention. ErrNotFound when
	// the task has no row, or its first row is not level 1.
	TaskCard(ctx context.Context, tenantID, taskID string, now time.Time) (TaskCard, error)
	// MoveTopic sets channel = toChannel on every row of msgID's topic
	// (walkTopic, ownTask as TopicArchive takes it) in ONE transaction, and
	// marks them. ErrNotFound when the card is gone.
	MoveTopic(ctx context.Context, tenantID, msgID, ownTask, toChannel, by string, at time.Time) (MoveResult, error)
	// MoveMessage re-homes msgID under toTask (parent none, level 0, channel
	// toChannel, received_at at least notBefore) and takes its own thread
	// along, in ONE transaction. ErrNotFound when the row is gone,
	// ErrMoveCycle when toTask is inside its own thread.
	MoveMessage(ctx context.Context, tenantID, msgID, toTask, toChannel, by string, at, notBefore time.Time) (MoveResult, error)
	// MovedTaskChannel is the channel of a task that has moved rows, and
	// false when none of its rows is moved (spec 045 §3.7).
	MovedTaskChannel(ctx context.Context, tenantID, taskID string) (string, bool, error)
}

// markRow applies one move to m: the first move keeps the home, a move that
// lands back home clears the mark. fromTask records the home task on a
// message move ("" = a channel-only change).
func markRow(m *Message, toChannel, by string, at time.Time, homeTask bool) {
	if m.Move.At.IsZero() {
		m.Move.FromChannel = m.Channel
	}
	m.Channel = toChannel
	m.Move.At, m.Move.By = at, by
	if homeTask && m.Move.FromTask != "" && m.TaskID == m.Move.FromTask {
		m.ParentTaskID = m.Move.FromParent
		m.Move.FromTask, m.Move.FromParent = "", ""
	}
	if m.Move.FromTask == "" && m.Channel == m.Move.FromChannel {
		m.Move = MoveMark{}
	}
}

// ---- Memory driver -----------------------------------------------------------

func (s *Memory) TaskCard(_ context.Context, tenant, task string, now time.Time) (TaskCard, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var first *Message
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == task && m.ExpiresAt.After(now) &&
			(first == nil || newer(first.ReceivedAt, first.MsgID, m.ReceivedAt, m.MsgID)) {
			first = m
		}
	}
	if first == nil || parentBit(first.IsParent) != 1 {
		return TaskCard{}, ErrNotFound
	}
	return TaskCard{MsgID: first.MsgID, Channel: first.Channel, ReceivedAt: first.ReceivedAt,
		IssueTopic: s.iss.isTask(tenant, task)}, nil
}

func (s *Memory) MoveTopic(_ context.Context, tenant, msgID, ownTask, toChannel, by string, at time.Time) (MoveResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	set, err := s.topicLocked(tenant, msgID, ownTask)
	if err != nil {
		return MoveResult{}, err
	}
	for _, id := range set.MsgIDs {
		markRow(s.messages[[2]string{tenant, id}], toChannel, by, at, false)
	}
	s.anyMoved = true
	card := s.messages[[2]string{tenant, msgID}]
	return MoveResult{MsgIDs: set.MsgIDs, TaskIDs: set.TaskIDs, Moved: card.Move.Moved(), ReceivedAt: card.ReceivedAt}, nil
}

func (s *Memory) MoveMessage(_ context.Context, tenant, msgID, toTask, toChannel, by string, at, notBefore time.Time) (MoveResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	set, err := s.topicLocked(tenant, msgID, "")
	if err != nil {
		return MoveResult{}, err
	}
	for _, t := range set.TaskIDs {
		if t == toTask {
			return MoveResult{}, ErrMoveCycle
		}
	}
	row := s.messages[[2]string{tenant, msgID}]
	from := row.TaskID
	if row.Move.At.IsZero() || row.Move.FromTask == "" {
		row.Move.FromTask, row.Move.FromParent = row.TaskID, row.ParentTaskID
	}
	row.TaskID, row.ParentTaskID, row.IsParent = toTask, "", 0
	if row.ReceivedAt.Before(notBefore) {
		row.ReceivedAt = notBefore
	}
	markRow(row, toChannel, by, at, true)
	for _, id := range set.MsgIDs[1:] {
		m := s.messages[[2]string{tenant, id}]
		if m.ParentTaskID == from {
			m.ParentTaskID = toTask
		}
		markRow(m, toChannel, by, at, false)
	}
	s.anyMoved = true
	return MoveResult{MsgIDs: set.MsgIDs, TaskIDs: set.TaskIDs, Moved: row.Move.Moved(), ReceivedAt: row.ReceivedAt}, nil
}

func (s *Memory) MovedTaskChannel(_ context.Context, tenant, task string) (string, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.anyMoved {
		return "", false, nil
	}
	var rows []*Message
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == task && m.Move.Moved() {
			rows = append(rows, m)
		}
	}
	if len(rows) == 0 {
		return "", false, nil
	}
	sort.Slice(rows, func(i, j int) bool {
		return newer(rows[j].ReceivedAt, rows[j].MsgID, rows[i].ReceivedAt, rows[i].MsgID)
	})
	return rows[0].Channel, true, nil
}

// viewMove is m's mark as a view element carries it: the place now filled in,
// zero for a row at home.
func viewMove(m *Message) MoveMark {
	if !m.Move.Moved() {
		return MoveMark{}
	}
	v := m.Move
	v.Channel, v.TaskID, v.ParentTaskID = m.Channel, m.TaskID, m.ParentTaskID
	return v
}
