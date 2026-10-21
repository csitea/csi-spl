package store

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
	"github.com/jackc/pgx/v5"
)

// dropCategories removes test nodes from a Postgres store (the estate tree
// outlives the test); a no-op on Memory.
func dropCategories(t *testing.T, st Store, paths ...string) {
	t.Cleanup(func() {
		if pg, ok := st.(*Postgres); ok {
			pg.asOperator(context.Background(), func(tx pgx.Tx) error { //nolint:errcheck
				_, err := tx.Exec(context.Background(), `DELETE FROM activity_categories WHERE category_path = ANY($1)`, paths)
				return err
			})
		}
	})
}

// spec 143 T040: the seeded tree (rdb 0204, owner poll 2 answer A: 5 areas
// with their sub-categories) reads back; an operator adds a child under a
// seeded node, reads it back linked to its parent, changes it and turns it
// off. RED CONTROLS: a child whose parent is not there, a taken path, a bad
// path and a change of a node that does not exist are refused.
func TestCategoriesStoreCRUD(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cs, ok := st.(CategoryStore)
			if !ok {
				t.Fatalf("%s keeps no categories", name)
			}
			all, err := cs.ListCategories(ctx)
			if err != nil {
				t.Fatal(err)
			}
			seed := map[string]Category{}
			for _, c := range all {
				seed[c.Path] = c
			}
			for _, want := range CategorySeed {
				got, ok := seed[want.Path]
				if !ok || got.ParentPath != want.ParentPath || got.Title != want.Title || !got.IsActive || got.Dimensions["kind"] != want.Dimensions["kind"] {
					t.Errorf("seed %s: %+v (present %v)", want.Path, got, ok)
				}
			}
			roots := 0
			for _, c := range all {
				if c.ParentPath == "" && seed[c.Path].Title != "" {
					roots++
				}
			}
			if roots < 5 {
				t.Errorf("roots %d, want the 5 seeded areas", roots)
			}
			leaf := "coding/hard/go_" + strings.ToLower(uid(""))
			dropCategories(t, st, leaf)
			c, err := cs.CreateCategory(ctx, Category{Path: leaf, ParentPath: "coding/hard", Title: "Go", Dimensions: map[string]any{"kind": "complex_coding"}, IsActive: true})
			if err != nil || c.Path != leaf || c.ParentPath != "coding/hard" || c.CreatedAt.IsZero() {
				t.Fatalf("create child: %+v %v", c, err)
			}
			all, _ = cs.ListCategories(ctx)
			var back Category
			for _, x := range all {
				if x.Path == leaf {
					back = x
				}
			}
			if back.ParentPath != "coding/hard" || back.Dimensions["kind"] != "complex_coding" || CategoryDepth(back.Path) != 3 {
				t.Fatalf("read back: %+v", back)
			}
			back.Title, back.IsActive = "Go services", false
			if up, err := cs.UpdateCategory(ctx, back); err != nil || up.Title != "Go services" || up.IsActive || !up.CreatedAt.Equal(c.CreatedAt) {
				t.Fatalf("update: %+v %v", up, err)
			}
			orphan := "nosuch_" + strings.ToLower(uid("")) + "/child"
			if _, err := cs.CreateCategory(ctx, Category{Path: orphan, ParentPath: CategoryParent(orphan), Title: "x", IsActive: true}); !errors.Is(err, ErrUnknownCategory) {
				t.Errorf("RED CONTROL child of a missing parent: %v, want ErrUnknownCategory", err)
			}
			if _, err := cs.CreateCategory(ctx, Category{Path: "coding/hard", ParentPath: "coding", Title: "again", IsActive: true}); !errors.Is(err, ErrConflict) {
				t.Errorf("RED CONTROL a taken path: %v, want ErrConflict", err)
			}
			for _, bad := range []Category{{Path: "Coding/Hard", ParentPath: "Coding", Title: "x"}, {Path: "coding//x", ParentPath: "coding/", Title: "x"},
				{Path: "coding/x", ParentPath: "", Title: "x"}, {Path: Uncategorised, Title: "x"}} {
				if _, err := cs.CreateCategory(ctx, bad); err == nil {
					t.Errorf("RED CONTROL bad node %+v stored", bad)
				}
			}
			if _, err := cs.UpdateCategory(ctx, Category{Path: orphan, ParentPath: CategoryParent(orphan), Title: "x"}); !errors.Is(err, ErrNotFound) {
				t.Errorf("RED CONTROL update of a missing node: %v, want ErrNotFound", err)
			}
		})
	}
}

