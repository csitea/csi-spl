package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"testing"

	"github.com/jackc/pgx/v5"
)

// spec 113 T002: the workspace-doc store on testkit Postgres (never the
// memory store). This file: the shared fixture, the model tree, the invariant
// check and the outcome test. The property, concurrent and timing tests are in
// workspace_docs_{prop,conc,timing}_test.go.
//
// Controls (T002 Done): SPOOL_TEST_WSDOC_PLANT=gap|prelock|lockrows plants
// one bug in the store; the run must then go red, printing its replay seed.
//   gap       a delete that skips closing the sibling gap  (property test)
//   prelock   a move that reads positions before the lock  (concurrent test)
//   lockrows  a store that ignores the lock's row count    (outcome + property)

// wsDocPG is the Postgres store plus a fresh tenant, with the plant (if any).
func wsDocPG(t *testing.T) (*Postgres, string) {
	t.Helper()
	pg := pgOnly(t)
	plant := os.Getenv("SPOOL_TEST_WSDOC_PLANT")
	switch plant {
	case "":
	case "gap":
		wsDocPlant.skipGapClose = true
	case "prelock":
		wsDocPlant.positionsBeforeLock = true
	case "lockrows":
		wsDocPlant.ignoreLockRows = true
	case "editlock":
		wsDocPlant.editNoDocLock = true
	default:
		t.Fatalf("SPOOL_TEST_WSDOC_PLANT=%q: want gap, prelock, lockrows or editlock", plant)
	}
	if plant != "" {
		t.Logf("CONTROL plant=%s is on: this run must go red", plant)
		t.Cleanup(func() { wsDocPlant = wsDocPlants{} })
	}
	return pg, newTenant(t, pg)
}

// wsSeed is SPOOL_TEST_WSDOC_SEED when set (replay one seed), else def.
func wsSeeds(def []int64) []int64 {
	if s := os.Getenv("SPOOL_TEST_WSDOC_SEED"); s != "" {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return []int64{n}
		}
	}
	return def
}

// wsEnvInt is an int knob of the tests (counts), def when unset.
func wsEnvInt(name string, def int) int {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil && n > 0 {
		return n
	}
	return def
}

// wsModel is the in-memory model tree the DB is compared with.
type wsModel struct {
	root   string
	parent map[string]string
	kids   map[string][]string
}

func newWsModel(root string) *wsModel {
	return &wsModel{root: root, parent: map[string]string{}, kids: map[string][]string{}}
}

// insert puts id under parent at ord (1-based, clamped to append).
func (m *wsModel) insert(parent, id string, ord int) {
	k := m.kids[parent]
	ord = clampOrd(ord, len(k)+1)
	k = append(k, "")
	copy(k[ord:], k[ord-1:])
	k[ord-1] = id
	m.kids[parent] = k
	m.parent[id] = parent
}

// detach takes id out of its parent's list and returns where it was.
func (m *wsModel) detach(id string) (string, int) {
	p := m.parent[id]
	k := m.kids[p]
	for i, c := range k {
		if c == id {
			m.kids[p] = append(k[:i:i], k[i+1:]...)
			delete(m.parent, id)
			return p, i + 1
		}
	}
	return p, 0
}

// drop deletes id's subtree.
func (m *wsModel) drop(id string) {
	m.detach(id)
	var walk func(string)
	walk = func(x string) {
		for _, c := range m.kids[x] {
			delete(m.parent, c)
			walk(c)
		}
		delete(m.kids, x)
	}
	walk(id)
}

// under: x is top or below it.
func (m *wsModel) under(x, top string) bool {
	for n := 0; x != "" && n <= len(m.parent)+1; n++ {
		if x == top {
			return true
		}
		x = m.parent[x]
	}
	return false
}

// items is every item but the root, in document order.
func (m *wsModel) items() []string {
	var out []string
	for _, r := range m.rows()[1:] {
		out = append(out, r.ID)
	}
	return out
}

// rows is the model in document order, as DocSubtree reports it.
func (m *wsModel) rows() []DocItem {
	out := []DocItem{{ID: m.root, Ord: 1}}
	var walk func(string, string)
	walk = func(x, prefix string) {
		for i, c := range m.kids[x] {
			o := prefix + strconv.Itoa(i+1)
			out = append(out, DocItem{ID: c, ParentID: x, Ord: i + 1, Outline: o})
			walk(c, o+".")
		}
	}
	walk(m.root, "")
	return out
}

// apply replays one rev-log entry (section 2.3) onto the model.
func (m *wsModel) apply(op map[string]any) {
	s := func(k string) string { v, _ := op[k].(string); return v }
	n := func(k string) int { v, _ := op[k].(float64); return int(v) }
	switch s("kind") {
	case "create":
		m.root = s("item")
	case "add":
		if s("where") == string(DocParent) {
			m.detach(s("anchor"))
			m.insert(s("to_parent"), s("item"), n("to_ord"))
			m.insert(s("item"), s("anchor"), 1)
			return
		}
		m.insert(s("to_parent"), s("item"), n("to_ord"))
	case "move":
		m.detach(s("item"))
		m.insert(s("to_parent"), s("item"), n("to_ord"))
	case "delete":
		m.drop(s("item"))
	}
}

