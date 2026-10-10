package store

import (
	"context"
	"errors"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/jackc/pgx/v5"
)

// Spec 123 lane 1 (sections 4.1, 4.4, 5.1): rdb 0166's cost_lines and
// cost_coverage under row level security, the natural key the readers
// UPSERT on, the supersede order of a hand edit, and costs.read.
// rls_failclosed_test.go's catalogue gate covers the policies' shape and
// TestCrossTenantEveryTable the unscoped writes (crosstenant_test.go seeds
// one cost_lines row per tenant); this file proves what each scope reads and
// may write. Postgres only (SPOOL_TEST_PG_DSN).

// costLineInsert writes one cost line; $1 is tenant_id (NULL = estate),
// $2 the day, $3 the origin, $4 the project (estate rows are shared by every
// test on the database, so each test names its own).
const costLineInsert = `INSERT INTO cost_lines (day, source, project_or_vendor, tenant_id, kind, units,
	amount_micros, currency, usd_micros, eur_micros, fx_rate_day, origin, run_id)
	VALUES ($2::date, 'gcp', $4, $1, 'cloud_run', 1, 1000000, 'USD', 1000000, 920000, $2::date, $3, 'run-1')`

// seedCostLine writes one cost line for tenant under the tenant's own scope
// (the runtime path: RLS WITH CHECK admits it).
func seedCostLine(ctx context.Context, pg *Postgres, tenant, day, origin string) error {
	_, err := pg.execTenant(ctx, tenant, costLineInsert, tenant, day, origin, "csi-spl-dev")
	return err
}

// costCount counts the cost_lines rows of tenant ("" = the estate rows) in
// one fresh transaction under scope: "tenant:<id>", "operator", "empty"
// (app.tenant_id = the empty string) or "none".
func costCount(t *testing.T, pg *Postgres, scope, tenant string) int {
	t.Helper()
	ctx := context.Background()
	n := -1
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
		switch {
		case scope == "operator":
			_, err = tx.Exec(ctx, pgScopeOperator)
		case scope == "empty":
			_, err = tx.Exec(ctx, pgScopeTenant, "")
		case len(scope) > 7 && scope[:7] == "tenant:":
			_, err = tx.Exec(ctx, pgScopeTenant, scope[7:])
		}
		if err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT count(*) FROM cost_lines WHERE tenant_id IS NOT DISTINCT FROM NULLIF($1, '')`, tenant).Scan(&n)
	})
	if err != nil {
		t.Fatalf("%s: %v", scope, err)
	}
	return n
}

// seedEstateLine writes one estate row (tenant_id NULL) for project as the operator.
func seedEstateLine(t *testing.T, pg *Postgres, day, project string) {
	t.Helper()
	ctx := context.Background()
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, costLineInsert, nil, day, "billing_export", project)
		return err
	}); err != nil {
		t.Fatal(err)
	}
}

// TestRLSCostLinesScopes: workspace A cannot read workspace B's cost rows;
// no workspace reads an estate row; an empty scope and no scope read
// nothing (fail-closed); the operator reads them all. B's scope cannot write
// an A row nor an estate row (WITH CHECK, 42501), and its UPDATE / DELETE of
// A's rows touch none. A tenant delete takes its rows with it. CONTROL: with
// FORCE lifted (rolled back) the owner reads A's row under B's scope, so the
// zeros above are the policy's.
func TestRLSCostLinesScopes(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	if err := seedCostLine(ctx, pg, a, "2026-10-02", "metered"); err != nil {
		t.Fatal(err)
	}
	if err := seedCostLine(ctx, pg, b, "2026-10-02", "metered"); err != nil { // B's own row: admitted
		t.Fatal(err)
	}
	seedEstateLine(t, pg, "2026-10-02", uid("p-"))
	for _, c := range []struct {
		scope, of string
		want      int
	}{
		{"tenant:" + b, a, 0}, {"empty", a, 0}, {"none", a, 0}, {"tenant:" + a, a, 1}, {"operator", a, 1},
		{"tenant:" + a, "", 0}, {"tenant:" + b, "", 0}, {"empty", "", 0}, {"none", "", 0},
	} {
		if got := costCount(t, pg, c.scope, c.of); got != c.want {
			t.Errorf("scope %s reads %d rows of %q, want %d", c.scope, got, c.of, c.want)
		}
	}
	if got := costCount(t, pg, "operator", ""); got < 1 {
		t.Errorf("CONTROL: the operator reads %d estate rows, want >= 1", got)
	}
	if _, err := pg.execTenant(ctx, b, costLineInsert, a, "2026-10-03", "hand", "csi-spl-dev"); pgCode(err) != "42501" {
		t.Errorf("an A row written under B's scope: %v (want WITH CHECK, 42501)", err)
	}
	if _, err := pg.execTenant(ctx, b, costLineInsert, nil, "2026-10-03", "hand", "csi-spl-dev"); pgCode(err) != "42501" {
		t.Errorf("an estate row written under B's scope: %v (want WITH CHECK, 42501)", err)
	}
	for _, w := range []string{`UPDATE cost_lines SET usd_micros = 0 WHERE tenant_id = $1`, `DELETE FROM cost_lines WHERE tenant_id = $1`} {
		tag, err := pg.execTenant(ctx, b, w, a)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("B's scope reached %d of A's rows: %s (%v)", tag.RowsAffected(), w, err)
		}
	}
	tag, err := pg.execTenant(ctx, b, `UPDATE cost_lines SET usd_micros = 0 WHERE tenant_id IS NULL`)
	if err != nil || tag.RowsAffected() != 0 {
		t.Errorf("B's scope reached %d estate rows (%v)", tag.RowsAffected(), err)
	}
	if got := costCount(t, pg, "operator", a); got != 1 {
		t.Fatalf("after B's writes A holds %d rows, want 1", got)
	}
	var lifted int
	err = pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		for _, q := range []string{`ALTER TABLE cost_lines NO FORCE ROW LEVEL SECURITY`, `SELECT set_config('app.tenant_id', '` + b + `', true)`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM cost_lines WHERE tenant_id = $1`, a).Scan(&lifted); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) || lifted != 1 {
		t.Fatalf("CONTROL: without FORCE the owner read %d of A's rows under B's scope (%v), want 1", lifted, err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, a)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if got := costCount(t, pg, "operator", a); got != 0 {
		t.Fatalf("after the tenant delete A holds %d cost rows", got)
	}
}

