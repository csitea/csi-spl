package store

import (
	"context"
	"errors"
	"fmt"
	"math/rand" // nosemgrep: go.lang.security.audit.crypto.math_random.math-random-used -- a seeded, replayable op sequence for a test (SPOOL_TEST_WSDOC_SEED), never a secret
	"os"
	"sync"
	"sync/atomic"
	"testing"
)

// TestWorkspaceDocConcurrent (spec 113 3.5, T002 Done (b)): 8 writers on 8
// connections x 500 mixed ops on ONE doc: text edits, moves, adds, delete
// subtree; half the structural ops carry the rev read just before (retried on
// 412), half are blind (rev 0), so the lock alone orders them. The check runs
// after each committed op and at the end; the rev log is replayed into a model
// that must equal the final tree, every committed op must be in the log, and
// every item's last committed text edit must be what the DB holds. It prints
// committed / 412 / 404 / refused, lock waits and deadlock_detected, and fails
// on 0 lock waits (no contention proves nothing) and on any deadlock.
func TestWorkspaceDocConcurrent(t *testing.T) {
	_, tid := wsDocPG(t)
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, os.Getenv("SPOOL_TEST_PG_DSN"), PoolLimits{MaxConns: 12})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	var waits atomic.Int64
	wsDocLockWaits = &waits
	t.Cleanup(func() { wsDocLockWaits = nil })
	seed := wsSeeds([]int64{113})[0]
	c := &wsConc{t: t, pg: pg, tenant: tid, seed: seed, edits: map[string]wsEdit{}}
	c.seedDoc(60)
	writers, ops := wsEnvInt("SPOOL_TEST_WSDOC_WRITERS", 8), wsEnvInt("SPOOL_TEST_WSDOC_CONC_OPS", 500)
	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(seed*100 + int64(w)))
			for i := 0; i < ops && c.failed.Load() == nil; i++ {
				c.op(rng, fmt.Sprintf("w%d-%d", w, i))
			}
		}(w)
	}
	wg.Wait()
	if f := c.failed.Load(); f != nil {
		t.Fatalf("WSDOC replay: SPOOL_TEST_WSDOC_SEED=%d: %v", seed, *f)
	}
	t.Logf("WSDOC concurrent: writers=%d ops=%d committed=%d 412=%d 404=%d refused=%d lock_waits=%d deadlock_detected=%d",
		writers, writers*ops, c.n[0].Load(), c.n[1].Load(), c.n[2].Load(), c.n[3].Load(), waits.Load(), c.deadlocks.Load())
	if c.deadlocks.Load() != 0 || waits.Load() == 0 {
		t.Fatalf("WSDOC replay: SPOOL_TEST_WSDOC_SEED=%d: deadlocks %d (want 0), lock waits %d (want > 0)",
			seed, c.deadlocks.Load(), waits.Load())
	}
	c.replay()
}

// wsEdit is a committed text edit: the item rev it produced and its title.
type wsEdit struct {
	rev   int64
	title string
}

// wsConc is the shared state of the concurrent run.
type wsConc struct {
	t         *testing.T
	pg        *Postgres
	tenant    string
	doc, root string
	seed      int64
	n         [4]atomic.Int64 // committed, 412, 404, refused
	deadlocks atomic.Int64
	failed    atomic.Pointer[string]
	mu        sync.Mutex
	commits   map[int64]string // rev -> item of each committed structural op
	edits     map[string]wsEdit
}

// seedDoc creates the doc and n items through the ops (so the log covers them).
func (c *wsConc) seedDoc(n int) {
	ctx := context.Background()
	doc, root, err := c.pg.DocCreate(ctx, c.tenant, "concurrent", "", "conc")
	if err != nil {
		c.t.Fatal(err)
	}
	c.doc, c.root, c.commits = doc, root, map[int64]string{}
	ids := []string{root}
	rng := rand.New(rand.NewSource(c.seed))
	for i := 0; i < n; i++ {
		res, err := c.pg.DocItemAdd(ctx, c.tenant, DocItemAddReq{DocID: doc, Anchor: ids[rng.Intn(len(ids))], Where: DocChild, Actor: "seed"})
		if err != nil {
			c.t.Fatal(err)
		}
		ids = append(ids, res.ItemID)
	}
}

func (c *wsConc) fail(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	c.failed.CompareAndSwap(nil, &msg)
}

