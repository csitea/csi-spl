package store

import (
	"context"
	"sort"
	"time"
)

// Editing a sent message, and the append-only revision register behind it
// (specs/032 contracts/message-edit-v1.md, rdb 0026).
//
// An edit is NOT an overwrite. The message's current body is rewritten in
// place — same msg_id, same ts, same received_at, so it never moves in the
// topic — and every body it has ever had stays readable in the register. The
// owner asked for both halves in one breath: "both the old and the new msg
// should be stored ( for later feature to be able to compare those msgs )".
//
// Append-only means an edit INSERTs. Revision 1 is the body as first sent,
// captured at the FIRST edit; before that a message has no register rows at
// all, which is what makes "was this edited?" answerable from the message row
// alone.

// MessageRevision is one body a message has had (oldest first when listed).
type MessageRevision struct {
	// 1 = the body as first sent; 2..n = one per edit, in order.
	Revision int
	Body     string
	// The v:1 agent id that wrote this revision (revision 1 = the sender).
	EditedBy string
	EditedAt time.Time
}

// EditableMessage is one stored message read for the edit path: enough to
// authorise the edit (FromID, FromBox, EnvSig), to rebuild the envelope
// (Msg, Env, and the hub-envelope tags), and to answer with the view element
// the WUI already knows how to read.
type EditableMessage struct {
	MsgID        string
	TaskID       string
	Channel      string // "" = a DM
	ParentTaskID string // "" = a root topic
	FromBox      string
	FromID       string
	ToBox        string
	ToID         string
	Kind         string
	Body         string
	Msg          []byte // the inner v:1/v:2 object as stored
	Env          []byte // the canonical envelope as stored
	EnvSig       string // "" = browser-authored; anything else is box-signed
	TS           time.Time
	ReceivedAt   time.Time
	// EditedAt / EditedBy describe the LATEST edit; zero / "" = never edited.
	EditedAt time.Time
	EditedBy string
	// Revision is the highest revision in the register; 0 = never edited.
	Revision   int
	Deliveries []ViewDelivery
}

// Edited reports whether the message carries an edit marker.
func (m EditableMessage) Edited() bool { return !m.EditedAt.IsZero() }

// Edit is one edit ready to apply: the new body and the bytes the hub derived
// from it. The store writes them; it never re-encodes a message itself.
type Edit struct {
	Body     string
	Msg      []byte // the re-encoded canonical inner object
	Env      []byte // the re-marshalled canonical envelope
	EditedBy string // the v:1 agent id making the edit
	EditedAt time.Time
}

// MessageEdits is the edit half of the store contract (specs/032).
type MessageEdits interface {
	// GetEditable reads one message for the edit path. ErrNotFound when it is
	// absent, belongs to another tenant, or is already past retention at now —
	// the three cases the endpoint answers 404 for, kept indistinguishable on
	// purpose.
	GetEditable(ctx context.Context, tenantID, msgID string, now time.Time) (EditableMessage, error)

	// ApplyEdit rewrites the message's body and appends to the register, in
	// ONE transaction, and returns the new revision (2 on a first edit). The
	// original body becomes revision 1 in that same transaction when the
	// register is still empty, so no edit can lose the body it replaced.
	// ErrNotFound when the message is gone.
	ApplyEdit(ctx context.Context, tenantID, msgID string, e Edit) (int, error)

	// MessageRevisions lists every revision of a message, oldest first. Empty
	// for a message that was never edited.
	MessageRevisions(ctx context.Context, tenantID, msgID string) ([]MessageRevision, error)

	// DeleteMessage removes one message. Deliveries and the revision register
	// go with it. ErrNotFound when that tenant has no such row.
	DeleteMessage(ctx context.Context, tenantID, msgID string) error
}

// ---- Memory driver -----------------------------------------------------------

func (s *Memory) GetEditable(_ context.Context, tenant, msgID string, now time.Time) (EditableMessage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, msgID}]
	if !ok || !m.ExpiresAt.After(now) {
		return EditableMessage{}, ErrNotFound
	}
	out := EditableMessage{
		MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel, ParentTaskID: m.ParentTaskID,
		FromBox: m.FromBox, FromID: m.FromID, ToBox: m.ToBox, ToID: m.ToID, Kind: m.Kind,
		Body: m.Body, Msg: m.Msg, Env: m.Env, EnvSig: m.EnvSig, TS: m.TS, ReceivedAt: m.ReceivedAt,
		EditedAt: m.EditedAt, EditedBy: m.EditedBy, Deliveries: []ViewDelivery{},
	}
	if revs := s.revisions[[2]string{tenant, msgID}]; len(revs) > 0 {
		out.Revision = revs[len(revs)-1].Revision
	}
	for k, d := range s.deliveries {
		if k[0] == tenant && k[1] == msgID {
			out.Deliveries = append(out.Deliveries, ViewDelivery{ToBox: k[2], State: d.state})
		}
	}
	sort.Slice(out.Deliveries, func(i, j int) bool { return out.Deliveries[i].ToBox < out.Deliveries[j].ToBox })
	return out, nil
}

func (s *Memory) ApplyEdit(_ context.Context, tenant, msgID string, e Edit) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, msgID}
	m, ok := s.messages[k]
	if !ok {
		return 0, ErrNotFound
	}
	if s.revisions == nil {
		s.revisions = map[[2]string][]MessageRevision{}
	}
	revs := s.revisions[k]
	if len(revs) == 0 { // the body as first sent, captured before it is replaced
		revs = append(revs, MessageRevision{Revision: 1, Body: m.Body, EditedBy: m.FromID, EditedAt: m.ReceivedAt})
	}
	rev := revs[len(revs)-1].Revision + 1
	revs = append(revs, MessageRevision{Revision: rev, Body: e.Body, EditedBy: e.EditedBy, EditedAt: e.EditedAt})
	s.revisions[k] = revs
	m.Body, m.Msg, m.Env = e.Body, e.Msg, e.Env
	m.EditedAt, m.EditedBy = e.EditedAt, e.EditedBy
	return rev, nil
}

func (s *Memory) MessageRevisions(_ context.Context, tenant, msgID string) ([]MessageRevision, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]MessageRevision{}, s.revisions[[2]string{tenant, msgID}]...), nil
}

func (s *Memory) DeleteMessage(_ context.Context, tenant, msgID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, msgID}
	if _, ok := s.messages[k]; !ok {
		return ErrNotFound
	}
	delete(s.messages, k)
	delete(s.revisions, k)
	delete(s.reactions, k)
	for dk := range s.deliveries {
		if dk[0] == tenant && dk[1] == msgID {
			delete(s.deliveries, dk)
		}
	}
	return nil
}