// TestCostsReadGate (spec 123 section 5.1, owner Q-1 = A): a member's cost
// read is the hub's costs.read check (the rbac authorizer over the MIGRATED
// grant rows) followed by the workspace-scoped read. A developer of A reads 0
// rows; A's biz_owner and admin read A's row and none of B's. CONTROL: the
// same read without the permission check returns the developer A's row, so
// the developer's 0 is the grant's.
func TestCostsReadGate(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	for _, tn := range []string{a, b} {
		if err := seedCostLine(ctx, pg, tn, "2026-10-04", "transcript"); err != nil {
			t.Fatal(err)
		}
	}
	z := &rbac.Authorizer{Src: RBACSource{H: pg}}
	read := func(hum, tenant string, gate bool) int {
		if gate && !z.Can(ctx, hum, tenant, rbac.CostsRead) {
			return 0
		}
		return costCount(t, pg, "tenant:"+tenant, tenant)
	}
	for _, c := range []struct {
		role string
		want int
	}{{rbac.BizOwner, 1}, {rbac.Admin, 1}, {rbac.Developer, 0}, {rbac.ProductOwner, 0}, {rbac.Tester, 0}} {
		hum := admitAs(t, pg, a, c.role)
		if got := read(hum, a, true); got != c.want {
			t.Errorf("%s of A reads %d cost rows, want %d", c.role, got, c.want)
		}
		if got := read(hum, b, true); got != 0 {
			t.Errorf("%s of A reads %d of B's cost rows, want 0", c.role, got)
		}
		if c.role == rbac.Developer {
			if got := read(hum, a, false); got != 1 {
				t.Errorf("CONTROL: ungated, the developer's workspace scope reads %d rows, want 1", got)
			}
		}
	}
}

