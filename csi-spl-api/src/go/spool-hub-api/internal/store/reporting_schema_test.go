package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 143 build row 1, the Reporting schema (rdb 0202-0204, SPL-2347).
// Postgres only (hub-pg.tst.sh). Each test is red before its migration: the
// table or column it reads does not exist.

const estateDeployInsert = `INSERT INTO estate_deploys (deploy_id, env, component, version, commit_sha, status, source)
	VALUES ($1, 'prd', 'hub', 'v1.7.1', $2, 'success', $3)`

// scopes are the two non-operator scopes a hub statement can run in.
func reportingScopes(pg *Postgres, tenant string) map[string]func(func(pgx.Tx) error) error {
	ctx := context.Background()
	return map[string]func(func(pgx.Tx) error) error{
		"none":      func(fn func(pgx.Tx) error) error { return pgx.BeginFunc(ctx, pg.pool, fn) },
		"workspace": func(fn func(pgx.Tx) error) error { return pg.inTenant(ctx, tenant, fn) },
	}
}

func execIn(run func(func(pgx.Tx) error) error, sql string, args ...any) error {
	return run(func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), sql, args...)
		return err
	})
}

// T001: estate_deploys. GATE: the operator writes a row, every scope reads
// it, source defaults to ci and takes reconcile, a duplicate deploy_id is
// the unique violation. RED CONTROL: an insert with no scope or in a
// workspace scope is refused by RLS; a bad source or sha is refused.
func TestEstateDeploysSchema(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	id, sha := uuid4(), strings.Repeat("ab", 20)
	if _, err := pg.asOperator2(ctx, `INSERT INTO estate_deploys (deploy_id, env, component, version, commit_sha, status)
		VALUES ($1, 'dev', 'wui', 'v1.7.1-c3', $2, 'success')`, id, sha); err != nil {
		t.Fatalf("operator insert: %v", err)
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM estate_deploys WHERE deploy_id = $1 AND source = 'ci'`, id); err != nil || n != 1 {
		t.Fatalf("source default: %d %v, want the ci row", n, err)
	}
	if _, err := pg.asOperator2(ctx, estateDeployInsert, uuid4(), sha, "reconcile"); err != nil {
		t.Fatalf("a reconcile row: %v", err)
	}
	if _, err := pg.asOperator2(ctx, estateDeployInsert, id, sha, "ci"); err == nil || !strings.Contains(err.Error(), "estate_deploys_pkey") {
		t.Fatalf("duplicate deploy_id: %v, want the unique violation", err)
	}
	for _, bad := range [][]any{{uuid4(), sha, "manual"}, {uuid4(), "ABC", "ci"}, {"not-a-uuid", sha, "ci"}} {
		if _, err := pg.asOperator2(ctx, estateDeployInsert, bad...); err == nil || !strings.Contains(err.Error(), "check constraint") {
			t.Errorf("insert %v: %v, want a check violation", bad, err)
		}
	}
	tenant := newTenant(t, pg)
	for scope, run := range reportingScopes(pg, tenant) {
		var n int
		if err := run(func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM estate_deploys WHERE deploy_id = $1`, id).Scan(&n)
		}); err != nil || n != 1 {
			t.Errorf("%s scope reads %d of the deploy (%v), want 1 (estate-wide read)", scope, n, err)
		}
		if err := execIn(run, estateDeployInsert, uuid4(), sha, "ci"); err == nil || !strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s scope insert: %v, want the RLS refusal", scope, err)
		}
		if err := execIn(run, `UPDATE estate_deploys SET status = 'failed' WHERE deploy_id = $1`, id); err != nil {
			t.Errorf("%s scope update: %v", scope, err)
		}
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM estate_deploys WHERE deploy_id = $1 AND status = 'success'`, id); err != nil || n != 1 {
		t.Fatalf("a non-operator UPDATE changed the row: %d %v", n, err)
	}
}

const sqlAuditInsert = `INSERT INTO sql_query_audit (audit_id, tenant_id, human_id, query_text, duration_ms, row_count)
	VALUES ($1, $2, 'HUM-1', 'SELECT 1', 3, 1)`

// seedSQLAudit writes one audit row for tenant in its own scope, the way the
// SQL tab will (crosstenant_test.go seedTenantAll).
func seedSQLAudit(ctx context.Context, pg *Postgres, tenant string) error {
	_, err := pg.execTenant(ctx, tenant, sqlAuditInsert, uuid4(), tenant)
	return err
}

// T002: sql_query_audit. GATE: a workspace writes and reads its own row, the
// operator reads it. RED CONTROL: with no workspace set a read sees 0 rows
// and an insert is refused; another workspace reads 0 of the rows and
// cannot write one stamped with them; an UPDATE or DELETE is refused as
// append-only, in the workspace and in the operator scope.
func TestSQLQueryAuditSchema(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	if err := seedSQLAudit(ctx, pg, a); err != nil {
		t.Fatalf("A writes its own audit row: %v", err)
	}
	count := func(run func(func(pgx.Tx) error) error) (int, error) {
		var n int
		err := run(func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM sql_query_audit WHERE tenant_id = $1`, a).Scan(&n)
		})
		return n, err
	}
	scopesA, scopesB := reportingScopes(pg, a), reportingScopes(pg, b)
	if n, err := count(scopesA["workspace"]); err != nil || n != 1 {
		t.Fatalf("CONTROL: A reads %d of its rows (%v), want 1", n, err)
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM sql_query_audit WHERE tenant_id = $1`, a); err != nil || n != 1 {
		t.Fatalf("CONTROL: the operator reads %d (%v), want 1", n, err)
	}
	for name, run := range map[string]func(func(pgx.Tx) error) error{"no workspace": scopesA["none"], "workspace B": scopesB["workspace"]} {
		if n, err := count(run); err != nil || n != 0 {
			t.Errorf("%s reads %d of A's audit rows (%v), want 0", name, n, err)
		}
		if err := execIn(run, sqlAuditInsert, uuid4(), a); err == nil || !strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s writes an A-stamped row: %v, want the RLS refusal", name, err)
		}
	}
	for _, w := range []string{`UPDATE sql_query_audit SET row_count = 9 WHERE tenant_id = $1`, `DELETE FROM sql_query_audit WHERE tenant_id = $1`} {
		if err := execIn(scopesA["workspace"], w, a); err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Errorf("A: %s: %v, want the append-only refusal", w, err)
		}
		if _, err := pg.asOperator2(ctx, w, a); err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Errorf("operator: %s: %v, want the append-only refusal", w, err)
		}
	}
	var id string
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT audit_id FROM sql_query_audit WHERE tenant_id = $1`, a).Scan(&id)
	}); err != nil {
		t.Fatal(err)
	}
	if err := execIn(scopesA["workspace"], sqlAuditInsert, id, a); err == nil || !strings.Contains(err.Error(), "sql_query_audit_pkey") {
		t.Fatalf("duplicate audit_id: %v, want the unique violation", err)
	}
}

