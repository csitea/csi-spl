package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 099 T003, section 7.3: the races the mark-then-drain design must
// survive. C6, C7 and C8 landed with the triggers (topic_head_sql_test.go);
// this file holds C1, C2, C3, C4, C4b, C5 and C9. C1b (the same burst with
// and without the triggers) toggles the triggers for the whole database, so
// it runs only in TestTopicHeadCost (SPOOL_TEST_PERF=1, alone). Each test
// ends with topic_head_diff empty and every line accounted for.
// Postgres only (SPOOL_TEST_PG_DSN).

// pgCode is err's SQLSTATE, or "".
func pgCode(err error) string {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code
	}
	return ""
}

// lineCount is how many lines f's tenant stores in task ("" = all).
func lineCount(f *headFix, task string) int {
	f.t.Helper()
	var n int
	f.must("count", f.pg.queryRowTenant(context.Background(), f.tn,
		`SELECT count(*) FROM messages WHERE tenant_id = $1 AND ($2 = '' OR task_id::text = $2)`, []any{f.tn, task}, &n))
	return n
}

// burst builds n lines per writer into task (names <prefix><writer>-<i>),
// all made before any goroutine starts: lineMsg writes f's maps. Line i of
// every writer has the same received_at, so writers tie.
func burst(f *headFix, task, prefix string, writers, n int, o lineOpt) [][]Message {
	out := make([][]Message, writers)
	for w := range out {
		for i := 0; i < n; i++ {
			ago := time.Duration(n-i) * time.Millisecond
			out[w] = append(out[w], f.lineMsg(fmt.Sprintf("%s%d-%d", prefix, w, i), task, ago, o))
		}
	}
	return out
}

// insertAll inserts each writer's lines from its own goroutine, all started
// at once; it returns every insert's latency and the first error.
func insertAll(pg *Postgres, lines [][]Message) ([]time.Duration, error) {
	ctx := context.Background()
	var mu sync.Mutex
	var first error
	var lat []time.Duration
	var wg sync.WaitGroup
	start := make(chan struct{})
	for _, ms := range lines {
		wg.Add(1)
		go func(ms []Message) {
			defer wg.Done()
			<-start
			for _, m := range ms {
				t := time.Now()
				_, err := pg.InsertMessage(ctx, m)
				mu.Lock()
				lat = append(lat, time.Since(t))
				if err != nil && first == nil {
					first = err
				}
				mu.Unlock()
			}
		}(ms)
	}
	close(start)
	wg.Wait()
	return lat, first
}

// TestTopicHeadConcurrentInserts is C1: two writers insert 200 lines each
// into one topic at once (line i of both at one instant). The head is the
// greatest (received_at, msg_id) of all 401 lines and the diff is empty.
func TestTopicHeadConcurrentInserts(t *testing.T) {
	pg := pgOnly(t)
	f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	f.line("a0", "A", time.Hour, lineOpt{card: true})
	lines := burst(f, "A", "c1-", 2, 200, lineOpt{})
	if _, err := insertAll(pg, lines); err != nil {
		t.Fatalf("C1 insert: %v", err)
	}
	if n := lineCount(f, f.task["A"]); n != 401 {
		t.Fatalf("C1: %d lines in A, want 401", n)
	}
	last := lines[0][199]
	if lines[1][199].MsgID > last.MsgID {
		last = lines[1][199]
	}
	h := readHead(f, "A")
	if !h.lastAt.Equal(last.ReceivedAt) || h.lastMsg != last.MsgID || len(h.parts) != 1 || h.parts[0].lastMsg != last.MsgID {
		t.Fatalf("C1: A's head %+v, want last %s %s", h, last.ReceivedAt, last.MsgID)
	}
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("C1: %v", d)
	}
	t.Logf("C1: 2 x 200 inserts, head rev %d, part rev %d", h.rev, h.parts[0].rev)
}

