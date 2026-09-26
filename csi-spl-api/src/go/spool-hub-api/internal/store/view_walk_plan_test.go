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
