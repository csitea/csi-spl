package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-4490 (row 3 of the api top-10 errors, SPL-4420): the relay loops logged
// 96 `write: broken pipe` ERROR lines on prd, 92 of them one DB burst logged
// once per workspace by every loop, 4 a pooled connection the server had
// dropped.

// pipeErr is the error pgx returns for a write to a dead pooled connection
// that failed before anything reached the server: pgconn.SafeToRetry is true.
type pipeErr struct{ safe bool }

func (e pipeErr) Error() string {
	return "write unix ->/cloudsql/p:r:i/.s.PGSQL.5432: write: broken pipe"
}
func (e pipeErr) SafeToRetry() bool { return e.safe }

// pipeStore is the memory store whose relay-loop reads fail: the next
// `once` reads of each site fail with err, or every read while down is set.
type pipeStore struct {
	*store.Memory
	mu    sync.Mutex
	once  map[string]int
	calls map[string]int
	err   error
	down  atomic.Bool
}

func (p *pipeStore) hit(site string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls[site]++
	if p.down.Load() {
		return p.err
	}
	if p.once[site] > 0 {
		p.once[site]--
		return p.err
	}
	return nil
}

// failOnce makes the next read of every site fail once.
func (p *pipeStore) failOnce() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, s := range relayLoopSites {
		p.once[s] = 1
	}
	p.calls = map[string]int{}
}

func (p *pipeStore) QueuedFor(ctx context.Context, tenant, box string, now time.Time) ([]store.Queued, error) {
	if err := p.hit("relay queue"); err != nil {
		return nil, err
	}
	return p.Memory.QueuedFor(ctx, tenant, box, now)
}

func (p *pipeStore) UnheardPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]store.Queued, error) {
	if err := p.hit("relay unheard posts"); err != nil {
		return nil, err
	}
	return p.Memory.UnheardPosts(ctx, tenant, since, until, limit)
}

func (p *pipeStore) UnansweredPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]store.Queued, error) {
	if err := p.hit("relay unanswered posts"); err != nil {
		return nil, err
	}
	return p.Memory.UnansweredPosts(ctx, tenant, since, until, limit)
}

func (p *pipeStore) ReescalatablePosts(ctx context.Context, tenant string, since, escalatedBefore, until time.Time, maxAttempts, limit int) ([]store.Queued, error) {
	if err := p.hit("relay reescalatable posts"); err != nil {
		return nil, err
	}
	return p.Memory.ReescalatablePosts(ctx, tenant, since, escalatedBefore, until, maxAttempts, limit)
}

func (p *pipeStore) UnackedFor(ctx context.Context, tenant, box string, now, sentBefore time.Time) ([]store.Queued, error) {
	if err := p.hit("unacked rows"); err != nil {
		return nil, err
	}
	return p.Memory.UnackedFor(ctx, tenant, box, now, sentBefore)
}

func (p *pipeStore) NackedPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]store.Queued, error) {
	if err := p.hit("relay nacked posts"); err != nil {
		return nil, err
	}
	return p.Memory.NackedPosts(ctx, tenant, since, until, limit)
}

// newPipeRelay is newFlakyRelay on a pipeStore with `tenants` workspaces,
// one committing box each.
func newPipeRelay(t *testing.T, tenants int, err error) (*pipeStore, *flakyRelay) {
	t.Helper()
	_, key, _ := ed25519.GenerateKey(nil)
	p := &pipeStore{Memory: store.NewMemory(), once: map[string]int{}, calls: map[string]int{}, err: err}
	f := &flakyRelay{log: &syncWriter{w: &bytes.Buffer{}}}
	var clock atomic.Int64
	e := newEnv(t, func(o *hub.Options) {
		fallbackOpts(o, key, true)
		o.Store, o.Log = p, zerolog.New(f.log)
		o.UnansweredGrace, o.ReescalateEvery, o.ReescalateMax = 8*time.Second, 8*time.Second, 3
		o.Now = func() time.Time { return time.Now().Add(time.Duration(clock.Load())) }
	})
	e.st = p
	for range tenants {
		tid, _ := e.tenant()
		b := e.box(tid, "box-c", "CLE-13")
		e.pin(tid, b)
		e.commitBox(tid, b, "CLE-13", true)
	}
	f.tick = func(n int, step time.Duration) {
		for range n {
			clock.Add(int64(step))
			e.srv.Relay(context.Background())
		}
	}
	return p, f
}

// A read that failed before the send is retried once and works: no line, and
// each site read twice. CONTROL: before the fix every site logged one ERROR
// and was read once.
func TestRelayLoopRetriesASafeBrokenPipeOnce(t *testing.T) {
	p, f := newPipeRelay(t, 1, pipeErr{safe: true})
	p.failOnce()
	f.tick(1, 16*time.Second)
	got := f.levels(t)
	for _, site := range relayLoopSites {
		if len(got[site]) != 0 {
			t.Errorf("%q: %v after a broken pipe the retry cured, want no line", site, got[site])
		}
		if n := p.calls[site]; n != 2 {
			t.Errorf("%q: read %d times, want 2 (the failure and one retry)", site, n)
		}
	}
}

// A write that may have reached the server is never retried: read once, and
// the failure logged as before.
func TestRelayLoopNeverRetriesAnUnsafeError(t *testing.T) {
	p, f := newPipeRelay(t, 1, pipeErr{safe: false})
	p.failOnce()
	f.tick(1, 16*time.Second)
	got := f.levels(t)
	for _, site := range relayLoopSites {
		if n := p.calls[site]; n != 1 {
			t.Errorf("%q: read %d times, want 1 (no retry)", site, n)
		}
		if got[site]["error"] != 1 {
			t.Errorf("%q: %v, want 1 ERROR line", site, got[site])
		}
	}
}

// A pass that fails for every workspace logs one line per loop, not one per
// workspace, with the workspace count: ERROR the first pass, WARN after.
// CONTROL: before the fix 3 workspaces logged 3 ERROR lines per site.
func TestRelayLoopAllWorkspacesFailingLogsOneLinePerPass(t *testing.T) {
	p, f := newPipeRelay(t, 3, errors.New("write unix ->/cloudsql/p:r:i/.s.PGSQL.5432: write: broken pipe"))
	p.down.Store(true)
	f.tick(2, 16*time.Second)
	got := f.levels(t)
	for _, site := range relayLoopSites {
		if got[site]["error"] != 1 || got[site]["warn"] != 1 {
			t.Errorf("%q: %v in 2 failing passes over 3 workspaces, want 1 error + 1 warn", site, got[site])
		}
	}
	if n := countField(f, "workspaces", 3); n != 2*len(relayLoopSites) {
		t.Errorf("%d summary lines carry workspaces=3, want %d", n, 2*len(relayLoopSites))
	}
}

// countField counts the log lines whose JSON field key is n.
func countField(f *flakyRelay, key string, n int) int {
	f.log.mu.Lock()
	defer f.log.mu.Unlock()
	c := 0
	for _, line := range bytes.Split(f.log.w.Bytes(), []byte("\n")) {
		if bytes.Contains(line, []byte(`"`+key+`":`+strconv.Itoa(n)+`,`)) || bytes.Contains(line, []byte(`"`+key+`":`+strconv.Itoa(n)+`}`)) {
			c++
		}
	}
	return c
}