// TestCostLinesKeyAndSupersede: the natural key collides with NULL agent,
// model and tenant (NULLS NOT DISTINCT), so a re-read UPSERTs one row; the
// origin and currency CHECKs refuse (23514); a hand edit supersedes the old
// row in one transaction (the deferred FK) and leaves two rows, one live; a
// superseded_by that names no row fails at commit (23503).
func TestCostLinesKeyAndSupersede(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	day, prj := "2026-10-05", uid("p-")
	upsert := costLineInsert + ` ON CONFLICT (day, source, project_or_vendor, tenant_id, agent_id, model, kind)
		WHERE superseded_by IS NULL DO UPDATE SET usd_micros = cost_lines.usd_micros + 1`
	op := func(f func(tx pgx.Tx) error) error { return pg.asOperator(ctx, f) }
	for i := 0; i < 3; i++ {
		if err := op(func(tx pgx.Tx) error { _, err := tx.Exec(ctx, upsert, nil, day, "billing_export", prj); return err }); err != nil {
			t.Fatalf("upsert %d: %v", i, err)
		}
	}
	var n int
	var usd int64
	if err := op(func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*), max(usd_micros) FROM cost_lines WHERE project_or_vendor = $1`, prj).Scan(&n, &usd)
	}); err != nil || n != 1 || usd != 1000002 {
		t.Fatalf("three upserts left %d row(s), usd %d (%v); want 1, 1000002", n, usd, err)
	}
	for _, c := range []struct{ name, sql string }{
		{"origin", `INSERT INTO cost_lines (day, source, project_or_vendor, kind, amount_micros, currency, usd_micros, eur_micros, fx_rate_day, origin, run_id)
			VALUES ('2026-10-06', 'gcp', 'p', 'k', 1, 'USD', 1, 1, '2026-10-06', 'guess', 'r')`},
		{"currency", `INSERT INTO cost_lines (day, source, project_or_vendor, kind, amount_micros, currency, usd_micros, eur_micros, fx_rate_day, origin, run_id)
			VALUES ('2026-10-06', 'gcp', 'p', 'k', 1, 'usd', 1, 1, '2026-10-06', 'hand', 'r')`},
	} {
		if err := op(func(tx pgx.Tx) error { _, err := tx.Exec(ctx, c.sql); return err }); pgCode(err) != "23514" {
			t.Errorf("%s: %v, want a CHECK refusal (23514)", c.name, err)
		}
	}
	// The hand edit of section 4.4: new id first, retire the old row, insert
	// the new one with that id, all in one transaction.
	if err := op(func(tx pgx.Tx) error {
		var next int64
		if err := tx.QueryRow(ctx, `SELECT nextval(pg_get_serial_sequence('cost_lines', 'id'))`).Scan(&next); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE cost_lines SET superseded_by = $2 WHERE project_or_vendor = $1 AND superseded_by IS NULL`, prj, next); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO cost_lines (id, day, source, project_or_vendor, kind, units, amount_micros, currency,
			usd_micros, eur_micros, fx_rate_day, origin, run_id)
			VALUES ($2, $1::date, 'gcp', $3, 'cloud_run', 1, 5, 'USD', 5, 4, $1::date, 'hand', 'edit-1')`, day, next, prj)
		return err
	}); err != nil {
		t.Fatalf("supersede: %v", err)
	}
	var live, all int
	if err := op(func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE superseded_by IS NULL), count(*) FROM cost_lines WHERE project_or_vendor = $1`, prj).Scan(&live, &all)
	}); err != nil || live != 1 || all != 2 {
		t.Fatalf("after the edit: %d live of %d (%v); want 1 of 2", live, all, err)
	}
	if err := op(func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE cost_lines SET superseded_by = -1 WHERE project_or_vendor = $1 AND superseded_by IS NULL`, prj)
		return err
	}); pgCode(err) != "23503" {
		t.Fatalf("a superseded_by naming no row: %v, want 23503 at commit", err)
	}
}

// TestCostCoverage: a workspace scope reads the coverage rows but cannot
// write one (42501); no scope and an empty scope read none; the operator
// writes them; missing and partial need a reason (23514), ok does not; one
// row per (day, source) (23505).
func TestCostCoverage(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	day, sfx := "2026-10-07", uid(".")
	ins := `INSERT INTO cost_coverage (day, source, state, reason, run_id) VALUES ($1::date, $2, $3, NULLIF($4, ''), 'run-1')`
	op := func(src, state, reason string) error {
		return pg.asOperator(ctx, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, ins, day, src+sfx, state, reason); return err })
	}
	for _, c := range []struct {
		src, state, reason, code string
	}{
		{"gcp", "ok", "", ""}, {"transcript", "missing", "box sat did not post its day file", ""},
		{"agent_run", "partial", "", "23514"}, {"metered", "missing", "  ", "23514"}, {"hand", "late", "x", "23514"},
		{"gcp", "partial", "again", "23505"},
	} {
		if err := op(c.src, c.state, c.reason); pgCode(err) != c.code && !(c.code == "" && err == nil) {
			t.Errorf("%s %s %q: %v, want %q", c.src, c.state, c.reason, err, c.code)
		}
	}
	if _, err := pg.execTenant(ctx, a, ins, day, "invoice"+sfx, "ok", ""); pgCode(err) != "42501" {
		t.Errorf("a workspace scope wrote a coverage row: %v (want 42501)", err)
	}
	count := func(scope string) int {
		n := -1
		if err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
			switch scope {
			case "empty":
				_, err = tx.Exec(ctx, pgScopeTenant, "")
			case "tenant":
				_, err = tx.Exec(ctx, pgScopeTenant, a)
			}
			if err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM cost_coverage WHERE day = $1::date AND source LIKE '%' || $2`, day, sfx).Scan(&n)
		}); err != nil {
			t.Fatalf("%s: %v", scope, err)
		}
		return n
	}
	if got := count("tenant"); got != 2 {
		t.Errorf("a workspace scope reads %d coverage rows, want 2", got)
	}
	for _, s := range []string{"empty", "none"} {
		if got := count(s); got != 0 {
			t.Errorf("scope %s reads %d coverage rows, want 0", s, got)
		}
	}
}
