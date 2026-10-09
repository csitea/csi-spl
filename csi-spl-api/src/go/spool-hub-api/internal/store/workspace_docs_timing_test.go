package store

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestWorkspaceDocTiming (spec 113 3.5, T002 Done (i)): the real ops (tenant,
// RLS, the doc lock, the deferred trigger) timed end to end on testkit
// Postgres at 11,111 items (fanout 10), 1 x 1,000 and 1 x 10,000 siblings,
// n = 5 each: add first / last child, move subtree, delete subtree, subtree
// read. It prints median and max per op with the box load (/proc/loadavg:
// load inflates these). The ceilings (50 ms at 11,111 items; 1 x 1,000
// pending the owner, t1 d85e7d3c; 1 x 10,000 never, spec 3.5) are enforced
// only in a dedicated measurement run, SPOOL_TEST_WSDOC_TIMING_GATE=1: in the
// shared suite (wf 10, go test -race, every package on one Postgres, a loaded
// runner) the numbers are printed, never gated. Run 37928804138 measured
// delete at 92.8 ms there against 13.6..24.1 ms on a quieter box.
func TestWorkspaceDocTiming(t *testing.T) {
	pg, tid := wsDocPG(t)
	n := wsEnvInt("SPOOL_TEST_WSDOC_TIMING_N", 5)
	enforce := os.Getenv("SPOOL_TEST_WSDOC_TIMING_GATE") == "1"
	if !enforce {
		t.Log("WSDOC timing: ceilings printed, not enforced (a shared run); SPOOL_TEST_WSDOC_TIMING_GATE=1 enforces them")
	}
	for _, c := range []struct {
		name  string
		build func(*testing.T, *Postgres, string) wsTimingDoc
		gate  time.Duration // 0 = printed only
	}{
		{"11111-fanout10", wsBuildFanout, 50 * time.Millisecond},
		{"1x1000", func(t *testing.T, pg *Postgres, tid string) wsTimingDoc { return wsBuildWide(t, pg, tid, 1000) }, 0},
		{"1x10000", func(t *testing.T, pg *Postgres, tid string) wsTimingDoc { return wsBuildWide(t, pg, tid, 10000) }, 0},
	} {
		d := c.build(t, pg, tid)
		t.Logf("WSDOC timing %s: box load %s", c.name, wsLoad())
		for _, op := range d.ops(pg, tid) {
			var took []time.Duration
			for i := 0; i < n; i++ {
				start := time.Now()
				if err := op.run(i); err != nil {
					t.Fatalf("%s %s #%d: %v", c.name, op.name, i, err)
				}
				took = append(took, time.Since(start))
			}
			sort.Slice(took, func(a, b int) bool { return took[a] < took[b] })
			med, max := took[len(took)/2], took[len(took)-1]
			t.Logf("WSDOC timing %-15s %-12s n=%d median=%6.2f ms max=%6.2f ms", c.name, op.name, n, wsMs(med), wsMs(max))
			if enforce && c.gate > 0 && med > c.gate {
				t.Errorf("%s %s: median %.2f ms > %.0f ms", c.name, op.name, wsMs(med), wsMs(c.gate))
			}
		}
		if msg := wsCheck(context.Background(), pg, tid, d.doc); msg != "" {
			t.Fatalf("%s: invariants after the timed ops: %s", c.name, msg)
		}
	}
}

// wsLoad is the 1/5/15-minute load average and the CPU count of the box.
func wsLoad() string {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return "unknown"
	}
	f := strings.Fields(string(b))
	if len(f) < 3 {
		return "unknown"
	}
	return fmt.Sprintf("%s %s %s on %d CPUs", f[0], f[1], f[2], runtime.NumCPU())
}

