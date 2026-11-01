package store

import (
	"context"
	"time"
)

// memEvents is Memory's copy of rdb 0045 human_events, guarded by Memory.mu.
type memEvents struct {
	seq  int64
	rows []HumanEvent // ascending event_id
}

func (s *Memory) AddHumanEvents(_ context.Context, humanID string, evs []HumanEvent, now time.Time) (int, error) {
	for _, e := range evs {
		if err := CheckHumanEvent(e); err != nil {
			return 0, err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if _, ok := s.hum.humans[humanID]; !ok {
		return 0, ErrNotFound
	}
	stored := 0
	for _, e := range evs {
		if s.events.resent(humanID, e) {
			continue
		}
		stored++
		s.events.seq++
		e.ID, e.HumanID, e.Kind, e.ReceivedAt = s.events.seq, humanID, HumanEventKindError, now
		s.events.rows = append(s.events.rows, e)
	}
	// Trim to the newest HumanEventsKeep of this human.
	n := 0
	for _, r := range s.events.rows {
		if r.HumanID == humanID {
			n++
		}
	}
	if drop := n - HumanEventsKeep; drop > 0 {
		kept := s.events.rows[:0]
		for _, r := range s.events.rows {
			if r.HumanID == humanID && drop > 0 {
				drop--
				continue
			}
			kept = append(kept, r)
		}
		s.events.rows = kept
	}
	return stored, nil
}

// resent reports a stored row of humanID with e's error_id and occurred_at:
// rdb 0248's unique index (an empty error_id or no occurred_at never match).
func (m *memEvents) resent(humanID string, e HumanEvent) bool {
	if e.ErrorID == "" || e.OccurredAt == nil {
		return false
	}
	for _, r := range m.rows {
		if r.HumanID == humanID && r.ErrorID == e.ErrorID && r.OccurredAt != nil && r.OccurredAt.Equal(*e.OccurredAt) {
			return true
		}
	}
	return false
}

func (s *Memory) HumanEventsPage(_ context.Context, humanID string, before int64, limit int) ([]HumanEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []HumanEvent{}
	for i := len(s.events.rows) - 1; i >= 0 && len(out) < limit; i-- {
		r := s.events.rows[i]
		if r.HumanID == humanID && (before <= 0 || r.ID < before) {
			out = append(out, r)
		}
	}
	return out, nil
}

func (s *Memory) ClearHumanEvents(_ context.Context, humanID string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	kept := s.events.rows[:0]
	n := 0
	for _, r := range s.events.rows {
		if r.HumanID == humanID {
			n++
			continue
		}
		kept = append(kept, r)
	}
	s.events.rows = kept
	return n, nil
}

// DeleteHumanEvents deletes the named rows of humanID only (spec 162 B2).
func (s *Memory) DeleteHumanEvents(_ context.Context, humanID string, ids []int64) (int, error) {
	want := make(map[int64]bool, len(ids))
	for _, id := range ids {
		want[id] = true
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	kept := s.events.rows[:0]
	n := 0
	for _, r := range s.events.rows {
		if r.HumanID == humanID && want[r.ID] {
			n++
			continue
		}
		kept = append(kept, r)
	}
	s.events.rows = kept
	return n, nil
}
