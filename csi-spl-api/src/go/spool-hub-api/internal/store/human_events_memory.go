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
	for _, e := range evs {
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
	return len(evs), nil
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
