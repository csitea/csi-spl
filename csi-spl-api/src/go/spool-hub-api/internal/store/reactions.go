package store

import (
	"context"
	"time"
)

// StoredReaction is one actor's emoji on one message (rdb 0037). The message
// it hangs on may be is_parent 0 or 1; this row does not record which.
type StoredReaction struct {
	Emoji string
	Actor string
}

// MessageReactions is the emoji half of the store contract.
type MessageReactions interface {
	// AddReaction records actor's emoji on the message. A second add of the
	// same pair is a no-op. ErrNotFound when that tenant has no such message
	// inside retention at now.
	AddReaction(ctx context.Context, tenantID, msgID, actor, emoji string, now time.Time) error

	// RemoveReaction drops actor's emoji. Removing one that is not there is a
	// no-op. ErrNotFound when the message itself is gone or past retention.
	RemoveReaction(ctx context.Context, tenantID, msgID, actor, emoji string, now time.Time) error

	// ReactionsFor returns each message's reactions in the order they were
	// added (then actor). A message with none is absent from the map.
	ReactionsFor(ctx context.Context, tenantID string, msgIDs []string) (map[string][]StoredReaction, error)
}

type memReaction struct {
	emoji string
	actor string
	at    time.Time
}

func (s *Memory) AddReaction(_ context.Context, tenant, msgID, actor, emoji string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, msgID}
	m, ok := s.messages[k]
	if !ok || !m.ExpiresAt.After(now) {
		return ErrNotFound
	}
	if s.reactions == nil {
		s.reactions = map[[2]string][]memReaction{}
	}
	for _, r := range s.reactions[k] {
		if r.actor == actor && r.emoji == emoji {
			return nil
		}
	}
	s.reactions[k] = append(s.reactions[k], memReaction{emoji: emoji, actor: actor, at: now})
	return nil
}

func (s *Memory) RemoveReaction(_ context.Context, tenant, msgID, actor, emoji string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, msgID}
	m, ok := s.messages[k]
	if !ok || !m.ExpiresAt.After(now) {
		return ErrNotFound
	}
	list := s.reactions[k]
	kept := make([]memReaction, 0, len(list))
	for _, r := range list {
		if r.actor == actor && r.emoji == emoji {
			continue
		}
		kept = append(kept, r)
	}
	if len(kept) == 0 {
		delete(s.reactions, k)
		return nil
	}
	s.reactions[k] = kept
	return nil
}

func (s *Memory) ReactionsFor(_ context.Context, tenant string, msgIDs []string) (map[string][]StoredReaction, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string][]StoredReaction{}
	for _, id := range msgIDs {
		list := s.reactions[[2]string{tenant, id}]
		if len(list) == 0 {
			continue
		}
		// Copy in added order. The slice is already appended in that order.
		rows := make([]StoredReaction, len(list))
		for i, r := range list {
			rows[i] = StoredReaction{Emoji: r.emoji, Actor: r.actor}
		}
		out[id] = rows
	}
	return out, nil
}
