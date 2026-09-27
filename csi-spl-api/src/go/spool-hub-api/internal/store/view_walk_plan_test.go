package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// SPL-984: the topic walk's scope batch turns bitmap scans off for that one
// statement. Each recursive step is ORDER BY ... LIMIT 1 behind four or five
// boolean probes, so the planner rates it at rows=1 and LIMIT 1 looks no
// cheaper than reading everything; it then picked a Bitmap Heap Scan of every
// older message of the tenant per step (prd t1 2026-09-26: 3 488 rows per step,
// 171 832 probe loops, 1.0-1.6 s per page). With bitmap scans off each step is
// an ordered backward index scan that stops at the first passing row
// (lab: 1 977 -> 21.5 ms at 11.7k messages). set_config(..., true) is local to
// the batch's implicit transaction, so no other statement is affected.
func TestPgScopeTenantNoJITPlannerSettings(t *testing.T) {
	for _, want := range []string{
		`set_config('app.tenant_id', $1, true)`,
		`set_config('jit', 'off', true)`,
		`set_config('enable_bitmapscan', 'off', true)`,
		`set_config('plan_cache_mode', 'force_custom_plan', true)`,
	} {
		if !strings.Contains(pgScopeTenantNoJIT, want) {
			t.Errorf("pgScopeTenantNoJIT lacks %s: %s", want, pgScopeTenantNoJIT)
		}
	}
	if strings.Contains(pgScopeTenantNoJIT, "false)") {
		t.Errorf("a setting is session-wide (is_local=false) and would leak into the pooled connection: %s", pgScopeTenantNoJIT)
	}
}

// preSPL984Scope is pgScopeTenantNoJIT as it was before SPL-984 (the CONTROL).
const preSPL984Scope = `SELECT set_config('app.tenant_id', $1, true), set_config('jit', 'off', true)`

