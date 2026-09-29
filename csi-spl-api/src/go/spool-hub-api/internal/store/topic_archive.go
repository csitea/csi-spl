package store

import (
	"context"
	"sort"
	"time"
)

// Archiving and deleting a topic card (SPL-983, specs/041, rdb 0065).
//
// A CARD is a level-1 message drawn in the middle pane. It is either the
// first message of a task that is not the lobby's (every channel and DM
// card: its topic is that task), or a level-1 row of the one shared lobby
// task (its topic is its message-rooted thread, task_id = its msg_id). The
// hub decides which, because only the hub knows the lobby task id; the store
// takes the answer as ownTask ("" = a lobby card).
//
// Archive stamps archived_at / archived_by on the card row: the soft-delete
// flag. Every list then leaves the topic out. Because the hub stamps only a
// card, "an archived row in task T" means "T is archived" for every T but
// the lobby's, where it hides that one row. Delete walks the topic and
// removes every row in one transaction; the four tables that reference a
// message go with it (ON DELETE CASCADE).

// CardState is what the archive / delete path needs to know about a row.
type CardState struct {
	MsgID    string
	TaskID   string
	IsParent int
	// FirstOfTask: no is_parent=1 row of the same task was received before
	// this one - i.e. this is the task's opening card, the row TopicChannel
	// and TaskCard treat as the opener (is_parent=1, earliest received). A
	// plain reply (is_parent=0) received earlier does NOT unseat the card:
	// a topic whose oldest row is a channel reply or a moved-in message
	// (is_parent=0) was otherwise stuck - neither archivable nor deletable,
	// prd t1 topic e802196b, 2026-09-29 (SPL bug).
	FirstOfTask bool
	// IssueTopic: the task is an issue's discussion (rdb 0047), which
	// keeps its own lifecycle (specs/041 §3.2).
	IssueTopic bool
	ArchivedAt time.Time // zero = not archived
	ArchivedBy string
}

// TopicSet is every row of a card's topic: the card first, then the rest in
// the order they were found. TaskIDs are the tasks the walk covered.
type TopicSet struct {
	MsgIDs  []string
	TaskIDs []string
}

// Replies is the number of rows a delete removes besides the card.
func (t TopicSet) Replies() int {
	if len(t.MsgIDs) == 0 {
		return 0
	}
	return len(t.MsgIDs) - 1
}

// ArchivedQuery pages GET /v1/view/archived: newest archived_at first,
// strictly before (BeforeAt, BeforeID) when BeforeAt is set.
type ArchivedQuery struct {
	Reader         string // "" = no door (the door-off rig)
	ReaderChannels []string
	BeforeAt       time.Time
	BeforeID       string
	Limit          int
	Now            time.Time
}

// ArchivedCard is one archived card with its view element.
type ArchivedCard struct {
	ViewMsg
	TaskID     string
	Channel    string
	FromID     string
	ArchivedAt time.Time
	ArchivedBy string
}

// maxTopicWalk bounds the walk: a topic nested deeper than this is a bug,
// not a topic, and the delete refuses rather than loops.
const maxTopicWalk = 32

// TopicArchive is the archive half of the store contract (specs/041).
type TopicArchive interface {
	// CardState reads one row in retention. ErrNotFound as GetEditable.
	CardState(ctx context.Context, tenantID, msgID string, now time.Time) (CardState, error)
	// SetArchived stamps (archived=true) or clears the flag on msgID and
	// answers the row's state after the write. Archiving an archived row
	// keeps its first stamp. ErrNotFound when the row is gone.
	SetArchived(ctx context.Context, tenantID, msgID, by string, at time.Time, archived bool) (CardState, error)
	// TopicOf walks the card's topic (see the package note) and answers it.
	TopicOf(ctx context.Context, tenantID, msgID, ownTask string) (TopicSet, error)
	// DeleteTopic walks the topic and deletes every row of it in ONE
	// transaction, and answers what it deleted. ErrNotFound when the card is
	// already gone.
	DeleteTopic(ctx context.Context, tenantID, msgID, ownTask string) (TopicSet, error)
	// ArchivedCards lists the archived cards the reader may read.
	ArchivedCards(ctx context.Context, tenantID string, q ArchivedQuery) ([]ArchivedCard, error)
	// TopicReplies counts every row of each card's topic but the card, in
	// retention (the Archive view's reply count). ownTasks[i] is msgIDs[i]'s.
	TopicReplies(ctx context.Context, tenantID string, msgIDs, ownTasks []string) (map[string]int, error)
}