// spec 143 T040 red control, Postgres: the tree's own parent FK cascades
// (rdb 0204 ON DELETE CASCADE), so deleting a parent whose child a spawn
// request names fails the fleet_asks foreign key: a category in use is never
// removed under its requests. CONTROL: the same parent with an unused child
// deletes, the child with it.
func TestCategoryDeleteInUseRefused(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	root := "t_" + strings.ToLower(uid(""))
	child := root + "/used"
	dropCategories(t, pg, child, root)
	for _, c := range []Category{{Path: root, Title: "root", IsActive: true}, {Path: child, ParentPath: root, Title: "used", IsActive: true}} {
		if _, err := pg.CreateCategory(ctx, c); err != nil {
			t.Fatal(err)
		}
	}
	const ask = "c7c7c7c7-0000-4000-8000-000000000001"
	if _, _, err := pg.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: ask, Role: "orch", Kind: "task", From: "c-002@box-desk"}, "box-desk", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetAskCategory(ctx, tid, "main", ask, "complex_coding", child); err != nil {
		t.Fatal(err)
	}
	del := func() error {
		return pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `DELETE FROM activity_categories WHERE category_path = $1`, root)
			return err
		})
	}
	if err := del(); sqlState(err) != "23503" {
		t.Fatalf("RED CONTROL delete of a parent whose child a request names: %v, want a foreign key violation", err)
	}
	if err := pg.SetAskCategory(ctx, tid, "main", ask, "complex_coding", ""); err != nil {
		t.Fatal(err)
	}
	if err := del(); err != nil {
		t.Fatalf("CONTROL delete of the unused parent: %v", err)
	}
	if all, _ := pg.ListCategories(ctx); func() bool {
		for _, c := range all {
			if c.Path == child {
				return true
			}
		}
		return false
	}() {
		t.Fatal("CONTROL the child outlived its deleted parent")
	}
}

// spec 143 T042, the store half: a spawn request records the work kind and
// category of its brief, and reads them back. RED CONTROLS: a category path
// that names no node fails the foreign key (ErrUnknownCategory), a bad work
// kind is refused, an unknown ask and another workspace's ask are not found.
func TestSetAskCategory(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cs := st.(CategoryStore)
			tid, other := newTenant(t, st), newTenant(t, st)
			const ask = "c8c8c8c8-0000-4000-8000-000000000001"
			if _, _, err := st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: ask, Role: "orch", Kind: "task", From: "c-002@box-desk"}, "box-desk", time.Now()); err != nil {
				t.Fatal(err)
			}
			if err := cs.SetAskCategory(ctx, tid, "main", ask, "complex_coding", "coding/hard"); err != nil {
				t.Fatalf("set: %v", err)
			}
			if kind, path := askCategoryOf(t, st, tid, ask); kind != "complex_coding" || path != "coding/hard" {
				t.Fatalf("read back %q %q", kind, path)
			}
			if err := cs.SetAskCategory(ctx, tid, "main", ask, "complex_coding", "coding/no_such_node"); !errors.Is(err, ErrUnknownCategory) {
				t.Errorf("RED CONTROL a path naming no node: %v, want ErrUnknownCategory (the FK)", err)
			}
			if kind, path := askCategoryOf(t, st, tid, ask); kind != "complex_coding" || path != "coding/hard" {
				t.Errorf("a refused path changed the row: %q %q", kind, path)
			}
			if err := cs.SetAskCategory(ctx, tid, "main", ask, "astrology", ""); err == nil {
				t.Error("RED CONTROL a bad work kind was stored")
			}
			if err := cs.SetAskCategory(ctx, other, "main", ask, "tests", "tests"); !errors.Is(err, ErrNotFound) {
				t.Errorf("RED CONTROL another workspace's ask: %v, want ErrNotFound", err)
			}
			if err := cs.SetAskCategory(ctx, tid, "main", "c8c8c8c8-0000-4000-8000-0000000000ff", "tests", ""); !errors.Is(err, ErrNotFound) {
				t.Errorf("RED CONTROL an unknown ask: %v, want ErrNotFound", err)
			}
			if err := cs.SetAskCategory(ctx, tid, "main", ask, "", ""); err != nil {
				t.Fatal(err)
			}
			if kind, path := askCategoryOf(t, st, tid, ask); kind != "" || path != "" {
				t.Errorf("cleared: %q %q", kind, path)
			}
		})
	}
}

// askCategoryOf reads a request's work kind and category from either driver.
func askCategoryOf(t *testing.T, st Store, tid, ask string) (string, string) {
	t.Helper()
	switch s := st.(type) {
	case *Memory:
		kind, path, _ := s.AskCategory(tid, "main", ask)
		return kind, path
	case *Postgres:
		var kind, path string
		if err := s.inTenant(context.Background(), tid, func(tx pgx.Tx) error {
			return tx.QueryRow(context.Background(), `SELECT work_kind, coalesce(category_path, '') FROM fleet_asks
				WHERE tenant_id = $1 AND fleet = 'main' AND ask_id = $2`, tid, ask).Scan(&kind, &path)
		}); err != nil {
			t.Fatal(err)
		}
		return kind, path
	}
	t.Fatalf("driver %T", st)
	return "", ""
}