// together2 runs a and b from two goroutines started at once.
func together2(a, b func() error) (error, error) {
	var wg sync.WaitGroup
	errs := make([]error, 2)
	start := make(chan struct{})
	for i, fn := range []func() error{a, b} {
		wg.Add(1)
		go func(i int, fn func() error) {
			defer wg.Done()
			<-start
			errs[i] = fn()
		}(i, fn)
	}
	close(start)
	wg.Wait()
	return errs[0], errs[1]
}

// TestTopicHeadRaceInsertVsMove is C2: 20 inserts into A while A's 20 older
// lines are moved to B one by one, 5 rounds. Every line is where its writer
// put it and the diff is empty.
func TestTopicHeadRaceInsertVsMove(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	for r := 0; r < 5; r++ {
		f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
		f.line("a0", "A", time.Hour, lineOpt{card: true})
		f.line("b0", "B", time.Hour, lineOpt{card: true, ch: "crew"})
		var olds []string
		for i := 0; i < 20; i++ {
			olds = append(olds, f.line(fmt.Sprintf("o%d", i), "A", time.Duration(50-i)*time.Minute, lineOpt{}))
		}
		news := burst(f, "A", "n", 1, 20, lineOpt{})
		e1, e2 := together2(func() error {
			_, err := insertAll(pg, news)
			return err
		}, func() error {
			for _, id := range olds {
				if _, err := pg.MoveMessage(ctx, f.tn, id, f.task["B"], ChannelLobby, "HUM-1", f.t0, time.Time{}); err != nil {
					return err
				}
			}
			return nil
		})
		if e1 != nil || e2 != nil {
			t.Fatalf("C2 round %d: insert %v, move %v", r, e1, e2)
		}
		if a, b := lineCount(f, f.task["A"]), lineCount(f, f.task["B"]); a != 21 || b != 21 {
			t.Fatalf("C2 round %d: A has %d lines, B %d, want 21 and 21", r, a, b)
		}
		if d := headDiff(f); len(d) != 0 {
			t.Fatalf("C2 round %d: %v", r, d)
		}
	}
}

// TestTopicHeadRaceInsertVsMerge is C3: inserts into A and B while A merges
// into B, 5 rounds. No line is lost and the diff is empty.
func TestTopicHeadRaceInsertVsMerge(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	for r := 0; r < 5; r++ {
		f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
		for _, k := range []string{"A", "B"} {
			f.line(k+"0", k, time.Hour, lineOpt{card: true})
			for i := 1; i <= 5; i++ {
				f.line(fmt.Sprintf("%s%d", k, i), k, time.Duration(50-i)*time.Minute, lineOpt{})
			}
		}
		lines := append(burst(f, "A", "na", 1, 10, lineOpt{}), burst(f, "B", "nb", 1, 10, lineOpt{})...)
		var res MergeResult
		e1, e2 := together2(func() error {
			_, err := insertAll(pg, lines)
			return err
		}, func() (err error) {
			res, err = pg.MergeTopic(ctx, f.tn, f.task["A"], f.task["A"], f.task["B"], ChannelLobby, "HUM-1", f.t0)
			return err
		})
		if e1 != nil || e2 != nil {
			t.Fatalf("C3 round %d: insert %v, merge %v", r, e1, e2)
		}
		if n := lineCount(f, ""); n != 32 {
			t.Fatalf("C3 round %d: %d lines, want 32", r, n)
		}
		if d := headDiff(f); len(d) != 0 {
			t.Fatalf("C3 round %d (merge moved %d lines): %v", r, len(res.MsgIDs), d)
		}
	}
}