// walkTopic is the walk both drivers share. next answers, for a set of task
// ids, the (msg_id, task_id) of every row whose task_id or parent_task_id is
// one of them. A row's msg_id is a task too: a message-rooted thread opened
// on it lives under task_id = that msg_id.
func walkTopic(card, ownTask string, next func(tasks []string) ([][2]string, error)) (TopicSet, error) {
	seenMsg := map[string]bool{card: true}
	seenTask := map[string]bool{card: true}
	set := TopicSet{MsgIDs: []string{card}, TaskIDs: []string{card}}
	if ownTask != "" && ownTask != card {
		seenTask[ownTask] = true
		set.TaskIDs = append(set.TaskIDs, ownTask)
	}
	frontier := append([]string{}, set.TaskIDs...)
	for round := 0; len(frontier) > 0; round++ {
		if round >= maxTopicWalk {
			return TopicSet{}, ErrConflict
		}
		rows, err := next(frontier)
		if err != nil {
			return TopicSet{}, err
		}
		frontier = nil
		for _, r := range rows {
			msgID, task := r[0], r[1]
			if !seenMsg[msgID] {
				seenMsg[msgID] = true
				set.MsgIDs = append(set.MsgIDs, msgID)
			}
			for _, t := range []string{msgID, task} {
				if !seenTask[t] {
					seenTask[t] = true
					set.TaskIDs = append(set.TaskIDs, t)
					frontier = append(frontier, t)
				}
			}
		}
	}
	return set, nil
}

// ---- Memory driver -----------------------------------------------------------

func (s *Memory) CardState(_ context.Context, tenant, msgID string, now time.Time) (CardState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, msgID}]
	if !ok || !m.ExpiresAt.After(now) {
		return CardState{}, ErrNotFound
	}
	return s.cardStateLocked(tenant, m), nil
}

func (s *Memory) cardStateLocked(tenant string, m *Message) CardState {
	first := true
	for k, o := range s.messages {
		if k[0] == tenant && o.TaskID == m.TaskID && parentBit(o.IsParent) == 1 &&
			newer(m.ReceivedAt, m.MsgID, o.ReceivedAt, o.MsgID) {
			first = false
			break
		}
	}
	return CardState{MsgID: m.MsgID, TaskID: m.TaskID, IsParent: parentBit(m.IsParent), FirstOfTask: first, IssueTopic: s.iss.isTask(tenant, m.TaskID),
		ArchivedAt: m.ArchivedAt, ArchivedBy: m.ArchivedBy}
}

func (s *Memory) SetArchived(_ context.Context, tenant, msgID, by string, at time.Time, archived bool) (CardState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, msgID}]
	if !ok {
		return CardState{}, ErrNotFound
	}
	switch {
	case !archived:
		m.ArchivedAt, m.ArchivedBy = time.Time{}, ""
	case m.ArchivedAt.IsZero():
		m.ArchivedAt, m.ArchivedBy = at, by
	}
	return s.cardStateLocked(tenant, m), nil
}

func (s *Memory) topicLocked(tenant, msgID, ownTask string) (TopicSet, error) {
	if _, ok := s.messages[[2]string{tenant, msgID}]; !ok {
		return TopicSet{}, ErrNotFound
	}
	return walkTopic(msgID, ownTask, func(tasks []string) ([][2]string, error) {
		want := map[string]bool{}
		for _, t := range tasks {
			want[t] = true
		}
		var out [][2]string
		for k, m := range s.messages {
			if k[0] == tenant && (want[m.TaskID] || (m.ParentTaskID != "" && want[m.ParentTaskID])) {
				out = append(out, [2]string{m.MsgID, m.TaskID})
			}
		}
		sort.Slice(out, func(i, j int) bool { return out[i][0] < out[j][0] })
		return out, nil
	})
}

