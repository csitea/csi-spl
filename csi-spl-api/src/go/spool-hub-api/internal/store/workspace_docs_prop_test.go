package store

import (
	"context"
	"errors"
	"fmt"
	"math/rand" // nosemgrep: go.lang.security.audit.crypto.math_random.math-random-used -- a seeded, replayable op sequence for a test (SPOOL_TEST_WSDOC_SEED), never a secret
	"sync"
	"testing"
)

// TestWorkspaceDocProperty (spec 113 3.5, T002 Done (a)): random sequences of
// add sibling / parent / child, move (also into its own subtree, refused),
// delete subtree, plus stale-rev, gone-item and cross-tenant probes, >= 5,000
// ops x 5 seeds. After EVERY step: the invariant check on the tables and the
// whole tree compared with the model. A failure prints its seed; replay it
// with SPOOL_TEST_WSDOC_SEED=<seed> (SPOOL_TEST_WSDOC_OPS sets the length).
func TestWorkspaceDocProperty(t *testing.T) {
	pg, tid := wsDocPG(t)
	other := newTenant(t, pg)
	ops, seeds := wsEnvInt("SPOOL_TEST_WSDOC_OPS", 5000), wsSeeds([]int64{1, 2, 3, 4, 5})
	var mu sync.Mutex
	var counts [4]int
	t.Run("seeds", func(t *testing.T) {
		for _, seed := range seeds {
			t.Run(fmt.Sprint(seed), func(t *testing.T) {
				t.Parallel() // one doc per seed: independent, and the run is DB-latency bound
				p := &wsProp{t: t, pg: pg, tenant: tid, other: other, seed: seed, rng: rand.New(rand.NewSource(seed))}
				p.start()
				for p.step = 1; p.step <= ops; p.step++ {
					p.once()
				}
				t.Logf("seed %d: %d ops, %d items at the end, doc rev %d", seed, ops, len(p.m.parent), p.rev)
				mu.Lock()
				defer mu.Unlock()
				for i := range counts {
					counts[i] += p.counts[i]
				}
			})
		}
	})
	t.Logf("WSDOC property: committed=%d 412=%d 404=%d refused=%d (n = %d seeds x %d ops)",
		counts[0], counts[1], counts[2], counts[3], len(seeds), ops)
}

// wsProp is one seed's run: the doc, its model and the outcome counts
// (committed, 412, 404, refused).
type wsProp struct {
	t             *testing.T
	pg            *Postgres
	tenant, other string
	doc           string
	seed          int64
	step          int
	rng           *rand.Rand
	m             *wsModel
	rev           int64
	gone          []string
	counts        [4]int
}

func (p *wsProp) start() {
	doc, root, err := p.pg.DocCreate(context.Background(), p.tenant, "property", "prop")
	if err != nil {
		p.t.Fatalf("seed %d: create: %v", p.seed, err)
	}
	p.doc, p.m, p.rev = doc, newWsModel(root), 1
}

// pick is any item but the root; "" when there is none.
func (p *wsProp) pick() string {
	items := p.m.items()
	if len(items) == 0 {
		return ""
	}
	return items[p.rng.Intn(len(items))]
}

// anyItem is any item, the root included.
func (p *wsProp) anyItem() string {
	if it := p.pick(); it != "" && p.rng.Intn(8) != 0 {
		return it
	}
	return p.m.root
}

// once runs one random op, checks its outcome against the model's
// prediction, applies it to the model, then checks the DB.
func (p *wsProp) once() {
	k := p.rng.Intn(100)
	switch {
	case k < 30:
		p.add(DocChild)
	case k < 40:
		p.add(DocSibling)
	case k < 46:
		p.add(DocParent)
	case k < 70:
		p.move()
	case k < 80:
		p.del()
	default:
		p.probe(k)
	}
	if msg := wsCheck(context.Background(), p.pg, p.tenant, p.doc); msg != "" {
		p.fail("invariants: %s", msg)
	}
	got, err := p.pg.DocSubtree(context.Background(), p.tenant, p.doc, "")
	if err != nil {
		p.fail("read: %v", err)
	}
	if msg := sameAsModel(got, p.m); msg != "" {
		p.fail("model: %s", msg)
	}
}

func (p *wsProp) fail(format string, args ...any) {
	p.t.Helper()
	args = append([]any{p.seed, p.step}, args...)
	p.t.Fatalf("WSDOC replay: SPOOL_TEST_WSDOC_SEED=%d (step %d): "+format, args...)
}

