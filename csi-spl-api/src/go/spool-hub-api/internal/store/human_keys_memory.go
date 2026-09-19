package store

import (
	"context"
	"sort"
	"time"
)

// memKeys is Memory's copy of rdb 0018 human_keys, guarded by Memory.mu.
type memKeys struct {
	seq  int64
	rows []*HumanKey
}

func (s *Memory) AddHumanKey(_ context.Context, k HumanKey, now time.Time) (HumanKey, error) {
	if err := checkHumanKey(k); err != nil {
		return HumanKey{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	if _, ok := s.hum.humans[k.HumanID]; !ok {
		return HumanKey{}, ErrNotFound
	}
	for _, r := range s.keys.rows {
		if r.PublicKey == k.PublicKey {
			return HumanKey{}, ErrConflict
		}
	}
	for _, r := range s.keys.rows {
		if r.HumanID == k.HumanID && r.RevokedAt == nil {
			at := now
			r.RevokedAt, r.RevokedReason = &at, KeyRevokedReplaced
		}
	}
	s.keys.seq++
	k.ID, k.CreatedAt, k.RevokedAt, k.RevokedReason = s.keys.seq, now, nil, ""
	row := k
	s.keys.rows = append(s.keys.rows, &row)
	return row, nil
}

func (s *Memory) HumanKeys(_ context.Context, humanID string) ([]HumanKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []HumanKey{}
	for _, r := range s.keys.rows {
		if r.HumanID == humanID {
			out = append(out, *r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID > out[j].ID })
	return out, nil
}

func (s *Memory) HumanKey(_ context.Context, humanID string, id int64) (HumanKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range s.keys.rows {
		if r.ID == id && r.HumanID == humanID {
			return *r, nil
		}
	}
	return HumanKey{}, ErrNotFound
}

func (s *Memory) RevokeHumanKey(_ context.Context, humanID string, id int64, now time.Time) (HumanKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range s.keys.rows {
		if r.ID == id && r.HumanID == humanID {
			if r.RevokedAt == nil {
				at := now
				r.RevokedAt, r.RevokedReason = &at, KeyRevokedByUser
			}
			return *r, nil
		}
	}
	return HumanKey{}, ErrNotFound
}
