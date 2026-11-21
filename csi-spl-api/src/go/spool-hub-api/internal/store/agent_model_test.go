package store

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// spec 184 row H1 (contract 7.1.5, rdb 0309): the default model per agent
// kind as the hub reads and writes it, on Memory and Postgres.
//   - overrides (n=3 set, 1 reset): a fresh workspace has none; set cells
//     read back sorted with their writer; a reset cell is gone; another
//     workspace reads none of them.
//   - refused (n=9): an unknown vendor or kind, an alias kind, a model
//     failing the 7.1.2 syntax (space, quote, 81 characters, empty), a cell
//     named twice, an empty patch. A refused patch writes nothing, not even
//     its good cells.
//   - readings (n=5): the first is stored; a newer read_at replaces it; an
//     older and an equal one are ignored; a bad reading is refused; another
//     workspace reads none.
func TestAgentModels(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 21, 9, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			am, ok := st.(AgentModels)
			if !ok {
				t.Fatalf("%s keeps no agent models", name)
			}
			tid, other := newTenant(t, st), newTenant(t, st)
			testAgentModelCells(ctx, t, am, tid, other, now)
			testAgentModelReadings(ctx, t, am, tid, other, now)
		})
	}
}

func agentModelLine(rows []AgentModel) string {
	var out []string
	for _, m := range rows {
		out = append(out, m.Vendor+":"+m.Kind+"="+m.Model)
	}
	return strings.Join(out, ",")
}

func testAgentModelCells(ctx context.Context, t *testing.T, am AgentModels, tid, other string, now time.Time) {
	t.Helper()
	read := func(tenant string) []AgentModel {
		t.Helper()
		rows, err := am.AgentModels(ctx, tenant)
		if err != nil {
			t.Fatalf("read %s: %v", tenant, err)
		}
		return rows
	}
	if got := read(tid); len(got) != 0 {
		t.Fatalf("a fresh workspace reads %v", got)
	}
	if err := am.SetAgentModels(ctx, tid, AgentModelPatch{By: "HUM-1", Set: []AgentModel{
		{Vendor: "grok", Kind: "tests", Model: "grok-4.6"},
		{Vendor: "claude", Kind: "complex_coding", Model: "opus"},
		{Vendor: "claude", Kind: "*", Model: "sonnet"},
		{Vendor: "mistral", Kind: "*", Model: "mistral-large"},
	}}, now); err != nil {
		t.Fatalf("set: %v", err)
	}
	got := read(tid)
	if l := agentModelLine(got); l != "claude:*=sonnet,claude:complex_coding=opus,grok:tests=grok-4.6,mistral:*=mistral-large" {
		t.Fatalf("read back %s", l)
	}
	if got[0].UpdatedBy != "HUM-1" || !got[0].UpdatedAt.Equal(now) {
		t.Fatalf("writer: %q %v", got[0].UpdatedBy, got[0].UpdatedAt)
	}
	long := strings.Repeat("m", 81)
	for label, p := range map[string]AgentModelPatch{
		"unknown vendor":  {Set: []AgentModel{{Vendor: "gemini", Kind: "*", Model: "x"}}},
		"unknown kind":    {Set: []AgentModel{{Vendor: "claude", Kind: "docs", Model: "x"}}},
		"alias kind hard": {Reset: []AgentModelKey{{"claude", "hard"}}},
		"model with a space beside a good cell": {Set: []AgentModel{
			{Vendor: "qwen", Kind: "*", Model: "qwen3-coder"}, {Vendor: "agy", Kind: "*", Model: "Gemini 3.8 Flash (High)"}}},
		"model with a quote": {Set: []AgentModel{{Vendor: "claude", Kind: "tests", Model: "opus'; rm -rf /"}}},
		"model 81 long":      {Set: []AgentModel{{Vendor: "claude", Kind: "tests", Model: long}}},
		"model empty":        {Set: []AgentModel{{Vendor: "claude", Kind: "tests", Model: ""}}},
		"named twice": {Set: []AgentModel{{Vendor: "claude", Kind: "*", Model: "opus"}},
			Reset: []AgentModelKey{{"claude", "*"}}},
		"empty": {},
	} {
		if err := am.SetAgentModels(ctx, tid, p, now); !errors.Is(err, ErrBadAgentModel) {
			t.Errorf("%s: %v, want ErrBadAgentModel", label, err)
		}
	}
	if l := agentModelLine(read(tid)); strings.Contains(l, "qwen") || !strings.Contains(l, "claude:*=sonnet") {
		t.Fatalf("a refused patch wrote: %s", l)
	}
	if got := read(other); len(got) != 0 {
		t.Fatalf("another workspace reads %s", agentModelLine(got))
	}
	later := now.Add(time.Hour)
	if err := am.SetAgentModels(ctx, tid, AgentModelPatch{By: "HUM-2",
		Set:   []AgentModel{{Vendor: "claude", Kind: "*", Model: "claude-opus-5-5"}},
		Reset: []AgentModelKey{{"grok", "tests"}}}, later); err != nil {
		t.Fatalf("replace + reset: %v", err)
	}
	got = read(tid)
	if l := agentModelLine(got); l != "claude:*=claude-opus-5-5,claude:complex_coding=opus,mistral:*=mistral-large" {
		t.Fatalf("after replace + reset: %s", l)
	}
	if got[0].UpdatedBy != "HUM-2" || !got[0].UpdatedAt.Equal(later) {
		t.Fatalf("replaced writer: %q %v", got[0].UpdatedBy, got[0].UpdatedAt)
	}
}