// walkLines runs the walk for q under scope (prefix "EXPLAIN ..." or "") and
// returns the first column of every row: the plan lines, or the task ids.
func walkLines(t *testing.T, pg *Postgres, scope, prefix, tenant string, q TopicQuery) []string {
	t.Helper()
	ctx := context.Background()
	sql, args := viewTopicsSQL(tenant, q)
	b := &pgx.Batch{}
	b.Queue(scope, tenant)
	b.Queue(prefix+sql, args...)
	br := pg.pool.SendBatch(ctx, b)
	defer br.Close()
	if _, err := br.Exec(); err != nil {
		t.Fatal(err)
	}
	rows, err := br.Query()
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	if err := scanRows(rows, func(r pgx.Rows) error {
		v, err := r.Values()
		if err != nil {
			return err
		}
		out = append(out, v[0].(string))
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return out
}

// TestViewTopicsWalkPlanShape seeds a prd-t1-sized tenant (4 000 messages,
// 300 topics) and asks the lobby's real question (read door, Roots,
// NoIssues, limit 51). The walk must not bitmap-scan messages, and its answer
// must equal the answer without the planner setting.
func TestViewTopicsWalkPlanShape(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	tn := newTenant(t, pg)
	seedTopics(t, pg, tn, 4000, 300, now, 0.21)
	q := TopicQuery{Roots: true, NoIssues: true, Reader: "HUM-1", ReaderChannels: []string{"c1", "c2"}, Limit: 51, Now: now}
	for _, qc := range []struct {
		name string
		q    TopicQuery
	}{{"all", q}, {"dm", func() TopicQuery { d := q; d.DM, d.Viewer = true, "HUM-1"; return d }()}} {
		const explain = "EXPLAIN (ANALYZE, BUFFERS) "
		plan := strings.Join(walkLines(t, pg, pgScopeTenantNoJIT, explain, tn, qc.q), "\n")
		if strings.Contains(plan, "Bitmap Heap Scan on messages") {
			t.Errorf("%s: the walk bitmap-scans messages under pgScopeTenantNoJIT:\n%s", qc.name, plan)
		}
		old := strings.Join(walkLines(t, pg, preSPL984Scope, explain, tn, qc.q), "\n")
		t.Logf("%s: CONTROL the pre-SPL-984 scope bitmap-scans messages: %v", qc.name, strings.Contains(old, "Bitmap Heap Scan on messages"))
		// A planner setting must never change the answer.
		got, want := walkLines(t, pg, pgScopeTenantNoJIT, "", tn, qc.q), walkLines(t, pg, preSPL984Scope, "", tn, qc.q)
		if len(got) == 0 || strings.Join(got, ",") != strings.Join(want, ",") {
			t.Fatalf("%s: %d rows %v, pre-SPL-984 scope %d rows %v", qc.name, len(got), got, len(want), want)
		}
		rows, err := pg.ViewTopics(ctx, tn, qc.q)
		if err != nil || len(rows) != len(got) {
			t.Fatalf("%s: ViewTopics %d rows (%v), walk %d", qc.name, len(rows), err, len(got))
		}
	}
}

// plansOnOneConn runs the walk for q under scope runs times on ONE pooled
// connection (pgx prepares it there once, as in the hub) and returns that
// prepared statement's generic and custom plans in those runs.
func plansOnOneConn(t *testing.T, pg *Postgres, scope, tenant string, q TopicQuery, runs int) (generic, custom int64) {
	t.Helper()
	ctx := context.Background()
	conn, err := pg.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	sql, args := viewTopicsSQL(tenant, q)
	counts := func() (g, c int64) { // cumulative per connection; none before the first run
		err := conn.QueryRow(ctx, `SELECT generic_plans, custom_plans FROM pg_prepared_statements
			WHERE statement = $1`, sql).Scan(&g, &c)
		if err != nil && err != pgx.ErrNoRows {
			t.Fatal(err)
		}
		return g, c
	}
	g0, c0 := counts()
	for i := 0; i < runs; i++ {
		b := &pgx.Batch{}
		b.Queue(scope, tenant)
		b.Queue(sql, args...)
		br := conn.SendBatch(ctx, b)
		if _, err := br.Exec(); err != nil {
			t.Fatal(err)
		}
		rows, err := br.Query()
		if err != nil {
			t.Fatal(err)
		}
		rows.Close()
		if err := br.Close(); err != nil {
			t.Fatal(err)
		}
	}
	g1, c1 := counts()
	return g1 - g0, c1 - c0
}

// TestViewTopicsWalkNeverGenericPlan (CLE-35061): after five runs of a
// prepared statement Postgres may switch to a generic plan, built without the
// tenant, the time or the reader's channels; for the walk that plan was 2.5x
// slower on prd t1 (71 vs 27 ms). The scope forces a custom plan every run.
func TestViewTopicsWalkNeverGenericPlan(t *testing.T) {
	pg := pgOnly(t)
	now := time.Now().UTC().Truncate(time.Millisecond)
	tn := newTenant(t, pg)
	seedTopics(t, pg, tn, 2000, 150, now, 0.37)
	q := TopicQuery{Roots: true, NoIssues: true, Reader: "HUM-1", ReaderChannels: []string{"c1", "c2"}, Limit: 51, Now: now}
	const runs = 8
	generic, custom := plansOnOneConn(t, pg, pgScopeTenantNoJIT, tn, q, runs)
	if generic != 0 || custom != runs {
		t.Errorf("pgScopeTenantNoJIT: %d generic / %d custom plans in %d runs, want 0 / %d", generic, custom, runs, runs)
	}
	// CONTROL: the same walk without the setting (the plan choice is the
	// planner's, so this is logged, not asserted).
	g, c := plansOnOneConn(t, pg, preSPL984Scope, tn, q, runs)
	t.Logf("CONTROL without plan_cache_mode: %d generic / %d custom plans in %d runs", g, c, runs)
}
