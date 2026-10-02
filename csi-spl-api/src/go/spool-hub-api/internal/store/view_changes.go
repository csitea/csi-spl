package store

import (
	"context"
	"sort"
	"time"
)

// Reconnect catch-up as a delta (db payload audit round 2, R2-2). A WUI tab
// that lost its socket re-read a whole channel page (~44 KB, 3..5 round
// trips) even when nothing was missed. With since= the topics list answers
// only the topics that changed after a cursor, and ViewChanges is how the hub
// finds them.
//
// A change is anything that alters what a held row shows: a new message, an
// edit, a kind change, a move, an archive, a reaction added - each leaves a
// timestamp - and a reaction REMOVED, which leaves no row behind. For that
// one the browser sends the reaction count it holds per message (Held), and
// a message whose count differs is a change.
//
// What leaves no trace at all - a move back home (it clears the mark), an
// unarchive (it clears the stamp), a deleted message - is not found here;
// those reach an open tab through their live frames only, as they did
// before (the full-page catch-up merged by msg_id and never removed or
// replaced a held row either).

// ChangeKind names why a row is in a ViewChanges answer.
type ChangeKind string

const (
	ChangeNew     ChangeKind = "new"
	ChangeEdit    ChangeKind = "edit"
	ChangeKindSet ChangeKind = "kind"
	ChangeMove    ChangeKind = "move"
	ChangeArchive ChangeKind = "archive"
	ChangeReact   ChangeKind = "react"
)

// ChangeQuery asks for every change in a tenant after Since.
type ChangeQuery struct {
	Since time.Time
	// Held is msg_id -> the number of reaction rows (actor x emoji) the
	// caller holds for it. A message whose current count differs is a react
	// change; a message the caller holds with no reactions is not listed.
	Held map[string]int
	// Max caps the answer; a full answer (len == Max) means "too many, read
	// the whole page" to the hub.
	Max int
	Now time.Time
}

// TopicChange is one changed row and where it is now. A row may appear once
// per kind.
type TopicChange struct {
	Kind     ChangeKind
	MsgID    string
	TaskID   string
	Channel  string // "" = a DM
	FromID   string
	ToID     string
	HomeChan string // moved rows: the channel the row was stored in ("" = none / a DM)
	HomeTask string // moved rows: the task it left on a message move ("" = none)
}

// ViewChanger is the change read a store offers for since=. Without it the
// hub answers the full page.
type ViewChanger interface {
	ViewChanges(ctx context.Context, tenant string, q ChangeQuery) ([]TopicChange, error)
}

var (
	_ ViewChanger = (*Memory)(nil)
	_ ViewChanger = (*Postgres)(nil)
)

func (s *Memory) ViewChanges(_ context.Context, tenant string, q ChangeQuery) ([]TopicChange, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []TopicChange
	for _, m := range s.liveLocked(tenant, q.Now) { // oldest first
		for _, k := range s.changeKindsLocked(tenant, m, q) {
			out = append(out, TopicChange{Kind: k, MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel,
				FromID: m.FromID, ToID: m.ToID, HomeChan: homeChan(m), HomeTask: m.Move.FromTask})
		}
	}
	// Postgres' order: by kind, then oldest first.
	sort.SliceStable(out, func(i, j int) bool { return changeOrder[out[i].Kind] < changeOrder[out[j].Kind] })
	if q.Max > 0 && len(out) > q.Max {
		out = out[:q.Max]
	}
	return out, nil
}

var changeOrder = map[ChangeKind]int{ChangeNew: 1, ChangeEdit: 2, ChangeKindSet: 3, ChangeMove: 4, ChangeArchive: 5, ChangeReact: 6}

// changeKindsLocked lists why m is a change after q.Since.
func (s *Memory) changeKindsLocked(tenant string, m *Message, q ChangeQuery) []ChangeKind {
	var ks []ChangeKind
	after := func(t time.Time) bool { return !t.IsZero() && t.After(q.Since) }
	if after(m.ReceivedAt) {
		ks = append(ks, ChangeNew)
	}
	if after(m.EditedAt) {
		ks = append(ks, ChangeEdit)
	}
	if after(m.KindSetAt) {
		ks = append(ks, ChangeKindSet)
	}
	if after(m.Move.At) {
		ks = append(ks, ChangeMove)
	}
	if after(m.ArchivedAt) {
		ks = append(ks, ChangeArchive)
	}
	rs := s.reactions[[2]string{tenant, m.MsgID}]
	added := false
	for _, r := range rs {
		added = added || after(r.at)
	}
	if n, held := q.Held[m.MsgID]; added || (held && n != len(rs)) {
		ks = append(ks, ChangeReact)
	}
	return ks
}

// homeChan is a moved row's home channel; "" for a row at home.
func homeChan(m *Message) string {
	if !m.Move.Moved() {
		return ""
	}
	return m.Move.FromChannel
}
