package store

import (
	"context"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 123 lane 4 (sections 4.3, 4.6, 8): the box feed's write of one day of
// one source into cost_lines and cost_coverage. The PG tests use their own
// source name per test (estate rows are shared by every test of the database).

func costDayFixture(source string) CostDay {
	return CostDay{Day: "2026-10-09", Source: source, RunID: "run-1", State: "ok", Lines: []CostLine{
		{ProjectOrVendor: "claude", AgentID: "c-101", Model: "m-x", Kind: "output.standard", Units: 107, Origin: "transcript"},
		{ProjectOrVendor: "claude", AgentID: "c-101", Model: "m-x", Kind: "cache_read.standard", Units: 1011, Origin: "transcript"},
		{ProjectOrVendor: "grok", AgentID: "g-201", Kind: "unmetered", Units: 0, Origin: "transcript"},
	}}
}

// TestCheckCostDay: the feed refuses what rdb 0166 or its own rules would.
func TestCheckCostDay(t *testing.T) {
	ok := costDayFixture("fleet_tokens.box-a")
	if why := CheckCostDay(ok); why != "" {
		t.Fatalf("the fixture is refused: %s", why)
	}
	for name, mut := range map[string]func(*CostDay){
		"bad day":          func(d *CostDay) { d.Day = "2026-02-30" },
		"bad source":       func(d *CostDay) { d.Source = "Fleet Tokens" },
		"no run id":        func(d *CostDay) { d.RunID = "" },
		"bad state":        func(d *CostDay) { d.State = "fine" },
		"partial, no why":  func(d *CostDay) { d.State = "partial" },
		"missing + lines":  func(d *CostDay) { d.State, d.Reason = "missing", "reader failed" },
		"gcp origin":       func(d *CostDay) { d.Lines[0].Origin = "billing_export" },
		"hand origin":      func(d *CostDay) { d.Lines[0].Origin = "hand" },
		"negative units":   func(d *CostDay) { d.Lines[0].Units = -1 },
		"bad kind":         func(d *CostDay) { d.Lines[0].Kind = "Output" },
		"no vendor":        func(d *CostDay) { d.Lines[0].ProjectOrVendor = "" },
		"duplicate key":    func(d *CostDay) { d.Lines[1].Kind = d.Lines[0].Kind },
		"newline in agent": func(d *CostDay) { d.Lines[0].AgentID = "c-1\nx" },
	} {
		d := costDayFixture("fleet_tokens.box-a")
		d.Lines = append([]CostLine(nil), d.Lines...)
		mut(&d)
		if CheckCostDay(d) == "" {
			t.Errorf("%s: admitted", name)
		}
	}
}

// costSourceRows reads the live rows of (day, source) as the operator:
// key -> units, and the coverage state and reason.
func costSourceRows(t *testing.T, pg *Postgres, day, source string) (map[string]float64, string, string) {
	t.Helper()
	ctx := context.Background()
	rows := map[string]float64{}
	var state, reason string
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		r, err := tx.Query(ctx, `SELECT project_or_vendor || '/' || coalesce(agent_id, '-') || '/' || coalesce(model, '-') || '/' || kind,
			units::float8 FROM cost_lines WHERE day = $1::date AND source = $2 AND superseded_by IS NULL`, day, source)
		if err != nil {
			return err
		}
		for r.Next() {
			var k string
			var u float64
			if err := r.Scan(&k, &u); err != nil {
				return err
			}
			if _, dup := rows[k]; dup {
				rows[k+"#dup"] = u
			}
			rows[k] = u
		}
		if err := r.Err(); err != nil {
			return err
		}
		err = tx.QueryRow(ctx, `SELECT state, coalesce(reason, '') FROM cost_coverage WHERE day = $1::date AND source = $2`, day, source).Scan(&state, &reason)
		if err == pgx.ErrNoRows {
			return nil
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return rows, state, reason
}

// TestCostIngestIdempotent (section 8 Idempotency): the same day put twice
// leaves the same rows with the same units, never twice the count. CONTROL:
// with the ON CONFLICT clause dropped the second put is refused (23505), so
// the one row per key is the UPSERT's.
func TestCostIngestIdempotent(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	src := "fleet_tokens." + strings.ToLower(uid("b"))
	d := costDayFixture(src)
	for i := range 2 {
		d.RunID = "run-" + string(rune('1'+i))
		res, err := pg.PutCostDay(ctx, d)
		if err != nil || res.Written != 3 || res.Removed != 0 {
			t.Fatalf("put %d: %+v %v", i+1, res, err)
		}
	}
	rows, state, _ := costSourceRows(t, pg, d.Day, src)
	if len(rows) != 3 || rows["claude/c-101/m-x/output.standard"] != 107 || rows["grok/g-201/-/unmetered"] != 0 || state != "ok" {
		t.Fatalf("after two puts: %v state %q", rows, state)
	}
	saved := costLineUpsert
	t.Cleanup(func() { costLineUpsert = saved })
	costLineUpsert = saved[:strings.Index(saved, "ON CONFLICT")]
	if _, err := pg.PutCostDay(ctx, d); pgCode(err) != "23505" {
		t.Fatalf("CONTROL: without ON CONFLICT the re-put answered %v, want 23505", err)
	}
}

// TestCostIngestReRead: a re-read updates a changed count and removes the
// line it no longer has; a missing day removes nothing and keeps the old
// rows; a partial day keeps its reason.
func TestCostIngestReRead(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	src := "agent_hours." + strings.ToLower(uid("b"))
	d := costDayFixture(src)
	if _, err := pg.PutCostDay(ctx, d); err != nil {
		t.Fatal(err)
	}
	d.RunID, d.State, d.Reason = "run-2", "partial", "1 agent(s) unmetered"
	d.Lines = []CostLine{d.Lines[0], d.Lines[2]}
	d.Lines[0].Units = 120
	res, err := pg.PutCostDay(ctx, d)
	if err != nil || res.Written != 2 || res.Removed != 1 {
		t.Fatalf("re-read: %+v %v", res, err)
	}
	rows, state, reason := costSourceRows(t, pg, d.Day, src)
	if len(rows) != 2 || rows["claude/c-101/m-x/output.standard"] != 120 || state != "partial" || reason != "1 agent(s) unmetered" {
		t.Fatalf("after the re-read: %v %q %q", rows, state, reason)
	}
	miss := CostDay{Day: d.Day, Source: src, RunID: "run-3", State: "missing", Reason: "no transcript dir"}
	if res, err := pg.PutCostDay(ctx, miss); err != nil || res.Removed != 0 {
		t.Fatalf("missing: %+v %v", res, err)
	}
	rows, state, _ = costSourceRows(t, pg, d.Day, src)
	if len(rows) != 2 || state != "missing" {
		t.Fatalf("a missing read erased rows or kept ok: %v %q", rows, state)
	}
	other, _, _ := costSourceRows(t, pg, d.Day, src+"x")
	if len(other) != 0 {
		t.Fatalf("another source's day holds %v", other)
	}
}