func (s *Memory) TopicOf(_ context.Context, tenant, msgID, ownTask string) (TopicSet, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.topicLocked(tenant, msgID, ownTask)
}

func (s *Memory) DeleteTopic(_ context.Context, tenant, msgID, ownTask string) (TopicSet, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	set, err := s.topicLocked(tenant, msgID, ownTask)
	if err != nil {
		return TopicSet{}, err
	}
	for _, id := range set.MsgIDs {
		k := [2]string{tenant, id}
		delete(s.messages, k)
		delete(s.revisions, k)
		delete(s.kindChanges, k)
		delete(s.reactions, k)
		for dk := range s.deliveries {
			if dk[0] == tenant && dk[1] == id {
				delete(s.deliveries, dk)
			}
		}
	}
	return set, nil
}

func (s *Memory) ArchivedCards(_ context.Context, tenant string, q ArchivedQuery) ([]ArchivedCard, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []ArchivedCard
	for _, m := range s.liveLocked(tenant, q.Now) {
		if m.ArchivedAt.IsZero() {
			continue
		}
		if q.Reader != "" && !readableBy(m.Channel, m.FromID, m.ToID, q.Reader, q.ReaderChannels) {
			continue
		}
		if !q.BeforeAt.IsZero() && !newer(q.BeforeAt, q.BeforeID, m.ArchivedAt, m.MsgID) {
			continue
		}
		out = append(out, ArchivedCard{
			ViewMsg: ViewMsg{MsgID: m.MsgID, ReceivedAt: m.ReceivedAt, Env: m.Env, Deliveries: []ViewDelivery{},
				EditedAt: m.EditedAt, EditedBy: m.EditedBy, IsParent: parentBit(m.IsParent), TypedBy: m.TypedBy},
			TaskID: m.TaskID, Channel: m.Channel, FromID: m.FromID, ArchivedAt: m.ArchivedAt, ArchivedBy: m.ArchivedBy,
		})
	}
	sort.Slice(out, func(i, j int) bool { return newer(out[i].ArchivedAt, out[i].MsgID, out[j].ArchivedAt, out[j].MsgID) })
	if q.Limit > 0 && len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out, nil
}

func (s *Memory) TopicReplies(_ context.Context, tenant string, msgIDs, ownTasks []string) (map[string]int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]int{}
	for i, id := range msgIDs {
		own := ""
		if i < len(ownTasks) {
			own = ownTasks[i]
		}
		set, err := s.topicLocked(tenant, id, own)
		if err != nil {
			continue
		}
		out[id] = set.Replies()
	}
	return out, nil
}

// archivedHiddenLocked is the list filter on one row: its own card, its
// task's card (the lobby's excepted) or the lobby card whose thread it is
// in is archived.
func (s *Memory) archivedHiddenLocked(tenant string, m *Message, lobby string) bool {
	for k, z := range s.messages {
		if k[0] != tenant || z.ArchivedAt.IsZero() {
			continue
		}
		if z.MsgID == m.MsgID || z.MsgID == m.TaskID || (z.TaskID == m.TaskID && m.TaskID != lobby) ||
			(m.ParentTaskID != "" && z.TaskID == m.ParentTaskID && m.ParentTaskID != lobby) {
			return true
		}
	}
	return false
}

// topicArchivedLocked: task is archived (its card is), or it is the thread
// of an archived lobby card.
func (s *Memory) topicArchivedLocked(tenant, task, lobby string) bool {
	for k, z := range s.messages {
		if k[0] == tenant && !z.ArchivedAt.IsZero() && (z.MsgID == task || (z.TaskID == task && task != lobby)) {
			return true
		}
	}
	return false
}