// TestTopicHeadRaceCrossMerge is C4: MergeTopic A->B and B->A at once, 50
// rounds. Each call ends ok or with a store refusal (the second merge can
// find its card already moved); a 40P01 is counted and logged, and any is a
// failure: it is what spec 099 T004 (one retry on 40P01) waits for.
func TestTopicHeadRaceCrossMerge(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	outcome := map[string]int{}
	for r := 0; r < 50; r++ {
		f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
		for _, k := range []string{"A", "B"} {
			f.line(k+"0", k, time.Hour, lineOpt{card: true})
			for i := 1; i <= 3; i++ {
				f.line(fmt.Sprintf("%s%d", k, i), k, time.Duration(50-i)*time.Minute, lineOpt{})
			}
		}
		merge := func(src, dst string) func() error {
			return func() error {
				_, err := pg.MergeTopic(ctx, f.tn, f.task[src], f.task[src], f.task[dst], ChannelLobby, "HUM-1", f.t0)
				return err
			}
		}
		e1, e2 := together2(merge("A", "B"), merge("B", "A"))
		for _, err := range []error{e1, e2} {
			switch code := pgCode(err); {
			case err == nil:
				outcome["ok"]++
			case code == "40P01":
				outcome["40P01"]++
			case code != "":
				t.Fatalf("C4 round %d: %v", r, err)
			default:
				outcome["refused: "+err.Error()]++
			}
		}
		if n := lineCount(f, ""); n != 8 {
			t.Fatalf("C4 round %d: %d lines, want 8", r, n)
		}
		if d := headDiff(f); len(d) != 0 {
			t.Fatalf("C4 round %d: %v", r, d)
		}
	}
	t.Logf("C4: 100 merge calls over 50 rounds: %v", outcome)
	if outcome["40P01"] != 0 {
		t.Fatalf("C4: %d merge calls ended in 40P01 (a lock cycle): spec 099 T004 is needed", outcome["40P01"])
	}
}

// lockstep runs two scoped transactions statement by statement: every
// writer runs its statement i, then waits for the other, then both COMMIT
// at once. immediate makes the head drain run after each statement (the
// v0.1 shape) instead of at COMMIT. It returns each transaction's error.
func lockstep(pg *Postgres, tenant string, immediate bool, steps [2][]func(pgx.Tx) error) [2]error {
	ctx := context.Background()
	var errs [2]error
	var wg sync.WaitGroup
	bar := make([]sync.WaitGroup, len(steps[0])+1)
	for i := range bar {
		bar[i].Add(2)
	}
	for w := 0; w < 2; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			errs[w] = lockstepTx(ctx, pg, tenant, immediate, steps[w], bar)
		}(w)
	}
	wg.Wait()
	return errs
}

// lockstepTx is one side of lockstep; it always arrives at every barrier,
// so a failed side never strands the other.
func lockstepTx(ctx context.Context, pg *Postgres, tenant string, immediate bool, steps []func(pgx.Tx) error, bar []sync.WaitGroup) error {
	arrived := 0
	defer func() {
		for ; arrived < len(bar); arrived++ {
			bar[arrived].Done()
		}
	}()
	return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if immediate {
			if _, err := tx.Exec(ctx, `SET CONSTRAINTS topic_head_apply IMMEDIATE`); err != nil {
				return err
			}
		}
		for _, step := range steps {
			if err := step(tx); err != nil {
				return err
			}
			bar[arrived].Done()
			bar[arrived].Wait()
			arrived++
		}
		bar[arrived].Done()
		bar[arrived].Wait()
		arrived++
		return nil
	})
}

// cycleRound seeds A and B with two lines each and runs C4b's two
// transactions: one writes a head column of A's line then B's, the other
// B's then A's - different rows, the same two heads.
func cycleRound(t *testing.T, pg *Postgres, immediate bool) (*headFix, [2]error) {
	f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	for _, k := range []string{"A", "B"} {
		f.line(k+"0", k, time.Hour, lineOpt{card: true})
		f.line(k+"1", k, 30*time.Minute, lineOpt{})
	}
	// An IMMEDIATE apply fires before the same statement's mark (triggers
	// fire in name order: topic_head_apply < topic_head_mark_upd), so the
	// control adds a no-op UPDATE OF expires_at - it queues the apply and no
	// mark - to drain each touch inside its own step, as v0.1 did.
	touch := func(line string) func(pgx.Tx) error {
		return func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `UPDATE messages SET expires_at = expires_at + interval '1 second'
				WHERE tenant_id = $1 AND msg_id = $2`, f.tn, f.msg[line])
			if err == nil && immediate {
				_, err = tx.Exec(context.Background(), `UPDATE messages SET expires_at = expires_at
					WHERE tenant_id = $1 AND msg_id = $2`, f.tn, f.msg[line])
			}
			return err
		}
	}
	errs := lockstep(pg, f.tn, immediate, [2][]func(pgx.Tx) error{
		{touch("A0"), touch("B0")},
		{touch("B1"), touch("A1")},
	})
	return f, errs
}

