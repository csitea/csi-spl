package store

import (
	"context"
	"flag"
	"fmt"
	"math/rand/v2" // nosemgrep: go.lang.security.audit.crypto.math_random.math-random-used -- a seeded, replayable test draw (spec 099 7.2), never a secret
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 099 T003, section 7.5 (Q6): what the head triggers add to a write.
// SPOOL_TEST_PERF=1 only, and ALONE (-run '^TestTopicHeadCost$'): the off
// arm disables the four head triggers for the whole database, so any other
// test running beside it would see stale heads. Run it on a CPU-limited
// postgres:16-alpine (docker --cpus); the test cannot see the limit, so the
// report names it.
//
// Method: every cell runs n samples per arm, the arms interleaved (on, off,
// then off, on ...), and reports the "added" time = the on arm's percentile
// minus the off arm's. The seed is loaded by INSERT .. SELECT with the
// triggers off, then the backfill. Every tenant an off arm wrote is
// re-backfilled at the end and its diff must be empty.
//
// Gates (spec 7.5): one insert, added p95 < 5 ms; a claim-shape UPDATE (no
// head column), added p95 < 5 ms; a 5 000-row purge chunk over 1 000
// topics, longest head-lock hold (its COMMIT, where the drain holds every
// head it locked) <= 100 ms, else the purge needs its own smaller chunk; C1b
// (2 writers x 200 inserts into one topic), added p95 < 5 ms. The hot topic
// (5 000 lines, 200 parties) and the bulk 1 000-row INSERT .. SELECT are
// printed only.

const costGate = 5 * time.Millisecond

// headTriggerNames are rdb 0144's triggers on messages.
var headTriggerNames = []string{"topic_head_mark_ins", "topic_head_mark_upd", "topic_head_mark_del", "topic_head_apply"}

// setHeadTriggers enables or disables every head trigger, committed.
func setHeadTriggers(t *testing.T, pg *Postgres, on bool) {
	t.Helper()
	verb := "DISABLE"
	if on {
		verb = "ENABLE"
	}
	var parts []string
	for _, tg := range headTriggerNames {
		parts = append(parts, verb+" TRIGGER "+pgx.Identifier{tg}.Sanitize())
	}
	if _, err := pg.pool.Exec(context.Background(), `ALTER TABLE messages `+strings.Join(parts, ", ")); err != nil {
		t.Fatalf("%s the head triggers: %v", verb, err)
	}
}

// headPct is the p-th percentile (0..1) of ds, nearest rank.
func headPct(ds []time.Duration, p float64) time.Duration {
	if len(ds) == 0 {
		return 0
	}
	s := append([]time.Duration(nil), ds...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	k := int(p*float64(len(s)) + 0.5)
	if k < 1 {
		k = 1
	}
	if k > len(s) {
		k = len(s)
	}
	return s[k-1]
}

// costRow is one line of the report: the arms' p50 / p95 and what the
// triggers add; gate is "" when the cell is printed only.
type costRow struct {
	cell, n                   string
	on, off                   []time.Duration
	gate                      string
	pass                      bool
	note                      string
	addedP50, addedP95, onMax time.Duration
}

func newCostRow(cell string, on, off []time.Duration) costRow {
	r := costRow{cell: cell, n: fmt.Sprintf("%d / %d", len(on), len(off)), on: on, off: off}
	r.addedP50, r.addedP95, r.onMax = headPct(on, .5)-headPct(off, .5), headPct(on, .95)-headPct(off, .95), headPct(on, 1)
	return r
}

func (r costRow) line() string {
	verdict := ""
	if r.gate != "" {
		verdict = map[bool]string{true: "PASS ", false: "FAIL "}[r.pass] + r.gate
	}
	return fmt.Sprintf("| %s | %s | %s / %s | %s / %s | %s / %s | %s | %s |", r.cell, r.n, ms3(headPct(r.on, .5)), ms3(headPct(r.on, .95)),
		ms3(headPct(r.off, .5)), ms3(headPct(r.off, .95)), ms3(r.addedP50), ms3(r.addedP95), verdict, r.note)
}

func ms3(d time.Duration) string { return fmt.Sprintf("%.2f", float64(d.Microseconds())/1000) }

// interleave runs sample n times per arm, the arms alternating which goes
// first, with the triggers set for each arm; it returns the on and off
// durations.
func interleave(t *testing.T, pg *Postgres, n int, sample func(on bool) time.Duration) (on, off []time.Duration) {
	t.Helper()
	for i := 0; i < n; i++ {
		for _, arm := range [][]bool{{true, false}, {false, true}}[i%2] {
			setHeadTriggers(t, pg, arm)
			d := sample(arm)
			if arm {
				on = append(on, d)
			} else {
				off = append(off, d)
			}
		}
	}
	setHeadTriggers(t, pg, true)
	return on, off
}

// TestTopicHeadCost: see the file comment.
func TestTopicHeadCost(t *testing.T) {
	if os.Getenv("SPOOL_TEST_PERF") != "1" {
		t.Skip("SPOOL_TEST_PERF=1 runs the head write-cost cells")
	}
	if r := flag.Lookup("test.run"); r == nil || !strings.Contains(r.Value.String(), "TopicHeadCost") {
		t.Skip("TestTopicHeadCost toggles the head triggers for the whole database: run it alone, -run '^TestTopicHeadCost$'")
	}
	pg := pgOnly(t)
	t.Cleanup(func() { setHeadTriggers(t, pg, true) })
	n := envInt("TOPIC_HEAD_COST_N", 200)
	now := time.Now().UTC().Truncate(time.Microsecond)
	f := lightHeadFix(t, pg, now)
	setHeadTriggers(t, pg, false)
	seedTopics(t, pg, f.tn, 20000, 1500, now, 0.42)
	setHeadTriggers(t, pg, true)
	chunks := backfillTenant(f, true)
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("after the seed's backfill (%d chunks): %d heads differ", chunks, len(d))
	}
	stale := []*headFix{f}
	rows := []costRow{costInsert(t, f, n), costClaim(t, f, n)}
	purge, pf := costPurge(t, pg, now, envInt("TOPIC_HEAD_COST_PURGE_N", 5))
	c1b, cf := costContention(t, pg, now, envInt("TOPIC_HEAD_COST_C1B_N", 5))
	hot, hf := costHot(t, pg, now, envInt("TOPIC_HEAD_COST_HOT_N", 20))
	bulk := costBulk(t, f, envInt("TOPIC_HEAD_COST_BULK_N", 5))
	rows = append(rows, purge...)
	rows = append(rows, c1b, hot, bulk)
	stale = append(append(append(stale, pf...), cf...), hf)
	report := []string{"| cell | n on / off | on p50 / p95 ms | off p50 / p95 ms | added p50 / p95 ms | gate | note |", "|---|---|---|---|---|---|---|"}
	failed := false
	for _, r := range rows {
		report = append(report, r.line())
		failed = failed || (r.gate != "" && !r.pass)
	}
	t.Logf("seed: 20 000 lines over 1 500 topics, backfilled in %d chunks\n%s", chunks, strings.Join(report, "\n"))
	for _, s := range stale {
		rebackfill(s)
		if d := headDiff(s); len(d) != 0 {
			t.Fatalf("tenant %s after the re-backfill: %d heads differ", s.tn, len(d))
		}
	}
	if failed {
		t.Fatal("a spec 7.5 gate failed (see the table)")
	}
}

// rebackfill walks topic_head_backfill (rebuild_all) over every topic of
// f's tenant; backfillTenant stops at the tenant's mark, which an earlier
// backfill already set.
func rebackfill(f *headFix) {
	f.t.Helper()
	ctx := context.Background()
	cur := f.tn + "/00000000-0000-0000-0000-000000000000"
	for {
		var next *string
		f.must("re-backfill", f.pg.asOperator(ctx, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT topic_head_backfill(chunk => 100, rebuild_all => true, after => $1)`, cur).Scan(&next)
		}))
		if next == nil || !strings.HasPrefix(*next, f.tn+"/") {
			return
		}
		cur = *next
	}
}

// seededTasks is the tenant's topics, sorted.
func seededTasks(t *testing.T, f *headFix) []string {
	t.Helper()
	var out []string
	ctx := context.Background()
	f.must("tasks", f.pg.inTenant(ctx, f.tn, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT DISTINCT task_id::text FROM messages WHERE tenant_id = $1 ORDER BY 1`, []any{f.tn}, func(r pgx.Rows) error {
			var s string
			err := r.Scan(&s)
			out = append(out, s)
			return err
		})
	}))
	return out
}