// op is one writer op: re-read the doc (and its rev), pick, act; on 412 retry
// with a fresh read, up to 20 times.
func (c *wsConc) op(rng *rand.Rand, tag string) {
	ctx := context.Background()
	kind := rng.Intn(100)
	for try := 0; try < 20; try++ {
		rev, err := wsDocRev(ctx, c.pg, c.tenant, c.doc)
		items, err2 := c.pg.DocSubtree(ctx, c.tenant, c.doc, "")
		if err = errors.Join(err, err2); err != nil {
			c.fail("%s read: %v", tag, err)
			return
		}
		if !c.outcome(tag, c.act(ctx, rng, kind, rev, items, tag)) {
			return
		}
	}
}

// act runs the chosen op on the read state; it returns its error and, when
// committed, has recorded it.
func (c *wsConc) act(ctx context.Context, rng *rand.Rand, kind int, rev int64, items []DocItem, tag string) error {
	it := items[rng.Intn(len(items))]
	to := items[rng.Intn(len(items))]
	if rng.Intn(2) == 0 {
		rev = 0 // blind: only the lock orders it
	}
	var res DocOpResult
	var err error
	switch {
	case kind < 40:
		var next int64
		if next, err = c.pg.DocItemUpdateField(ctx, c.tenant, c.doc, it.ID, "title", tag, it.Rev); err == nil {
			c.mu.Lock()
			if e := c.edits[it.ID]; next > e.rev {
				c.edits[it.ID] = wsEdit{rev: next, title: tag}
			}
			c.mu.Unlock()
		}
		return err
	case kind < 75:
		res, err = c.pg.DocItemMove(ctx, c.tenant, DocItemMoveReq{DocID: c.doc, Rev: rev, ItemID: it.ID, Parent: to.ID, Ord: rng.Intn(4), Actor: tag})
	case kind < 90:
		res, err = c.pg.DocItemAdd(ctx, c.tenant, DocItemAddReq{DocID: c.doc, Rev: rev, Anchor: to.ID, Where: DocChild, Ord: rng.Intn(4), Actor: tag})
	default:
		res, err = c.pg.DocItemDeleteSubtree(ctx, c.tenant, c.doc, rev, it.ID, tag)
	}
	if err == nil {
		c.mu.Lock()
		c.commits[res.Rev] = res.ItemID
		c.mu.Unlock()
		if msg := wsCheck(ctx, c.pg, c.tenant, c.doc); msg != "" {
			c.fail("%s: invariants after rev %d: %s", tag, res.Rev, msg)
		}
	}
	return err
}

// outcome counts err; true means retry (a 412).
func (c *wsConc) outcome(tag string, err error) bool {
	switch {
	case err == nil:
		c.n[0].Add(1)
	case errors.Is(err, ErrDocStale):
		c.n[1].Add(1)
		return true
	case errors.Is(err, ErrNotFound):
		c.n[2].Add(1)
	case errors.Is(err, ErrDocRefused):
		c.n[3].Add(1)
	case sqlState(err) == "40P01":
		c.deadlocks.Add(1)
	default:
		c.fail("%s: an outcome outside the four: %v", tag, err)
	}
	return false
}

// replay: the rev log is 1..rev with no hole, holds every committed op, and
// replayed into a model equals the final tree; text edits are not lost.
func (c *wsConc) replay() {
	ctx := context.Background()
	revs, ops, err := wsRevLog(ctx, c.pg, c.tenant, c.doc)
	if err != nil {
		c.t.Fatal(err)
	}
	m := newWsModel("")
	for i, op := range ops {
		if revs[i] != int64(i+1) {
			c.t.Fatalf("rev log hole at %d (rev %d)", i+1, revs[i])
		}
		if item, ok := c.commits[revs[i]]; ok && op["item"] != item {
			c.t.Fatalf("rev %d: log item %v, writer committed %s", revs[i], op["item"], item)
		}
		m.apply(op)
	}
	for rev := range c.commits {
		if rev > int64(len(revs)) {
			c.t.Fatalf("committed rev %d is not in the log (%d entries): a lost op", rev, len(revs))
		}
	}
	got, err := c.pg.DocSubtree(ctx, c.tenant, c.doc, "")
	if err != nil {
		c.t.Fatal(err)
	}
	if msg := sameAsModel(got, m); msg != "" {
		c.t.Fatalf("WSDOC replay: SPOOL_TEST_WSDOC_SEED=%d: the log replayed != the final tree: %s", c.seed, msg)
	}
	for _, it := range got {
		if e, ok := c.edits[it.ID]; ok && (it.Rev != e.rev || it.Title != e.title) {
			c.t.Fatalf("item %s: DB rev %d %q, last committed edit rev %d %q", it.ID, it.Rev, it.Title, e.rev, e.title)
		}
	}
	c.t.Logf("WSDOC concurrent replay: %d log entries, %d items, model = DB", len(revs), len(got))
}