func wsMs(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

// wsTimingDoc is a seeded doc: the parents the ops work under and the
// subtrees they move or delete.
type wsTimingDoc struct {
	doc, root string
	parents   []string // add / move targets
	movers    []string // subtrees moved, one per rep
	victims   []string // subtrees deleted, one per rep
	read      string   // the subtree read
}

type wsTimedOp struct {
	name string
	run  func(i int) error
}

func (d wsTimingDoc) ops(pg *Postgres, tid string) []wsTimedOp {
	ctx := context.Background()
	add := func(ord int) func(int) error {
		return func(i int) error {
			_, err := pg.DocItemAdd(ctx, tid, DocItemAddReq{DocID: d.doc, Anchor: d.parents[i%len(d.parents)], Where: DocChild, Ord: ord, Actor: "timing"})
			return err
		}
	}
	return []wsTimedOp{
		{"add-first", add(1)},
		{"add-last", add(0)},
		{"move", func(i int) error {
			to := d.parents[(i+1)%len(d.parents)]
			_, err := pg.DocItemMove(ctx, tid, DocItemMoveReq{DocID: d.doc, ItemID: d.movers[i], Parent: to, Ord: 1, Actor: "timing"})
			return err
		}},
		{"delete", func(i int) error {
			_, err := pg.DocItemDeleteSubtree(ctx, tid, d.doc, 0, d.victims[i], "timing")
			return err
		}},
		{"read-subtree", func(int) error {
			items, err := pg.DocSubtree(ctx, tid, d.doc, d.read)
			if err == nil && len(items) < 2 {
				err = fmt.Errorf("subtree read %d items", len(items))
			}
			return err
		}},
	}
}

// wsBuildFanout seeds 1 + 10 + 100 + 1,000 + 10,000 = 11,111 items. Parents
// are level-1 items (10 children each); movers and victims level-2 subtrees
// (111 items each); the read is a level-1 subtree (1,111 items).
func wsBuildFanout(t *testing.T, pg *Postgres, tid string) wsTimingDoc {
	ctx := context.Background()
	doc, root, err := pg.DocCreate(ctx, tid, "timing fanout", "timing")
	if err != nil {
		t.Fatal(err)
	}
	wsExec(t, pg, tid, `UPDATE workspace_doc_item SET title = '0' WHERE doc_id = $1`, doc)
	for lvl := 1; lvl <= 4; lvl++ {
		wsExec(t, pg, tid, `INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title)
			SELECT tenant_id, doc_id, id, g, $2 FROM workspace_doc_item, generate_series(1, 10) g
			WHERE doc_id = $1 AND title = $3`, doc, fmt.Sprint(lvl), fmt.Sprint(lvl-1))
	}
	wsExec(t, pg, tid, `ANALYZE workspace_doc_item`)
	l1, l2 := wsLevel(t, pg, tid, doc, "1"), wsLevel(t, pg, tid, doc, "2")
	if len(l1) != 10 || len(l2) != 100 {
		t.Fatalf("fanout seed: %d / %d", len(l1), len(l2))
	}
	return wsTimingDoc{doc: doc, root: root, parents: l1, movers: l2[:10], victims: l2[50:60], read: l1[9]}
}

// wsBuildWide seeds one parent (the root) with n children.
func wsBuildWide(t *testing.T, pg *Postgres, tid string, n int) wsTimingDoc {
	ctx := context.Background()
	doc, root, err := pg.DocCreate(ctx, tid, fmt.Sprintf("timing 1x%d", n), "timing")
	if err != nil {
		t.Fatal(err)
	}
	wsExec(t, pg, tid, `INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title)
		SELECT tenant_id, doc_id, id, g, '1' FROM workspace_doc_item, generate_series(1, $2::int) g
		WHERE doc_id = $1 AND parent_id IS NULL`, doc, n)
	wsExec(t, pg, tid, `ANALYZE workspace_doc_item`)
	kids := wsLevel(t, pg, tid, doc, "1")
	// movers go from the back to the front (a full-width shift);
	// victims are near the front, so each delete closes a gap of ~n.
	return wsTimingDoc{doc: doc, root: root, parents: []string{root}, movers: kids[n-10:], victims: kids[10:20], read: ""}
}

func wsExec(t *testing.T, pg *Postgres, tid, sql string, args ...any) {
	t.Helper()
	if err := pg.inTenant(context.Background(), tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), sql, args...)
		return err
	}); err != nil {
		t.Fatal(err)
	}
}

// wsLevel is the ids of a doc's seeded level (the title the seed wrote), in order.
func wsLevel(t *testing.T, pg *Postgres, tid, doc, lvl string) []string {
	t.Helper()
	var ids []string
	err := pg.queryTenant(context.Background(), tid, `SELECT id::text FROM workspace_doc_item
		WHERE doc_id = $1 AND title = $2 ORDER BY parent_id, ord`, []any{doc, lvl}, func(r pgx.Rows) error {
		var id string
		ids = append(ids, id)
		return r.Scan(&ids[len(ids)-1])
	})
	if err != nil {
		t.Fatal(err)
	}
	return ids
}
