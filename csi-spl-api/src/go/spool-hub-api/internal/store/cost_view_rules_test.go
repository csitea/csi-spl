package store

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func viewRule(label, match string, bp int) CostViewRule {
	return CostViewRule{Label: label, Match: match, ShareBP: bp}
}

// viewRulesOf is ws's stored rules as "label match bp" lines, key order.
func viewRulesOf(t *testing.T, vs CostViewRuleStore, ws string) []string {
	t.Helper()
	all, err := vs.CostViewRules(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, r := range all {
		if r.WorkspaceID == ws {
			out = append(out, strings.TrimSpace(r.Label+" "+r.Match)+" "+strconv.Itoa(r.ShareBP))
		}
	}
	return out
}

// SPL-6086, spec 143 costs-workspace-views.md 3.1-3.3, row R1: a workspace's
// rules are replaced whole in one transaction; another workspace's stay; a
// bad set (a match on persons, a bad pattern, a share of 10001 or 0, an
// unknown label, a rule twice) is never stored and leaves the stored set
// whole; a set the database refuses after the delete (a created_by of 201
// characters, rdb 0304's CHECK) leaves it whole too, so the delete and the
// inserts are one transaction; an empty set removes. Memory and Postgres.
func TestCostViewRuleStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			vs, ok := st.(CostViewRuleStore)
			if !ok {
				t.Fatalf("%s keeps no cost view rules", name)
			}
			wa, wb := newTenant(t, st), newTenant(t, st)
			full := []CostViewRule{viewRule(CostViewCloud, "*", 10000), viewRule(CostViewPersons, "", 10000), viewRule(CostViewTokens, "", 10000)}
			if _, err := vs.PutCostViewRules(ctx, wa, "op", full); err != nil {
				t.Fatal(err)
			}
			part := []CostViewRule{viewRule(CostViewTokens, "", 7000), viewRule(CostViewCloud, "ex-a-*", 10000), viewRule(CostViewPersons, "", 3000)}
			got, err := vs.PutCostViewRules(ctx, wb, "op", part)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != 3 || got[0].Label != CostViewCloud || got[0].WorkspaceID != wb || got[0].CreatedBy != "op" || got[0].CreatedAt.IsZero() {
				t.Fatalf("put answer: %+v", got)
			}
			wantA := "cloud * 10000|persons 10000|tokens 10000"
			if s := strings.Join(viewRulesOf(t, vs, wa), "|"); s != wantA {
				t.Fatalf("wa read back %q, want %q", s, wantA)
			}
			if s := strings.Join(viewRulesOf(t, vs, wb), "|"); s != "cloud ex-a-* 10000|persons 3000|tokens 7000" {
				t.Fatalf("wb read back %q", s)
			}
			for why, bad := range map[string][]CostViewRule{
				"persons match":  {viewRule(CostViewCloud, "*", 5000), viewRule(CostViewPersons, "x*", 3000)},
				"cloud no match": {viewRule(CostViewCloud, "", 5000)},
				"bad pattern":    {viewRule(CostViewCloud, "Ex_A*", 5000)},
				"no star":        {viewRule(CostViewCloud, "ex-a", 5000)},
				"share 10001":    {viewRule(CostViewTokens, "", 10001)},
				"share 0":        {viewRule(CostViewTokens, "", 0)},
				"label":          {viewRule("total", "", 5000)},
				"twice":          {viewRule(CostViewTokens, "", 5000), viewRule(CostViewTokens, "", 4000)},
			} {
				if _, err := vs.PutCostViewRules(ctx, wa, "op", bad); err == nil {
					t.Errorf("%s: stored", why)
				}
			}
			if _, err := vs.PutCostViewRules(ctx, wa, strings.Repeat("o", 201), []CostViewRule{viewRule(CostViewTokens, "", 1)}); err == nil {
				t.Errorf("created_by of 201: stored")
			}
			if _, err := vs.PutCostViewRules(ctx, uid("t-gone-"), "op", []CostViewRule{viewRule(CostViewTokens, "", 1)}); err == nil {
				t.Errorf("a workspace the store does not hold: stored")
			}
			if s := strings.Join(viewRulesOf(t, vs, wa), "|"); s != wantA {
				t.Fatalf("a refused set changed the stored one: %q", s)
			}
			if _, err := vs.PutCostViewRules(ctx, wa, "op", []CostViewRule{viewRule(CostViewCloud, "ex-b-*", 2500)}); err != nil {
				t.Fatal(err)
			}
			if s := strings.Join(viewRulesOf(t, vs, wa), "|"); s != "cloud ex-b-* 2500" {
				t.Fatalf("replaced whole: %q", s)
			}
			if _, err := vs.PutCostViewRules(ctx, wa, "op", nil); err != nil {
				t.Fatal(err)
			}
			if s := viewRulesOf(t, vs, wa); s != nil {
				t.Fatalf("after the removal: %q", s)
			}
			if s := viewRulesOf(t, vs, wb); len(s) != 3 {
				t.Fatalf("wb changed by wa's puts: %q", s)
			}
		})
	}
}