// sameAsModel compares the DB tree, read whole, with the model ("" = equal).
func sameAsModel(got []DocItem, m *wsModel) string {
	want := m.rows()
	if len(got) != len(want) {
		return fmt.Sprintf("DB has %d items, model %d", len(got), len(want))
	}
	seen := map[string]bool{}
	for i, w := range want {
		g := got[i]
		if g.ID != w.ID || g.ParentID != w.ParentID || g.Ord != w.Ord || g.Outline != w.Outline {
			return fmt.Sprintf("row %d: DB %s<-%s ord %d %q, model %s<-%s ord %d %q",
				i, g.ID, g.ParentID, g.Ord, g.Outline, w.ID, w.ParentID, w.Ord, w.Outline)
		}
		if seen[g.Outline] {
			return "I6: outline " + g.Outline + " twice"
		}
		seen[g.Outline] = true
	}
	return ""
}

// wsCheckSQL is the I1..I4 check of one doc, straight from the tables.
const wsCheckSQL = `WITH RECURSIVE r AS (
		SELECT id, 0 AS n FROM workspace_doc_item WHERE doc_id = $1 AND parent_id IS NULL
		UNION ALL
		SELECT c.id, r.n + 1 FROM workspace_doc_item c JOIN r ON c.parent_id = r.id WHERE c.doc_id = $1 AND r.n < 100000)
	SELECT (SELECT count(*) FROM workspace_doc_item WHERE doc_id = $1 AND parent_id IS NULL),
		(SELECT count(*) FROM workspace_doc_item WHERE doc_id = $1),
		(SELECT count(*) FROM r),
		(SELECT count(*) FROM (SELECT parent_id FROM workspace_doc_item WHERE doc_id = $1 AND parent_id IS NOT NULL
			GROUP BY parent_id HAVING min(ord) <> 1 OR max(ord) <> count(*) OR count(DISTINCT ord) <> count(*)) g)`

// wsCheck runs the invariant check ("" = all hold).
func wsCheck(ctx context.Context, pg *Postgres, tenant, doc string) string {
	var roots, items, reach, gapped int
	if err := pg.queryRowTenant(ctx, tenant, wsCheckSQL, []any{doc}, &roots, &items, &reach, &gapped); err != nil {
		return "check: " + err.Error()
	}
	switch {
	case roots != 1:
		return fmt.Sprintf("I1: %d roots", roots)
	case reach != items:
		return fmt.Sprintf("I3: %d of %d items reachable", reach, items)
	case gapped != 0:
		return fmt.Sprintf("I4: %d parents with a gap or overlap", gapped)
	}
	return ""
}

// wsDocRev is the doc's current rev.
func wsDocRev(ctx context.Context, pg *Postgres, tenant, doc string) (int64, error) {
	var rev int64
	err := pg.queryRowTenant(ctx, tenant, `SELECT rev FROM workspace_doc WHERE id = $1`, []any{doc}, &rev)
	return rev, err
}

// wsRevLog is the doc's rev log in rev order.
func wsRevLog(ctx context.Context, pg *Postgres, tenant, doc string) ([]int64, []map[string]any, error) {
	var revs []int64
	var ops []map[string]any
	err := pg.queryTenant(ctx, tenant, `SELECT rev, op FROM workspace_doc_rev_log WHERE doc_id = $1 ORDER BY rev`,
		[]any{doc}, func(r pgx.Rows) error {
			var rev int64
			var op map[string]any
			if err := r.Scan(&rev, &op); err != nil {
				return err
			}
			revs, ops = append(revs, rev), append(ops, op)
			return nil
		})
	return revs, ops, err
}

// TestWorkspaceDocOutcomes: each op's four outcomes, the readers' outline,
// and a cross-tenant op that is a 404 from the lock, writing nothing.
func TestWorkspaceDocOutcomes(t *testing.T) {
	pg, tid := wsDocPG(t)
	ctx := context.Background()
	doc, root, err := pg.DocCreate(ctx, tid, "outcomes", "", "t")
	if err != nil {
		t.Fatal(err)
	}
	add := func(rev int64, anchor string, where DocWhere, ord int) (DocOpResult, error) {
		return pg.DocItemAdd(ctx, tid, DocItemAddReq{DocID: doc, Rev: rev, Anchor: anchor, Where: where, Ord: ord, Actor: "t"})
	}
	a, err := add(1, root, DocChild, 0)
	b, err2 := add(a.Rev, a.ItemID, DocSibling, 0)
	c, err3 := add(b.Rev, a.ItemID, DocChild, 0)
	p, err4 := add(c.Rev, b.ItemID, DocParent, 0)
	if err := errors.Join(err, err2, err3, err4); err != nil || p.Rev != 5 {
		t.Fatalf("adds: %v rev %d", err, p.Rev)
	}
	sub, err := pg.DocSubtree(ctx, tid, doc, "")
	if err != nil {
		t.Fatal(err)
	}
	var outline []string
	for _, it := range sub {
		outline = append(outline, it.Outline)
	}
	if got := fmt.Sprint(outline); got != "[ 1 1.1 2 2.1]" || sub[3].ID != p.ItemID || sub[4].ID != b.ItemID {
		t.Fatalf("outline %s", got)
	}
	kids, err := pg.DocChildren(ctx, tid, doc, p.ItemID)
	if err != nil || fmt.Sprint(kids.Path) != "[2]" || len(kids.Items) != 1 || kids.Items[0].Outline != "2.1" {
		t.Fatalf("children: %+v %v", kids, err)
	}
	wsOutcomeRefusals(t, pg, tid, doc, root, a.ItemID, c.ItemID)
	wsOutcomeText(t, pg, tid, doc, c.ItemID)
	wsOutcomeForeign(t, pg, doc, root)
}