// spec 143 T043 gate: child categories' tokens roll up into their parent's
// sum, at every depth asked. RED CONTROL: minutes with no category, and
// minutes of a category no node names any more, are 'uncategorised' and
// never dropped: the roots plus 'uncategorised' are the total.
func TestTokensByCategoryRollup(t *testing.T) {
	from, to := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC)
	leaves := []CategoryLaneTokens{
		{Path: "coding/hard", Tokens: 1000, CacheRead: 50, CostUSD: 1.5},
		{Path: "coding/simple", Tokens: 200, CostUSD: 0.25},
		{Path: "coding", Tokens: 30},
		{Path: "review/r7", Tokens: 400, CostUSD: 1},
		{Path: "", Tokens: 7000, CacheRead: 9, CostUSD: 3},
		{Path: "coding/removed_node", Tokens: 11},
	}
	byPath := func(r CategoryTokensResponse) map[string]CategoryNode {
		m := map[string]CategoryNode{}
		for _, n := range r.Categories {
			m[n.Path] = n
		}
		return m
	}
	all := CategoryRollup(CategorySeed, leaves, from, to, 0)
	got := byPath(all)
	if c := got["coding"]; c.Tokens != 1230 || c.CacheRead != 50 || c.CostUSD != 1.75 || c.Depth != 1 {
		t.Errorf("coding = hard + simple + its own: %+v, want 1230 tokens, 1.75 USD", c)
	}
	if c := got["coding/hard"]; c.Tokens != 1000 || c.Depth != 2 {
		t.Errorf("coding/hard: %+v", c)
	}
	if c := got["review"]; c.Tokens != 400 || got["review/r7"].Tokens != 400 || got["review/gate"].Tokens != 0 {
		t.Errorf("review: %+v %+v %+v", c, got["review/r7"], got["review/gate"])
	}
	if len(all.Categories) != len(CategorySeed) {
		t.Errorf("depth leaf: %d nodes, want every node (%d)", len(all.Categories), len(CategorySeed))
	}
	d1 := CategoryRollup(CategorySeed, leaves, from, to, 1)
	if len(d1.Categories) != 5 || byPath(d1)["coding"].Tokens != 1230 {
		t.Errorf("depth 1: %+v", d1.Categories)
	}
	if d2 := CategoryRollup(CategorySeed, leaves, from, to, 2); len(d2.Categories) != len(CategorySeed) || byPath(d2)["coding/simple"].Tokens != 200 {
		t.Errorf("depth 2: %d nodes", len(d2.Categories))
	}
	if u := all.Uncategorised; u.Path != Uncategorised || u.Tokens != 7011 || u.CacheRead != 9 || u.CostUSD != 3 {
		t.Errorf("RED CONTROL uncategorised %+v, want 7011 tokens (no category + a removed node), never dropped", u)
	}
	var roots int64
	for _, n := range d1.Categories {
		roots += n.Tokens
	}
	if total := roots + d1.Uncategorised.Tokens; total != d1.Tokens || d1.Tokens != 8641 || d1.CostUSD != 5.75 {
		t.Errorf("RED CONTROL roots %d + uncategorised %d = %d, total %d (want 8641): a minute was dropped or counted twice", roots, d1.Uncategorised.Tokens, total, d1.Tokens)
	}
}