func testAgentModelReadings(ctx context.Context, t *testing.T, am AgentModels, tid, other string, now time.Time) {
	t.Helper()
	put := func(r AgentModelReading, want bool) {
		t.Helper()
		stored, err := am.PutAgentModelReading(ctx, tid, r)
		if err != nil || stored != want {
			t.Fatalf("put %s/%s at %v: stored=%v %v, want %v", r.Box, r.Vendor, r.ReadAt, stored, err, want)
		}
	}
	read := func(tenant string) []AgentModelReading {
		t.Helper()
		rows, err := am.AgentModelReadings(ctx, tenant)
		if err != nil {
			t.Fatalf("readings %s: %v", tenant, err)
		}
		return rows
	}
	if got := read(tid); len(got) != 0 {
		t.Fatalf("a fresh workspace reads %v", got)
	}
	put(AgentModelReading{Box: "box-a", Vendor: "grok", CLIVersion: "1.0.89",
		Models: []string{"grok-4.7", "grok-4.6"}, ReadAt: now}, true)
	put(AgentModelReading{Box: "box-a", Vendor: "claude", CLIVersion: "2.1.323",
		Models: []string{"fable", "opus", "sonnet"}, ReadAt: now}, true)
	put(AgentModelReading{Box: "box-a", Vendor: "grok", CLIVersion: "1.0.92",
		Models: []string{"grok-4.7", "grok-4.7-build-fast"}, ReadAt: now.Add(time.Minute)}, true)
	put(AgentModelReading{Box: "box-a", Vendor: "grok", CLIVersion: "1.0.80",
		Models: []string{"grok-3"}, ReadAt: now.Add(-time.Hour)}, false)
	put(AgentModelReading{Box: "box-a", Vendor: "grok", CLIVersion: "1.0.81",
		Models: []string{"grok-3"}, ReadAt: now.Add(time.Minute)}, false)
	put(AgentModelReading{Box: "box-b", Vendor: "mistral", Models: nil, ReadAt: now}, true)
	got := read(tid)
	if len(got) != 3 || got[0].Vendor != "claude" || got[1].Vendor != "grok" || got[2].Box != "box-b" {
		t.Fatalf("readings: %+v", got)
	}
	g := got[1]
	if g.CLIVersion != "1.0.92" || !slices.Equal(g.Models, []string{"grok-4.7", "grok-4.7-build-fast"}) ||
		!g.ReadAt.Equal(now.Add(time.Minute)) {
		t.Fatalf("the newer grok reading did not replace the older: %+v", g)
	}
	if got[2].Models == nil || len(got[2].Models) != 0 {
		t.Fatalf("an empty list reads %#v, want []", got[2].Models)
	}
	for label, r := range map[string]AgentModelReading{
		"unknown vendor":  {Box: "box-a", Vendor: "gemini", ReadAt: now},
		"bad box":         {Box: "box a", Vendor: "grok", ReadAt: now},
		"model syntax":    {Box: "box-a", Vendor: "agy", Models: []string{"Gemini 3.8 Flash (High)"}, ReadAt: now},
		"no read_at":      {Box: "box-a", Vendor: "grok"},
		"too many":        {Box: "box-a", Vendor: "grok", Models: slices.Repeat([]string{"m"}, MaxAgentModelsListed+1), ReadAt: now},
		"cli control chr": {Box: "box-a", Vendor: "grok", CLIVersion: "1.0\n", ReadAt: now},
	} {
		if _, err := am.PutAgentModelReading(ctx, tid, r); !errors.Is(err, ErrBadAgentModel) {
			t.Errorf("%s: %v, want ErrBadAgentModel", label, err)
		}
	}
	if got := read(other); len(got) != 0 {
		t.Fatalf("another workspace reads %+v", got)
	}
}

