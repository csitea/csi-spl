package hub

import (
	"context"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

// defaultFileUsageTTL: how long a tenant's listed file bytes are trusted
// before POST /v1/files lists t/<tenant>/files/ again (027 T020).
const defaultFileUsageTTL = time.Minute

// fileUsage caches each tenant's stored file bytes for the upload quota, so a
// new upload no longer lists the tenant's whole prefix (027 T020; before: one
// objects.list per new upload, O(files)). Uploads through this process are
// accounted at once (reserve / release), so the cache only misses bytes
// written by ANOTHER hub process (a Cloud Run revision overlapping a roll;
// max_instances=1 otherwise). That is the over-quota window: at most what
// other processes store for the tenant within ttl. Delete and the cicd-logs
// path drop the entry instead, so the next upload lists afresh.
type fileUsage struct {
	ttl time.Duration
	mu  sync.Mutex
	m   map[string]usageEntry
}

type usageEntry struct {
	bytes int64
	at    time.Time
}

func newFileUsage(ttl time.Duration) *fileUsage {
	if ttl <= 0 {
		ttl = defaultFileUsageTTL
	}
	return &fileUsage{ttl: ttl, m: map[string]usageEntry{}}
}

// load makes tenant's entry fresh: a prefix listing when it is absent or
// older than ttl. It is a best-effort cache: the lock is not held across the
// listing, so concurrent loads for the same tenant may each list, and the
// last one to finish is stored.
func (u *fileUsage) load(ctx context.Context, bs blob.Store, tenant string, now time.Time) error {
	e, ok := u.entry(tenant)
	if ok && now.Sub(e.at) < u.ttl {
		return nil
	}
	used, err := bs.PrefixBytes(ctx, "t/"+tenant+"/files/")
	if err != nil {
		return err
	}
	u.store(tenant, used, now)
	return nil
}

// entry returns tenant's cached entry, ok=false when there is none.
func (u *fileUsage) entry(tenant string) (usageEntry, bool) {
	u.mu.Lock()
	defer u.mu.Unlock()
	e, ok := u.m[tenant]
	return e, ok
}

// store records used bytes for tenant as listed at now.
func (u *fileUsage) store(tenant string, used int64, now time.Time) {
	u.mu.Lock()
	defer u.mu.Unlock()
	u.m[tenant] = usageEntry{bytes: used, at: now}
}

// over reports whether n more bytes would put tenant over q, reserving
// nothing (the Content-Length pre-check, before any byte is read).
func (u *fileUsage) over(ctx context.Context, bs blob.Store, q billing.Quota, tenant string, n int64, now time.Time) (bool, error) {
	if q.FileBytes <= 0 {
		return false, nil // unlimited: nothing to count, nothing to list
	}
	if err := u.load(ctx, bs, tenant, now); err != nil {
		return false, err
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	return q.Over(billing.Usage{FileBytes: u.m[tenant].bytes}, 0, 0, n) != "", nil
}

// reserve counts n more bytes against tenant when q allows it: ok=false is
// over quota and reserves nothing. The check and the add happen under one
// lock, so concurrent uploads cannot pass it together past the quota.
func (u *fileUsage) reserve(ctx context.Context, bs blob.Store, q billing.Quota, tenant string, n int64, now time.Time) (bool, error) {
	if q.FileBytes <= 0 {
		return true, nil
	}
	if err := u.load(ctx, bs, tenant, now); err != nil {
		return false, err
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	e := u.m[tenant]
	if q.Over(billing.Usage{FileBytes: e.bytes}, 0, 0, n) != "" {
		return false, nil
	}
	e.bytes += n
	u.m[tenant] = e
	return true, nil
}

// release gives back a reservation whose object was not stored (duplicate,
// promote failure).
func (u *fileUsage) release(tenant string, n int64) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if e, ok := u.m[tenant]; ok {
		e.bytes -= n
		u.m[tenant] = e
	}
}

// forget drops tenant's entry: the next upload lists its prefix again.
func (u *fileUsage) forget(tenant string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	delete(u.m, tenant)
}
