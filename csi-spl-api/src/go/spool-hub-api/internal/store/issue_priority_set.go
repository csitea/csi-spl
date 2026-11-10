package store

import (
	"context"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// When an issue's own prio was last set (rdb 0273, spec 150 3.4 item 4,
// SPL-5223): the hub compares it with its discussions' topic_priorities
// set_at, and the newest change wins. Only an update with
// IssuePatch.PriorityOwn that changes the priority stamps it.

// IssuePrioritySets reads the stamps. Both drivers implement it.
type IssuePrioritySets interface {
	// IssuePrioritySetAt answers the issues of numbers (nil: every issue of
	// the tenant) whose own priority was ever set, with its time; an issue
	// never set by hand is absent.
	IssuePrioritySetAt(ctx context.Context, tenantID string, numbers []int) (map[int]time.Time, error)
}

var (
	_ IssuePrioritySets = (*Memory)(nil)
	_ IssuePrioritySets = (*Postgres)(nil)
)

// IssuePrioritySetAt reads issues.priority_set_at; see IssuePrioritySets.
func (s *Postgres) IssuePrioritySetAt(ctx context.Context, tenant string, numbers []int) (map[int]time.Time, error) {
	out := map[int]time.Time{}
	if numbers != nil && len(numbers) == 0 {
		return out, nil
	}
	err := s.queryTenant(ctx, tenant, `SELECT number, priority_set_at FROM issues
		WHERE tenant_id = $1 AND priority_set_at IS NOT NULL AND ($2::int[] IS NULL OR number = ANY ($2::int[]))`,
		[]any{tenant, numbers}, func(r pgx.Rows) error {
			var n int
			var at time.Time
			err := r.Scan(&n, &at)
			out[n] = at.UTC()
			return err
		})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// IssuePrioritySetAt reads the in-memory stamps; see IssuePrioritySets.
func (s *Memory) IssuePrioritySetAt(_ context.Context, tenant string, numbers []int) (map[int]time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[int]time.Time{}
	for n, at := range s.iss.prioAt[tenant] {
		if numbers == nil || slices.Contains(numbers, n) {
			out[n] = at
		}
	}
	return out, nil
}

// stampPriorityLocked records an issue's own priority change. Caller holds
// Memory.mu.
func (m *memIssues) stampPriorityLocked(tenant string, number int, at time.Time) {
	if m.prioAt == nil {
		m.prioAt = map[string]map[int]time.Time{}
	}
	if m.prioAt[tenant] == nil {
		m.prioAt[tenant] = map[int]time.Time{}
	}
	m.prioAt[tenant][number] = at.UTC()
}