// costInsert: one InsertMessage (its COMMIT runs the drain) into a seeded
// topic.
func costInsert(t *testing.T, f *headFix, n int) costRow {
	tasks, rng := seededTasks(t, f), rand.New(rand.NewPCG(uint64(99), 0))
	on, off := interleave(t, f.pg, n, func(bool) time.Duration {
		m := msgFor(f.tn, tasks[rng.IntN(len(tasks))], "box-b", f.t0, f.t0, "env-"+uuid4())
		m.Channel = "c1"
		t0 := time.Now()
		if _, err := f.pg.InsertMessage(context.Background(), m); err != nil {
			t.Fatalf("insert: %v", err)
		}
		return time.Since(t0)
	})
	r := newCostRow("one insert", on, off)
	r.gate, r.pass = "added p95 < 5 ms", r.addedP95 < costGate
	return r
}

// costClaim: the claim renew UPDATE (message_claim_postgres.go), which
// touches no head column, on a seeded line.
func costClaim(t *testing.T, f *headFix, n int) costRow {
	var ids []string
	ctx := context.Background()
	f.must("ids", f.pg.inTenant(ctx, f.tn, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT msg_id::text FROM messages WHERE tenant_id = $1 ORDER BY msg_id LIMIT 500`, []any{f.tn}, func(r pgx.Rows) error {
			var s string
			err := r.Scan(&s)
			ids = append(ids, s)
			return err
		})
	}))
	i := 0
	on, off := interleave(t, f.pg, n, func(bool) time.Duration {
		i++
		t0 := time.Now()
		if _, err := f.pg.execTenant(ctx, f.tn, `UPDATE messages SET locked_until = $3 WHERE tenant_id = $1 AND msg_id = $2`,
			f.tn, ids[i%len(ids)], f.t0.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatalf("claim: %v", err)
		}
		return time.Since(t0)
	})
	r := newCostRow("claim-shape UPDATE (no head column)", on, off)
	r.gate, r.pass = "added p95 < 5 ms", r.addedP95 < costGate
	return r
}

// costPurge: one 5 000-row purge chunk over 1 000 topics (C5's seed, a fresh
// tenant per sample): the whole chunk (DELETE + COMMIT) per arm, and the
// on arm's COMMIT alone - the drain, which holds every head lock it takes
// until the COMMIT ends.
func costPurge(t *testing.T, pg *Postgres, now time.Time, n int) ([]costRow, []*headFix) {
	ctx := context.Background()
	var commits []time.Duration
	var fixes []*headFix
	on, off := interleave(t, pg, n, func(arm bool) time.Duration {
		setHeadTriggers(t, pg, true)
		f := lightHeadFix(t, pg, now)
		purgeSeed(f, 1000, 5)
		setHeadTriggers(t, pg, arm)
		fixes = append(fixes, f)
		var stmt time.Duration
		t0 := time.Now()
		f.must("purge", pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, pgScopeOperator); err != nil {
				return err
			}
			tag, err := tx.Exec(ctx, headRandPurgeSQL, now, sweepChunk, f.tn)
			if err == nil && tag.RowsAffected() != 5000 {
				err = fmt.Errorf("purged %d rows, want 5000", tag.RowsAffected())
			}
			stmt = time.Since(t0)
			return err
		}))
		total := time.Since(t0)
		if arm {
			commits = append(commits, total-stmt)
		}
		return total
	})
	chunk := newCostRow("5 000-row purge chunk, 1 000 topics", on, off)
	hold := newCostRow("  its longest head-lock hold (the on arm's COMMIT)", commits, nil)
	hold.n = fmt.Sprint(len(commits))
	hold.addedP50, hold.addedP95 = 0, 0
	hold.gate, hold.pass = "max <= 100 ms", hold.onMax <= 100*time.Millisecond
	hold.note = "max " + ms3(hold.onMax) + " ms"
	if !hold.pass {
		hold.note += ": the purge needs its own smaller chunk"
	}
	return []costRow{chunk, hold}, fixes
}

// costContention is C1b: 2 writers x 200 inserts into one topic of a fresh
// tenant per round; every insert's latency, and each round's wall time.
func costContention(t *testing.T, pg *Postgres, now time.Time, rounds int) (costRow, []*headFix) {
	var fixes []*headFix
	var on, off []time.Duration
	var walls [2][]time.Duration
	for i := 0; i < rounds; i++ {
		for _, arm := range [][]bool{{true, false}, {false, true}}[i%2] {
			setHeadTriggers(t, pg, true)
			f := lightHeadFix(t, pg, now)
			f.line("a0", "A", time.Hour, lineOpt{card: true})
			lines := burst(f, "A", "c", 2, 200, lineOpt{})
			setHeadTriggers(t, pg, arm)
			t0 := time.Now()
			lat, err := insertAll(pg, lines)
			if err != nil {
				t.Fatalf("C1b: %v", err)
			}
			if arm {
				on, walls[0] = append(on, lat...), append(walls[0], time.Since(t0))
			} else {
				off, walls[1] = append(off, lat...), append(walls[1], time.Since(t0))
			}
			fixes = append(fixes, f)
		}
	}
	setHeadTriggers(t, pg, true)
	r := newCostRow("C1b: 2 x 200 inserts, one topic (per insert)", on, off)
	r.n = fmt.Sprintf("%d rounds, %d / %d inserts", rounds, len(on), len(off))
	r.gate, r.pass = "added p95 < 5 ms", r.addedP95 < costGate
	r.note = fmt.Sprintf("wall p50 on %s ms, off %s ms", ms3(headPct(walls[0], .5)), ms3(headPct(walls[1], .5)))
	return r, fixes
}

// costHot: one insert into a hot topic - 5 000 lines among 200 parties,
// 100 DM pairs and one channel.
func costHot(t *testing.T, pg *Postgres, now time.Time, n int) (costRow, *headFix) {
	ctx := context.Background()
	f := lightHeadFix(t, pg, now)
	f.task["H"] = uuid4()
	f.must("hot seed", pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id,
				kind, body, files, msg, env_sig, env, received_at, expires_at)
			SELECT $1, gen_random_uuid(), $2::uuid, CASE WHEN g % 2 = 0 THEN 'c1' END, at, 'box-a', 'P-' || (g % 200), 'box-b',
				'P-' || ((g + 1) % 200), 'task', 'b', '[]', '{"v":1}', 'sig', '\x00'::bytea, at, at + interval '30 days'
			FROM generate_series(1, 5000) g CROSS JOIN LATERAL (SELECT $3::timestamptz - g * interval '1 s' AS at) a`, f.tn, f.task["H"], now)
		return err
	}))
	on, off := interleave(t, pg, n, func(bool) time.Duration {
		m := msgFor(f.tn, f.task["H"], "box-b", now, now, "env-"+uuid4())
		m.Channel = ""
		m.FromID, m.ToID = "P-7", "P-8"
		t0 := time.Now()
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatalf("hot insert: %v", err)
		}
		return time.Since(t0)
	})
	return newCostRow("hot topic (5 000 lines, 200 parties): one insert", on, off), f
}

// costBulk: one 1 000-row INSERT .. SELECT over 100 new topics in the
// seeded tenant, as the operator.
func costBulk(t *testing.T, f *headFix, n int) costRow {
	ctx := context.Background()
	on, off := interleave(t, f.pg, n, func(bool) time.Duration {
		t0 := time.Now()
		f.must("bulk", f.pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id,
					kind, body, files, msg, env_sig, env, received_at, expires_at)
				SELECT $1, gen_random_uuid(), tk, 'c2', $2::timestamptz, 'box-a', 'AGT-1', 'box-b', 'HUM-1', 'task', 'b', '[]',
					'{"v":1}', 'sig', '\x00'::bytea, $2::timestamptz - g * interval '1 ms', $2::timestamptz + interval '30 days'
				FROM (SELECT gen_random_uuid() AS tk FROM generate_series(1, 100)) k CROSS JOIN generate_series(1, 10) g`, f.tn, f.t0)
			return err
		}))
		return time.Since(t0)
	})
	return newCostRow("bulk INSERT .. SELECT, 1 000 rows over 100 topics", on, off)
}