// TestTopicHeadLockstepNoCycle is C4b: two transactions in lockstep that
// cycle on the head locks under v0.1 (a head locked per statement) end
// without 40P01, 20 rounds, because the drain is sorted and runs last, at
// COMMIT. CONTROL: with the drain made IMMEDIATE (v0.1's shape) the same
// round deadlocks.
func TestTopicHeadLockstepNoCycle(t *testing.T) {
	pg := pgOnly(t)
	for r := 0; r < 20; r++ {
		f, errs := cycleRound(t, pg, false)
		if errs[0] != nil || errs[1] != nil {
			t.Fatalf("C4b round %d: %v / %v (SQLSTATE %q %q)", r, errs[0], errs[1], pgCode(errs[0]), pgCode(errs[1]))
		}
		if d := headDiff(f); len(d) != 0 {
			t.Fatalf("C4b round %d: %v", r, d)
		}
	}
	_, errs := cycleRound(t, pg, true)
	if pgCode(errs[0]) != "40P01" && pgCode(errs[1]) != "40P01" {
		t.Fatalf("C4b CONTROL: the IMMEDIATE drain did not deadlock: %v / %v", errs[0], errs[1])
	}
	t.Logf("C4b: 20 lockstep rounds, 0 40P01; control (IMMEDIATE drain): %v / %v", errs[0], errs[1])
}