// spec 143 T043, the join both drivers run: a placed request ("placed:
// c-1@<box>") claims its lane's minutes from 5 min before the placement
// until the next placement of the same id; the id's next lane is the next
// request's; another box's c-1, the minutes before the first placement and
// an unmetered minute are not claimed; another workspace's request claims
// nothing. RED CONTROL: the unclaimed minutes come back under "", not lost.
func TestCategoryTokensJoin(t *testing.T) {
	ctx := context.Background()
	n, _ := strconv.ParseUint(uid("")[:4], 16, 32)
	t0 := time.Date(2005, 1, 1, 6, 0, 0, 0, time.UTC).AddDate(0, 0, int(n%5000))
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cs, ft := st.(CategoryStore), st.(FleetTokenStore)
			op, other := newTenant(t, st), newTenant(t, st)
			box, box2 := strings.ToLower(uid("j")), strings.ToLower(uid("k"))
			place := func(tid, ask, path string, at time.Time, reason string) {
				t.Helper()
				if _, _, err := st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: ask, Role: "orch", Kind: "task", From: "c-002@box-desk"}, "box-desk", at.Add(-time.Minute)); err != nil {
					t.Fatal(err)
				}
				if path != "" {
					if err := cs.SetAskCategory(ctx, tid, "main", ask, "", path); err != nil {
						t.Fatal(err)
					}
				}
				if _, err := st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: ask, Op: AskDone, By: "c-001@box-desk", Reason: reason}, "box-desk", at); err != nil {
					t.Fatal(err)
				}
			}
			place(op, "c9c9c9c9-0000-4000-8000-000000000001", "coding/hard", t0, "placed: c-1@"+box)
			place(op, "c9c9c9c9-0000-4000-8000-000000000002", "review/r7", t0.Add(2*time.Hour), "placed: c-1@"+box)
			place(other, "c9c9c9c9-0000-4000-8000-000000000003", "tests", t0.Add(-time.Hour), "placed: c-1@"+box)
			min := func(d time.Duration) time.Time { return t0.Add(d) }
			samples := map[string][]wire.FleetTokenSample{
				box: {
					fleetSample("c-1", "claude", "", min(-30*time.Minute), 1, 0, 0, 0), // before the first placement: ""
					fleetSample("c-1", "claude", "", min(-4*time.Minute), 10, 0, 0, 0), // the lead: coding/hard
					fleetSample("c-1", "claude", "", min(time.Hour), 100, 20, 7, 3),    // coding/hard
					fleetSample("c-1", "claude", "", min(2*time.Hour), 1000, 0, 0, 0),  // the next lane: review/r7
					fleetSample("c-2", "claude", "", min(time.Hour), 5000, 0, 0, 0),    // never placed: ""
					{AgentID: "c-1", Vendor: "agy", Minute: min(90 * time.Minute)},     // unmetered: not counted
				},
				box2: {fleetSample("c-1", "claude", "", min(time.Hour), 70000, 0, 0, 0)}, // another box's c-1: ""
			}
			for b, ss := range samples {
				if _, err := ft.RecordSamples(ctx, b, ss); err != nil {
					t.Fatal(err)
				}
			}
			leaves, err := cs.CategoryTokens(ctx, op, min(-time.Hour), min(3*time.Hour))
			if err != nil {
				t.Fatal(err)
			}
			got := map[string]CategoryLaneTokens{}
			for _, l := range leaves {
				got[l.Path] = l
			}
			if h := got["coding/hard"]; h.Tokens != 133 || h.CacheRead != 7 {
				t.Errorf("coding/hard %+v, want 10 + 123 tokens, 7 cache reads", h)
			}
			if r := got["review/r7"]; r.Tokens != 1000 {
				t.Errorf("review/r7 %+v, want 1000 (the id's next lane)", r)
			}
			if _, ok := got["tests"]; ok {
				t.Errorf("another workspace's request claimed minutes: %+v", got["tests"])
			}
			if u := got[""]; u.Tokens != 75001 {
				t.Errorf("RED CONTROL unclaimed %+v, want 1 + 5000 + 70000 under \"\", never dropped", u)
			}
		})
	}
}

// The rollup's window: 7 days by default, at most 30, from before to.
func TestCategoryTokensWindow(t *testing.T) {
	now := time.Date(2026, 10, 22, 10, 30, 45, 0, time.UTC)
	if f, to, why := CategoryTokensWindow("", "", now); why != "" || !to.Equal(now.Truncate(time.Minute)) || to.Sub(f) != 7*24*time.Hour {
		t.Errorf("default: %v %v %q", f, to, why)
	}
	if f, to, why := CategoryTokensWindow("2026-10-01", "2026-10-02T00:00:00Z", now); why != "" || f.Day() != 1 || to.Day() != 2 {
		t.Errorf("given: %v %v %q", f, to, why)
	}
	for _, bad := range [][2]string{{"2026-08-01", "2026-10-01"}, {"2026-10-02", "2026-10-01"}, {"yesterday", ""}, {"", "soon"}} {
		if _, _, why := CategoryTokensWindow(bad[0], bad[1], now); why == "" {
			t.Errorf("%v accepted", bad)
		}
	}
}

func TestCheckAskCategory(t *testing.T) {
	for _, ok := range [][2]string{{"", ""}, {"complex_coding", "coding/hard"}, {"secret", ""}, {"", "a/b_c/d1"}} {
		if why := CheckAskCategory(ok[0], ok[1]); why != "" {
			t.Errorf("%v refused: %s", ok, why)
		}
	}
	for _, bad := range [][2]string{{"coding", ""}, {"", "Coding"}, {"", "a//b"}, {"", "/a"}, {"", "a b"}, {"", strings.Repeat("a", 201)}} {
		if why := CheckAskCategory(bad[0], bad[1]); why == "" {
			t.Errorf("%v accepted", bad)
		}
	}
}
