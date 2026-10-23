package store

import (
	"context"
	"slices"
	"sort"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// The box ids a workspace has locked (spec 025 box-owner-lock.md section 5.2,
// row B5, SPL-2991). The hub's view points (hiddenByLock) ask it to learn
// whether any box of the workspace is locked at all; only then do they read
// each lock (BoxLock, verified and cached) to see who owns it. A workspace
// with no lock pays this one read and nothing else.

// LockedBoxLister is implemented by Memory and Postgres.
type LockedBoxLister interface {
	// LockedBoxes answers the box ids of tenant's box_locks rows, sorted;
	// none on a database without rdb 0213. A row is listed whether it
	// verifies or not: BoxLock decides that.
	LockedBoxes(ctx context.Context, tenant string) ([]string, error)
}

var (
	_ LockedBoxLister = (*Memory)(nil)
	_ LockedBoxLister = (*Postgres)(nil)
)

// LockedBoxes implements LockedBoxLister.
func (s *Memory) LockedBoxes(_ context.Context, tenant string) ([]string, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for k := range s.boxLocksLocked().locks {
		if k[0] == tenant {
			out = append(out, k[1])
		}
	}
	sort.Strings(out)
	return s.expectLocks.withListed(tenant, out), nil
}

// LockedBoxes implements LockedBoxLister: the cache first, else one read in
// the workspace scope.
func (s *Postgres) LockedBoxes(ctx context.Context, tenant string) ([]string, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	gen := s.locks.generation()
	if ids, ok := s.lockList.get(tenant, gen); ok {
		return ids, nil
	}
	if !s.hasBoxLocks(ctx) {
		return s.expectLocks.withListed(tenant, nil), nil
	}
	var out []string
	err := s.queryTenant(ctx, tenant, `SELECT box_id FROM box_locks WHERE tenant_id = $1 ORDER BY box_id`,
		[]any{tenant}, func(rows pgx.Rows) error {
			var b string
			if err := rows.Scan(&b); err != nil {
				return err
			}
			out = append(out, b)
			return nil
		})
	if err == nil {
		out = s.expectLocks.withListed(tenant, out) // B6, section 6.4
		s.lockList.put(tenant, gen, out)
	}
	return out, err
}

// lockedBoxCache holds LockedBoxes per workspace for boxLockCacheTTL. An
// entry is good only while the lock cache's generation is the one it was
// read under: every lock write through this store bumps it (boxLockCache
// forget), so this process never serves a list older than its own write.
type lockedBoxCache struct {
	mu sync.Mutex
	m  map[string]lockedBoxEntry
}

type lockedBoxEntry struct {
	gen uint64
	ids []string
	exp time.Time
}

func (c *lockedBoxCache) get(tenant string, gen uint64) ([]string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[tenant]
	if !ok || e.gen != gen || !hotNow().Before(e.exp) {
		return nil, false
	}
	return slices.Clone(e.ids), true
}

func (c *lockedBoxCache) put(tenant string, gen uint64, ids []string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.m == nil {
		c.m = map[string]lockedBoxEntry{}
	}
	c.m[tenant] = lockedBoxEntry{gen: gen, ids: slices.Clone(ids), exp: hotNow().Add(boxLockCacheTTL)}
}