// rdb 0309 on Postgres, under the plain owner role of hub-pg.tst.sh: the
// row CHECKs refuse what the store would (the database is the last word),
// and RLS keeps each workspace to its own rows of both tables.
// RED CONTROL (spec 184 row H1): migrate a test copy of the SQL dir whose
// 0309 drops the RLS lines (ENABLE, FORCE, both policies): the
// cross-workspace read case then reads the other workspace's rows and fails.
func TestTenantAgentModel0309(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Date(2026, 11, 21, 9, 0, 0, 0, time.UTC)
	a, b := newTenant(t, pg), newTenant(t, pg)
	if err := pg.SetAgentModels(ctx, a, AgentModelPatch{By: "HUM-1",
		Set: []AgentModel{{Vendor: "claude", Kind: "*", Model: "sonnet"}}}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.PutAgentModelReading(ctx, a, AgentModelReading{Box: "box-a", Vendor: "grok",
		Models: []string{"grok-4.7"}, ReadAt: now}); err != nil {
		t.Fatal(err)
	}
	// scoped runs fn in one transaction under tenant's scope; the error is
	// the first statement's.
	scoped := func(tenant string, fn func(pgx.Tx) error) error {
		return pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
				return err
			}
			return fn(tx)
		})
	}
	count := func(tenant, table string) int {
		t.Helper()
		var n int
		if err := scoped(tenant, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM `+pgx.Identifier{table}.Sanitize()).Scan(&n)
		}); err != nil {
			t.Fatal(err)
		}
		return n
	}
	for _, table := range []string{"tenant_agent_model", "agent_model_reading"} {
		if n := count(a, table); n != 1 {
			t.Errorf("%s: workspace %s reads %d of its own rows, want 1", table, a, n)
		}
		// the cross-workspace read case: a query with no tenant predicate
		if n := count(b, table); n != 0 {
			t.Errorf("RLS %s: workspace %s reads %d rows of another workspace, want 0", table, b, n)
		}
	}
	insertErr := func(scope, sql string, args ...any) string {
		t.Helper()
		err := scoped(scope, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, sql, args...); return err })
		var pe *pgconn.PgError
		switch {
		case err == nil:
			return ""
		case errors.As(err, &pe) && pe.Code == "42501":
			return "rls"
		case errors.As(err, &pe):
			return pe.ConstraintName
		}
		t.Fatalf("not a Postgres error: %v", err)
		return ""
	}
	const model = `INSERT INTO tenant_agent_model (tenant_id, vendor, kind, model) VALUES ($1, $2, $3, $4)`
	const reading = `INSERT INTO agent_model_reading (tenant_id, box, vendor, models, read_at) VALUES ($1, $2, $3, $4, now())`
	for _, c := range []struct {
		name, want, sql string
		args            []any
	}{
		{"a write into another workspace", "rls", model, []any{a, "grok", "*", "grok-4.7"}},
		{"a reading into another workspace", "rls", reading, []any{a, "box-b", "grok", []string{"x"}}},
		{"unknown vendor", "tenant_agent_model_vendor_check", model, []any{b, "gemini", "*", "x"}},
		{"unknown kind", "tenant_agent_model_kind_check", model, []any{b, "claude", "hard", "x"}},
		{"model with a space", "tenant_agent_model_model_check", model, []any{b, "claude", "*", "a b"}},
		{"model with a quote", "tenant_agent_model_model_check", model, []any{b, "claude", "*", "a'b"}},
		{"reading vendor", "agent_model_reading_vendor_check", reading, []any{b, "box-b", "gemini", []string{"x"}}},
		{"reading model syntax", "agent_model_reading_models_check", reading, []any{b, "box-b", "agy", []string{"ok", "Gemini 3.8"}}},
		{"a good row", "", model, []any{b, "codex", "tests", "gpt-5.6-terra"}},
	} {
		if got := insertErr(b, c.sql, c.args...); got != c.want {
			t.Errorf("%s: broke %q, want %q", c.name, got, c.want)
		}
	}
}