func wsOutcomeRefusals(t *testing.T, pg *Postgres, tid, doc, root, a, c string) {
	ctx := context.Background()
	want := func(what string, err, want error) {
		t.Helper()
		if !errors.Is(err, want) {
			t.Fatalf("%s: %v, want %v", what, err, want)
		}
	}
	_, err := pg.DocItemDeleteSubtree(ctx, tid, doc, 0, root, "t")
	want("delete the root", err, ErrDocRefused)
	_, err = pg.DocItemMove(ctx, tid, DocItemMoveReq{DocID: doc, ItemID: a, Parent: c, Actor: "t"})
	want("move under its own child", err, ErrDocRefused)
	_, err = pg.DocItemMove(ctx, tid, DocItemMoveReq{DocID: doc, ItemID: a, Parent: a, Actor: "t"})
	want("move under itself", err, ErrDocRefused)
	_, err = pg.DocItemAdd(ctx, tid, DocItemAddReq{DocID: doc, Anchor: root, Where: DocSibling, Actor: "t"})
	want("a sibling of the root", err, ErrDocRefused)
	_, err = pg.DocItemDeleteSubtree(ctx, tid, doc, 1, a, "t")
	want("a stale doc rev", err, ErrDocStale)
	_, err = pg.DocItemDeleteSubtree(ctx, tid, doc, 0, uuid4(), "t")
	want("an unknown item", err, ErrDocItemNotFound)
	_, err = pg.DocItemDeleteSubtree(ctx, tid, uuid4(), 0, a, "t")
	want("an unknown doc", err, ErrDocNotFound)
	if msg := wsCheck(ctx, pg, tid, doc); msg != "" {
		t.Fatal(msg)
	}
}

func wsOutcomeText(t *testing.T, pg *Postgres, tid, doc, item string) {
	ctx := context.Background()
	r, err := pg.DocItemUpdateField(ctx, tid, doc, item, "title", "one", 1)
	if err != nil || r != 2 {
		t.Fatalf("title edit: rev %d %v", r, err)
	}
	if _, err := pg.DocItemUpdateField(ctx, tid, doc, item, "body", "x", 1); !errors.Is(err, ErrDocStale) {
		t.Fatalf("stale item rev: %v, want 412", err)
	}
	if _, err := pg.DocItemUpdateField(ctx, tid, doc, item, "attrs", `{"k":1}`, 2); err != nil {
		t.Fatalf("attrs edit: %v", err)
	}
	if _, err := pg.DocItemUpdateField(ctx, tid, doc, item, "ord", "1", 3); !errors.Is(err, ErrDocRefused) {
		t.Fatalf("ord is not on the allow-list: %v", err)
	}
	if _, err := pg.DocItemUpdateField(ctx, tid, doc, uuid4(), "title", "x", 1); !errors.Is(err, ErrDocItemNotFound) {
		t.Fatalf("gone item: %v, want 404", err)
	}
}

// wsOutcomeForeign: another tenant's structural ops on this doc are a 404
// from the lock (ErrDocNotFound, not an item 404 after going on unlocked).
func wsOutcomeForeign(t *testing.T, pg *Postgres, doc, root string) {
	ctx := context.Background()
	other := newTenant(t, pg)
	_, err := pg.DocItemAdd(ctx, other, DocItemAddReq{DocID: doc, Anchor: root, Where: DocChild, Actor: "x"})
	_, err2 := pg.DocItemDeleteSubtree(ctx, other, doc, 0, root, "x")
	if !errors.Is(err, ErrDocNotFound) || !errors.Is(err2, ErrDocNotFound) {
		t.Fatalf("cross-tenant ops: %v / %v, want the lock's 404 (ErrDocNotFound)", err, err2)
	}
	if items, err := pg.DocSubtree(ctx, other, doc, ""); !errors.Is(err, ErrDocNotFound) || len(items) != 0 {
		t.Fatalf("cross-tenant read: %d items %v", len(items), err)
	}
}