// outcome checks err against want and counts it; true when committed.
func (p *wsProp) outcome(what string, res DocOpResult, err, want error) bool {
	p.t.Helper()
	if want == nil && err == nil {
		if res.Rev != p.rev+1 {
			p.fail("%s: rev %d after %d", what, res.Rev, p.rev)
		}
		p.rev = res.Rev
		p.counts[0]++
		return true
	}
	if want == nil || !errors.Is(err, want) {
		p.fail("%s: got %v, want %v", what, err, want)
	}
	switch want {
	case ErrDocStale:
		p.counts[1]++
	case ErrDocRefused:
		p.counts[3]++
	default:
		p.counts[2]++
	}
	return false
}

func (p *wsProp) add(where DocWhere) {
	anchor, ord := p.anyItem(), p.rng.Intn(6)
	var want error
	if where != DocChild && anchor == p.m.root {
		want = ErrDocRefused
	}
	res, err := p.pg.DocItemAdd(context.Background(), p.tenant, DocItemAddReq{DocID: p.doc, Rev: p.rev,
		Anchor: anchor, Where: where, Ord: ord, Title: "t", Actor: "prop"})
	if !p.outcome("add "+string(where), res, err, want) {
		return
	}
	switch where {
	case DocChild:
		p.m.insert(anchor, res.ItemID, ord)
	case DocSibling:
		parent := p.m.parent[anchor]
		_, at := p.m.detach(anchor)
		p.m.insert(parent, anchor, at)
		p.m.insert(parent, res.ItemID, at+1)
	case DocParent:
		parent, at := p.m.detach(anchor)
		p.m.insert(parent, res.ItemID, at)
		p.m.insert(res.ItemID, anchor, 1)
	}
}

func (p *wsProp) move() {
	item, target, ord := p.pick(), p.anyItem(), p.rng.Intn(6)
	if item == "" {
		return
	}
	var want error
	if p.m.under(target, item) {
		want = ErrDocRefused
	}
	res, err := p.pg.DocItemMove(context.Background(), p.tenant, DocItemMoveReq{DocID: p.doc, Rev: p.rev,
		ItemID: item, Parent: target, Ord: ord, Actor: "prop"})
	if p.outcome("move", res, err, want) {
		p.m.detach(item)
		p.m.insert(target, item, ord)
	}
}

func (p *wsProp) del() {
	item := p.pick()
	if item == "" || p.rng.Intn(3) == 0 && len(p.m.parent) < 20 {
		return
	}
	res, err := p.pg.DocItemDeleteSubtree(context.Background(), p.tenant, p.doc, p.rev, item, "prop")
	if p.outcome("delete", res, err, nil) {
		p.gone = append(p.gone, item)
		p.m.drop(item)
	}
}

// probe is an op that must not commit: the root delete, a move into its own
// subtree, a stale rev, a gone item, another tenant on this doc.
func (p *wsProp) probe(k int) {
	ctx := context.Background()
	var res DocOpResult
	var err, want error
	switch item := p.pick(); {
	case k < 84:
		res, err = p.pg.DocItemDeleteSubtree(ctx, p.tenant, p.doc, p.rev, p.m.root, "prop")
		want = ErrDocRefused
	case k < 88 && item != "":
		res, err = p.pg.DocItemMove(ctx, p.tenant, DocItemMoveReq{DocID: p.doc, Rev: p.rev, ItemID: item, Parent: item, Actor: "prop"})
		want = ErrDocRefused
	case k < 92:
		res, err = p.pg.DocItemAdd(ctx, p.tenant, DocItemAddReq{DocID: p.doc, Rev: p.rev + 1, Anchor: p.m.root, Where: DocChild, Actor: "prop"})
		want = ErrDocStale
	case k < 96 && len(p.gone) > 0:
		g := p.gone[p.rng.Intn(len(p.gone))]
		res, err = p.pg.DocItemMove(ctx, p.tenant, DocItemMoveReq{DocID: p.doc, Rev: p.rev, ItemID: g, Parent: p.m.root, Actor: "prop"})
		want = ErrDocItemNotFound
	default:
		res, err = p.pg.DocItemAdd(ctx, p.other, DocItemAddReq{DocID: p.doc, Anchor: p.m.root, Where: DocChild, Actor: "prop"})
		want = ErrDocNotFound
	}
	p.outcome("probe", res, err, want)
}
