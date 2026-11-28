package store

import (
	"context"
	"sort"
	"time"
)

// DropAgentInvites implements AgentInvites on Memory: every invited (or
// announced) seat of agent on box in tenant moves to removed, archived
// channels included, as on Postgres.
func (s *Memory) DropAgentInvites(_ context.Context, tenant, box, agent string, _ time.Time) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	hit := map[string]bool{}
	for key := range s.ch.invited {
		if key[0] == tenant && key[2] == box && key[3] == agent {
			delete(s.ch.invited, key)
			s.ch.removed[key] = struct{}{}
			hit[key[1]] = true
		}
	}
	bag := s.ch.subs[[2]string{tenant, box}]
	for ch, ids := range bag {
		kept := make([]string, 0, len(ids))
		for _, id := range ids {
			if id != agent {
				kept = append(kept, id)
				continue
			}
			s.ch.removed[[4]string{tenant, ch, box, agent}] = struct{}{}
			hit[ch] = true
		}
		bag[ch] = kept
	}
	if len(hit) == 0 {
		return nil, nil
	}
	out := make([]string, 0, len(hit))
	for ch := range hit {
		out = append(out, ch)
	}
	sort.Strings(out)
	return out, nil
}
