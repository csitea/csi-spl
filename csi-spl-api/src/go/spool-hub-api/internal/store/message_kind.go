package store

import (
	"context"
	"time"
)

// Setting a sent message's kind (SPL-952, rdb 0060).
//
// The kind is inside the signed inner object, and an agent's envelope is
// signed with a key the hub does not hold, so a change cannot be written back
// into the envelope. It is hub metadata instead: messages.kind becomes the
// current kind (search and the topic kind counts follow it), kind_set_by /
// kind_set_at mark that it was changed, and message_kind_changes keeps every
// change, append-only, beside the envelope's original.

// KindChange is one change of a message's kind.
type KindChange struct {
	Seq   int // 1..n, in order
	From  string
	To    string
	SetBy string // the v:1 id that set it
	SetAt time.Time
}

// MessageKinds is the kind half of the store contract.
type MessageKinds interface {
	// SetKind makes kind the message's current kind and appends the change to
	// the register, in ONE transaction, and returns the change it recorded.
	// Setting the kind a message already has records nothing and returns a
	// zero change (Seq 0). ErrNotFound when the message is gone.
	SetKind(ctx context.Context, tenantID, msgID, kind, by string, at time.Time) (KindChange, error)

	// KindChanges lists every change of a message's kind, oldest first.
	KindChanges(ctx context.Context, tenantID, msgID string) ([]KindChange, error)
}

// ---- Memory driver -----------------------------------------------------------

func (s *Memory) SetKind(_ context.Context, tenant, msgID, kind, by string, at time.Time) (KindChange, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, msgID}
	m, ok := s.messages[k]
	if !ok {
		return KindChange{}, ErrNotFound
	}
	if m.Kind == kind {
		return KindChange{}, nil
	}
	if s.kindChanges == nil {
		s.kindChanges = map[[2]string][]KindChange{}
	}
	c := KindChange{Seq: len(s.kindChanges[k]) + 1, From: m.Kind, To: kind, SetBy: by, SetAt: at}
	s.kindChanges[k] = append(s.kindChanges[k], c)
	m.Kind, m.KindSetBy, m.KindSetAt = kind, by, at
	return c, nil
}

func (s *Memory) KindChanges(_ context.Context, tenant, msgID string) ([]KindChange, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]KindChange{}, s.kindChanges[[2]string{tenant, msgID}]...), nil
}