// purgeSeed bulk-loads `topics` topics into f's tenant as the operator, one
// INSERT .. SELECT through the triggers: each a live card an hour old and
// `expired` newer lines that expired a minute ago. It returns the task ids.
func purgeSeed(f *headFix, topics, expired int) []string {
	f.t.Helper()
	tasks := make([]string, topics)
	for i := range tasks {
		tasks[i] = uuid4()
	}
	ctx := context.Background()
	f.must("seed", f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, is_parent, channel, ts, from_box, from_id, to_box, to_id,
				kind, body, files, msg, env_sig, env, received_at, expires_at)
			SELECT $1, CASE WHEN l = 0 THEN tk ELSE gen_random_uuid() END, tk, (l = 0)::int, $2, at,
				'box-a', 'AGT-1', 'box-wui', 'HUM-1', 'task', 'b', '[]', '{"v":1}', 'sig', '\x00'::bytea, at,
				CASE WHEN l = 0 THEN $3::timestamptz + interval '30 days' ELSE $3::timestamptz - interval '1 minute' END
			FROM unnest($4::uuid[]) WITH ORDINALITY AS u (tk, k)
			CROSS JOIN generate_series(0, $5::int) l
			CROSS JOIN LATERAL (SELECT $3::timestamptz - interval '1 hour' + (k * 10 + l) * interval '1 ms' AS at) a`,
			f.tn, ChannelLobby, f.t0, tasks, expired)
		return err
	}))
	return tasks
}

// TestTopicHeadPurgeChunkVsInserts is C5: one 5 000-row purge chunk (the
// sweep's DELETE, tenant-scoped) over 1 000 topics commits while 100 lines
// are inserted into those topics. Every line written stays, every expired
// one goes, and the diff is empty; the purge's COMMIT (the drain: every head
// lock it takes is held until it ends) is the longest head-lock hold.
func TestTopicHeadPurgeChunkVsInserts(t *testing.T) {
	pg := pgOnly(t)
	f := lightHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	tasks := purgeSeed(f, 1000, 5)
	news := make([][]Message, 2)
	for i := 0; i < 100; i++ {
		m := msgFor(f.tn, tasks[i*10], "box-wui", f.t0, f.t0, "env-"+uuid4())
		m.Channel = ChannelLobby
		news[i%2] = append(news[i%2], m)
	}
	ctx := context.Background()
	var stmt, commit time.Duration
	var purged int64
	e1, e2 := together2(func() error {
		_, err := insertAll(pg, news)
		return err
	}, func() error {
		tx, err := pg.pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx) //nolint:errcheck
		if _, err := tx.Exec(ctx, pgScopeOperator); err != nil {
			return err
		}
		t0 := time.Now()
		tag, err := tx.Exec(ctx, headRandPurgeSQL, f.t0, sweepChunk, f.tn)
		if err != nil {
			return err
		}
		purged, stmt, t0 = tag.RowsAffected(), time.Since(t0), time.Now()
		err = tx.Commit(ctx)
		commit = time.Since(t0)
		return err
	})
	if e1 != nil || e2 != nil {
		t.Fatalf("C5: insert %v, purge %v", e1, e2)
	}
	if n := lineCount(f, ""); purged != 5000 || n != 1100 {
		t.Fatalf("C5: purged %d, %d lines left; want 5000 and 1100", purged, n)
	}
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("C5: %d heads differ, e.g. %v", len(d), firstKeys(d, 3))
	}
	t.Logf("C5: 5 000-row purge chunk over 1 000 topics vs 100 inserts: DELETE %s, COMMIT (longest head-lock hold) %s", stmt, commit)
}

// firstKeys is at most n of m's entries, by key.
func firstKeys(m map[string]string, n int) []string {
	var out []string
	for k := range m {
		out = append(out, k+": "+m[k])
	}
	sort.Strings(out)
	if len(out) > n {
		out = out[:n]
	}
	return out
}

// TestTopicHeadSameTaskTwoTenants is C9: two tenants write the SAME task
// uuid at once. Each tenant's head is its own lines' and both diffs are
// empty; then writes in one tenant leave every rev of the other unchanged.
func TestTopicHeadSameTaskTwoTenants(t *testing.T) {
	pg := pgOnly(t)
	t0 := time.Now().UTC().Truncate(time.Microsecond)
	f1, f2 := lightHeadFix(t, pg, t0), lightHeadFix(t, pg, t0)
	f2.task["A"] = uuid4()
	f1.task["A"] = f2.task["A"]
	f1.line("a0", "A", time.Hour, lineOpt{card: true})
	f2.line("a0", "A", time.Hour, lineOpt{card: true})
	l1 := burst(f1, "A", "x", 1, 50, lineOpt{})
	l2 := burst(f2, "A", "y", 1, 50, dmHumAgt)
	e1, e2 := together2(func() error { _, err := insertAll(pg, l1); return err }, func() error { _, err := insertAll(pg, l2); return err })
	if e1 != nil || e2 != nil {
		t.Fatalf("C9: %v / %v", e1, e2)
	}
	for _, f := range []*headFix{f1, f2} {
		if d := headDiff(f); len(d) != 0 {
			t.Fatalf("C9 tenant %s: %v", f.tn, d)
		}
	}
	h1, h2 := readHead(f1, "A"), readHead(f2, "A")
	if h1.lastMsg != l1[0][49].MsgID || h2.lastMsg != l2[0][49].MsgID || h1.dmLastAt != nil || h2.dmLastAt == nil {
		t.Fatalf("C9: heads crossed tenants: t1 %+v, t2 %+v", h1, h2)
	}
	before := headRevs(f2)
	ctx := context.Background()
	f1.line("a9", "A", 0, lineOpt{})
	_, err := pg.MoveMessage(ctx, f1.tn, f1.msg["x0-3"], uuid4(), ChannelLobby, "HUM-1", t0, time.Time{})
	f1.must("move", err)
	f1.must("delete", pg.DeleteMessage(ctx, f1.tn, f1.msg["x0-4"]))
	if after := headRevs(f2); fmt.Sprint(after) != fmt.Sprint(before) {
		t.Fatalf("C9: writes in %s moved %s's revs: %v -> %v", f1.tn, f2.tn, before, after)
	}
	if d := headDiff(f1); len(d) != 0 {
		t.Fatalf("C9 after the t1 writes: %v", d)
	}
}