// activitySeed is spec 4.2.1, the owner's poll 2 answer.
var activitySeed = []string{
	"coding", "coding/hard", "coding/i18n", "coding/simple",
	"dispatch", "dispatch/placement", "dispatch/triage",
	"review", "review/gate", "review/r7",
	"specs_and_docs", "specs_and_docs/doc", "specs_and_docs/spec",
	"tests", "tests/e2e", "tests/unit",
}

// T003: activity_categories and the fleet_asks columns. GATE: the seed is
// exactly the 5 areas and their sub-categories, every scope reads it, a
// new finer category is one operator INSERT, an ask takes a work kind and a
// category. RED CONTROL: an uppercase or symbol path, a parent that is not
// the path's prefix, a non-operator insert, an unknown work kind and an
// unknown category are each refused.
func TestActivityCategoriesSchema(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	for scope, run := range reportingScopes(pg, tenant) {
		var got []string
		if err := run(func(tx pgx.Tx) error {
			rows, err := tx.Query(ctx, `SELECT category_path FROM activity_categories WHERE category_path !~ '(^|/)zz' ORDER BY 1`)
			if err != nil {
				return err
			}
			return scanRows(rows, func(r pgx.Rows) error {
				got = append(got, "")
				return r.Scan(&got[len(got)-1])
			})
		}); err != nil || strings.Join(got, ",") != strings.Join(activitySeed, ",") {
			t.Errorf("%s scope reads %v (%v), want the seed %v", scope, got, err, activitySeed)
		}
		if err := execIn(run, `INSERT INTO activity_categories (category_path, parent_path, title) VALUES ('zzscope', NULL, 'x')`); err == nil ||
			!strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s scope insert: %v, want the RLS refusal", scope, err)
		}
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM activity_categories WHERE parent_path IS NULL`); err != nil || n != 5 {
		t.Fatalf("top-level areas: %d %v, want 5", n, err)
	}
	leaf := "zz" + strings.ToLower(strings.ReplaceAll(uid(""), "-", ""))
	if _, err := pg.asOperator2(ctx, `INSERT INTO activity_categories (category_path, parent_path, title) VALUES ($1, 'coding/hard', 'Finer')`,
		"coding/hard/"+leaf); err != nil {
		t.Fatalf("a finer category: %v", err)
	}
	for _, bad := range [][2]any{{"Coding/Upper", "coding"}, {"coding/a-b", "coding"}, {"coding/", "coding"}, {"coding/" + leaf, "tests"}, {leaf, "coding"}, {"tests/" + leaf, nil}} {
		if _, err := pg.asOperator2(ctx, `INSERT INTO activity_categories (category_path, parent_path, title) VALUES ($1, $2, 'x')`, bad[0], bad[1]); err == nil ||
			!strings.Contains(err.Error(), "check constraint") {
			t.Errorf("category %v: %v, want a check violation", bad, err)
		}
	}

	ask := uuid4()
	if _, _, err := pg.PutFleetAsk(ctx, tenant, FleetAsk{Fleet: "main", AskID: ask, Role: "orch", Kind: "task", From: "c-002"}, "box-a", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	set := func(col string, v any) error {
		_, err := pg.execTenant(ctx, tenant, `UPDATE fleet_asks SET `+pgx.Identifier{col}.Sanitize()+` = $1 WHERE ask_id = $2`, v, ask)
		return err
	}
	var kind string
	var cat *string
	if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT work_kind, category_path FROM fleet_asks WHERE ask_id = $1`, ask).Scan(&kind, &cat)
	}); err != nil || kind != "" || cat != nil {
		t.Fatalf("new ask: work_kind %q category %v (%v), want '' and NULL", kind, cat, err)
	}
	if err := set("work_kind", "complex_coding"); err != nil {
		t.Errorf("work_kind complex_coding: %v", err)
	}
	if err := set("category_path", "coding/hard"); err != nil {
		t.Errorf("category coding/hard: %v", err)
	}
	if err := set("work_kind", "hard"); err == nil || !strings.Contains(err.Error(), "check constraint") {
		t.Errorf("work_kind hard: %v, want a check violation", err)
	}
	if err := set("category_path", "coding/none"); err == nil || !strings.Contains(err.Error(), "foreign key") {
		t.Errorf("category coding/none: %v, want the FK violation", err)
	}
	if _, err := pg.asOperator2(ctx, `DELETE FROM activity_categories WHERE category_path = 'coding/hard'`); err == nil {
		t.Error("a category an ask names was deleted")
	} else if !strings.Contains(err.Error(), "foreign key") {
		t.Errorf("delete of a named category: %v, want the FK refusal", err)
	}
}