// SPL-6086, rdb 0304: no scope and a workspace scope read no view rule (the
// workspace's own included) and may not insert, update or delete one;
// CONTROL: the operator scope reads the row.
func TestCostViewRuleRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	if _, err := pg.PutCostViewRules(ctx, tenant, "op", []CostViewRule{viewRule(CostViewTokens, "", 7000)}); err != nil {
		t.Fatal(err)
	}
	for scope, run := range map[string]func(func(pgx.Tx) error) error{
		"none":      func(fn func(pgx.Tx) error) error { return pgx.BeginFunc(ctx, pg.pool, fn) },
		"workspace": func(fn func(pgx.Tx) error) error { return pg.inTenant(ctx, tenant, fn) },
	} {
		var n int
		if err := run(func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM cost_view_rules WHERE workspace_id = $1`, tenant).Scan(&n)
		}); err != nil || n != 0 {
			t.Errorf("%s scope reads %d view rules (%v), want 0", scope, n, err)
		}
		for _, w := range []string{`UPDATE cost_view_rules SET share_bp = 1 WHERE workspace_id = $1`,
			`DELETE FROM cost_view_rules WHERE workspace_id = $1`} {
			var hit int64
			if err := run(func(tx pgx.Tx) error {
				tag, err := tx.Exec(ctx, w, tenant)
				hit = tag.RowsAffected()
				return err
			}); err != nil || hit != 0 {
				t.Errorf("%s scope %q: %d rows (%v), want 0", scope, strings.Fields(w)[0], hit, err)
			}
		}
		err := run(func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO cost_view_rules (workspace_id, label, match, share_bp, created_by)
				VALUES ($1, 'persons', '', 10000, 'x')`, tenant)
			return err
		})
		if err == nil || !strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s scope insert: %v, want the RLS refusal", scope, err)
		}
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM cost_view_rules WHERE workspace_id = $1 AND share_bp = 7000`, tenant); err != nil || n != 1 {
		t.Fatalf("CONTROL: the operator scope reads the row: %d %v", n, err)
	}
}

// SPL-6086, rdb 0305: cost_entries.covers_source takes NULL or 'gcp' and
// cost_coverage.account_last4 NULL or 4 letters and digits; every existing
// row reads NULL (the columns are additive). Postgres only.
func TestCostEntryCoversColumns(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	check := func(sql string, want bool) {
		t.Helper()
		err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, sql)
			if err != nil {
				return err
			}
			return errRollback
		})
		if ok := errors.Is(err, errRollback); ok != want {
			t.Errorf("%s: accepted=%v (%v), want %v", sql, ok, err, want)
		}
	}
	entry := func(covers string) string {
		return `INSERT INTO cost_entries (id, type, label, amount, currency, period, created_by, covers_source)
			VALUES (gen_random_uuid(), 'cloud', 'synthetic', 1, 'EUR', '2001-01-01', 'op', ` + covers + `)`
	}
	check(entry(`'gcp'`), true)
	check(entry(`NULL`), true)
	check(entry(`'aws'`), false)
	cover := func(last4 string) string {
		return `INSERT INTO cost_coverage (day, source, state, run_id, account_last4)
			VALUES ('2001-01-01', 'gcp-r1-test', 'ok', 'run', ` + last4 + `)`
	}
	check(cover(`'A1b2'`), true)
	check(cover(`NULL`), true)
	check(cover(`'A1b2c'`), false)
	check(cover(`'A1-2'`), false)
}
