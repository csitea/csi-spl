package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Tenant isolation guards (specs/017 FR-SEC-014). Postgres only,
// run by hub-pg.tst.sh in the 10 ci hub job as the plain owner role.
//
// The gate reads the CATALOGUE after every migration, never a hand list: any
// table in the schema with a tenant_id column must have ENABLE + FORCE row
// level security, at least one policy that scopes it to app.tenant_id, and no
// policy that lets a statement without a tenant read a tenant's row or write
// any row. A new table (RBAC, search, keys, M2/M4, ...) that forgets any of
// that turns this red.
//
// One kind of policy is not a tenant statement's policy and is left out: a
// FOR SELECT policy TO roles that are all confined - NOLOGIN, not superuser,
// not BYPASSRLS, and no non-superuser login holds their privileges by
// inheritance (pg_has_role USAGE). Only a SECURITY DEFINER function owned by
// such a role reaches it (rdb 0143, spool_search_reader). A login that
// inherits the role, or a role that can log in, makes it a gap again.

// policyRow is one pg_policies row with its expressions as SQL text.
type policyRow struct {
	name, cmd      string
	permissive     bool
	using, withChk string // "" = absent
	confined       bool   // FOR SELECT TO confined roles only: not a tenant statement's policy
}

// tenantPolicyGaps returns one line per violation. It runs on a FRESH
// connection (so app.tenant_id is truly unset: NULL, not the empty string) inside one
// transaction that is rolled back; setup, when non-nil, runs first in that
// transaction (the CONTROLS add scratch tables there).
func tenantPolicyGaps(ctx context.Context, dsn string, setup func(pgx.Tx) error) ([]string, error) {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, err
	}
	defer conn.Close(ctx)
	tx, err := conn.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if setup != nil {
		if err := setup(tx); err != nil {
			return nil, err
		}
	}

	type table struct {
		name      string
		on, force bool
		policies  []policyRow
	}
	var tables []*table
	rows, err := tx.Query(ctx, `SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
		FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
		WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p')
		ORDER BY 1`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		tb := &table{}
		if err := rows.Scan(&tb.name, &tb.on, &tb.force); err != nil {
			rows.Close()
			return nil, err
		}
		tables = append(tables, tb)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(tables) == 0 {
		return nil, errors.New("no tenant_id table in the schema: the gate would prove nothing")
	}
	for _, tb := range tables {
		prow, err := tx.Query(ctx, `SELECT policyname, cmd, permissive = 'PERMISSIVE',
				COALESCE(qual, ''), COALESCE(with_check, ''),
				cmd = 'SELECT' AND NOT ('public' = ANY (roles)) AND NOT EXISTS (
					SELECT 1 FROM unnest(roles) AS pr (name) JOIN pg_roles g ON g.rolname = pr.name
					WHERE g.rolcanlogin OR g.rolsuper OR g.rolbypassrls
					   OR EXISTS (SELECT 1 FROM pg_roles l WHERE l.rolcanlogin AND NOT l.rolsuper
					              AND l.oid <> g.oid AND pg_has_role(l.oid, g.oid, 'USAGE')))
			FROM pg_policies WHERE schemaname = current_schema() AND tablename = $1 ORDER BY 1`, tb.name)
		if err != nil {
			return nil, err
		}
		for prow.Next() {
			var p policyRow
			if err := prow.Scan(&p.name, &p.cmd, &p.permissive, &p.using, &p.withChk, &p.confined); err != nil {
				prow.Close()
				return nil, err
			}
			tb.policies = append(tb.policies, p)
		}
		prow.Close()
		if err := prow.Err(); err != nil {
			return nil, err
		}
	}

	// eval evaluates expr for one synthetic row of tb (tenant_id = tenant, or
	// NULL when tenant is nil) under the current settings. An error is not
	// read as "not TRUE": it is returned, and becomes a gap.
	eval := func(tb, expr string, tenant *string) (bool, error) {
		row := `{"tenant_id": null}`
		if tenant != nil {
			row = fmt.Sprintf(`{"tenant_id": %q}`, *tenant)
		}
		id := pgx.Identifier{tb}.Sanitize()
		var ok bool
		sp, err := tx.Begin(ctx) // savepoint: a failed expression must not abort the gate
		if err != nil {
			return false, err
		}
		err = sp.QueryRow(ctx, `SELECT COALESCE((`+expr+`), false) FROM (SELECT (jsonb_populate_record(NULL::`+id+`, $1::jsonb)).*) AS `+id, row).Scan(&ok)
		if err != nil {
			sp.Rollback(ctx) //nolint:errcheck
			return false, err
		}
		return ok, sp.Commit(ctx)
	}
	checkExpr := func(p policyRow) string { // what a write is checked against
		switch {
		case p.withChk != "":
			return p.withChk
		case p.cmd == "ALL" || p.cmd == "UPDATE":
			return p.using
		}
		return ""
	}
	str := func(s string) *string { return &s }

	var gaps []string
	// 1. No tenant: the setting unset (NULL), then set to '' (what a pooled
	// connection reads after any earlier transaction-local set_config).
	for _, phase := range []string{"unset", "empty"} {
		if phase == "empty" {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', '', true), set_config('app.rls_scope', '', true)`); err != nil {
				return nil, err
			}
		}
		for _, tb := range tables {
			for _, p := range tb.policies {
				if !p.permissive || p.confined {
					continue // a restrictive policy only narrows; a confined one is no tenant statement's
				}
				if p.using != "" {
					for _, tn := range []*string{str(""), str("t-gate-x"), nil} {
						ok, err := eval(tb.name, p.using, tn)
						if err != nil {
							gaps = append(gaps, fmt.Sprintf("%s.%s: USING does not evaluate: %v", tb.name, p.name, err))
							break
						}
						if !ok {
							continue
						}
						if tn == nil && p.cmd == "SELECT" {
							continue // a hub-wide catalogue row (tenant_id NULL) may be readable
						}
						gaps = append(gaps, fmt.Sprintf("%s.%s: tenant %s: USING is TRUE for a row with tenant_id %s (%s)", tb.name, p.name, phase, show(tn), p.using))
					}
				}
				if ce := checkExpr(p); ce != "" {
					for _, tn := range []*string{str(""), str("t-gate-x"), nil} {
						ok, err := eval(tb.name, ce, tn)
						if err != nil {
							gaps = append(gaps, fmt.Sprintf("%s.%s: WITH CHECK does not evaluate: %v", tb.name, p.name, err))
							break
						}
						if ok {
							gaps = append(gaps, fmt.Sprintf("%s.%s: tenant %s: a write of tenant_id %s passes (%s)", tb.name, p.name, phase, show(tn), ce))
						}
					}
				}
			}
		}
	}
	// 2. With a tenant: some policy lets tenant t-gate-x read and write its own
	// row, and none lets it read or write t-gate-y's.
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', 't-gate-x', true)`); err != nil {
		return nil, err
	}
	for _, tb := range tables {
		if !tb.on || !tb.force {
			gaps = append(gaps, fmt.Sprintf("%s: carries tenant_id but row security is enable=%v force=%v", tb.name, tb.on, tb.force))
		}
		var reads, writes bool
		for _, p := range tb.policies {
			if !p.permissive || p.confined {
				continue
			}
			if p.using != "" && (p.cmd == "ALL" || p.cmd == "SELECT") {
				own, err := eval(tb.name, p.using, str("t-gate-x"))
				if err != nil {
					gaps = append(gaps, fmt.Sprintf("%s.%s: USING does not evaluate: %v", tb.name, p.name, err))
					continue
				}
				reads = reads || own
				if other, _ := eval(tb.name, p.using, str("t-gate-y")); other {
					gaps = append(gaps, fmt.Sprintf("%s.%s: tenant t-gate-x reads a t-gate-y row (%s)", tb.name, p.name, p.using))
				}
			}
			if ce := checkExpr(p); ce != "" && (p.cmd == "ALL" || p.cmd == "INSERT") {
				own, err := eval(tb.name, ce, str("t-gate-x"))
				if err != nil {
					continue // reported above
				}
				writes = writes || own
				if other, _ := eval(tb.name, ce, str("t-gate-y")); other {
					gaps = append(gaps, fmt.Sprintf("%s.%s: tenant t-gate-x writes a t-gate-y row (%s)", tb.name, p.name, ce))
				}
			}
		}
		if !reads || !writes {
			gaps = append(gaps, fmt.Sprintf("%s: no tenant policy on app.tenant_id (tenant reads own=%v, writes own=%v; policies %d)", tb.name, reads, writes, len(tb.policies)))
		}
	}
	return gaps, nil
}

func show(s *string) string {
	if s == nil {
		return "NULL"
	}
	return fmt.Sprintf("%q", *s)
}

// TestRLSPoliciesFailClosed is guard 1 + the database half of guard 2: the
// migrated schema has no gap.
func TestRLSPoliciesFailClosed(t *testing.T) {
	rlsStore(t)
	gaps, err := tenantPolicyGaps(context.Background(), os.Getenv("SPOOL_TEST_PG_DSN"), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, g := range gaps {
		t.Error(g)
	}
}

// TestRLSGateControl: the gate goes red for each way a new tenant table can
// ship unprotected, and for the 0014 policy form that an empty setting matched.
func TestRLSGateControl(t *testing.T) {
	rlsStore(t)
	ctx := context.Background()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	cases := []struct {
		name, ddl, want string
	}{
		{"no RLS", `CREATE TABLE scratch_gate (tenant_id text NOT NULL)`,
			"scratch_gate: carries tenant_id but row security is enable=false force=false"},
		{"ENABLE without FORCE", `CREATE TABLE scratch_gate (tenant_id text NOT NULL);
			ALTER TABLE scratch_gate ENABLE ROW LEVEL SECURITY;
			CREATE POLICY tenant_scope ON scratch_gate USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))`,
			"force=false"},
		{"FORCE, no policy", `CREATE TABLE scratch_gate (tenant_id text NOT NULL);
			ALTER TABLE scratch_gate ENABLE ROW LEVEL SECURITY; ALTER TABLE scratch_gate FORCE ROW LEVEL SECURITY`,
			"scratch_gate: no tenant policy"},
		{"0014 form matches ''", `CREATE TABLE scratch_gate (tenant_id text NOT NULL);
			ALTER TABLE scratch_gate ENABLE ROW LEVEL SECURITY; ALTER TABLE scratch_gate FORCE ROW LEVEL SECURITY;
			CREATE POLICY tenant_scope ON scratch_gate USING (tenant_id = current_setting('app.tenant_id', true))`,
			`tenant empty: USING is TRUE for a row with tenant_id ""`},
		{"NULL means all", `CREATE TABLE scratch_gate (tenant_id text NOT NULL);
			ALTER TABLE scratch_gate ENABLE ROW LEVEL SECURITY; ALTER TABLE scratch_gate FORCE ROW LEVEL SECURITY;
			CREATE POLICY tenant_scope ON scratch_gate USING (current_setting('app.tenant_id', true) IS NULL OR tenant_id = current_setting('app.tenant_id', true))`,
			`tenant unset: USING is TRUE for a row with tenant_id "t-gate-x"`},
		{"cross-tenant policy", `CREATE TABLE scratch_gate (tenant_id text NOT NULL);
			ALTER TABLE scratch_gate ENABLE ROW LEVEL SECURITY; ALTER TABLE scratch_gate FORCE ROW LEVEL SECURITY;
			CREATE POLICY tenant_scope ON scratch_gate USING (tenant_id IS NOT NULL AND current_setting('app.tenant_id', true) <> '')`,
			"tenant t-gate-x reads a t-gate-y row"},
		// rdb 0143's shape, made unsafe: USING (true) TO a role that can log
		// in, or TO a NOLOGIN role a login inherits, is a gap.
		{"USING (true) TO a login", goodGate + `;
			CREATE ROLE scratch_gate_login LOGIN;
			CREATE POLICY wide ON scratch_gate FOR SELECT TO scratch_gate_login USING (true)`,
			`scratch_gate.wide: tenant unset: USING is TRUE for a row with tenant_id ""`},
		{"USING (true) TO an inherited role", goodGate + `;
			CREATE ROLE scratch_gate_reader NOLOGIN;
			CREATE ROLE scratch_gate_login LOGIN IN ROLE scratch_gate_reader;
			CREATE POLICY wide ON scratch_gate FOR SELECT TO scratch_gate_reader USING (true)`,
			`scratch_gate.wide: tenant unset: USING is TRUE for a row with tenant_id ""`},
		{"USING (true) FOR ALL TO a confined role", goodGate + `;
			CREATE ROLE scratch_gate_reader NOLOGIN;
			CREATE POLICY wide ON scratch_gate TO scratch_gate_reader USING (true)`,
			`scratch_gate.wide: tenant unset: USING is TRUE for a row with tenant_id ""`},
	}
	for _, c := range cases {
		gaps, err := tenantPolicyGaps(ctx, dsn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, c.ddl)
			return err
		})
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if !strings.Contains(strings.Join(gaps, "\n"), c.want) {
			t.Errorf("CONTROL %s: the gate did not report %q; gaps: %q", c.name, c.want, gaps)
		}
	}
	// And the good forms pass: the gate is not red for everything. The second
	// is rdb 0143's: FOR SELECT USING (true) TO a confined NOLOGIN role.
	for _, ddl := range []string{goodGate, goodGate + `;
		CREATE ROLE scratch_gate_reader NOLOGIN;
		CREATE POLICY wide ON scratch_gate FOR SELECT TO scratch_gate_reader USING (true)`} {
		gaps, err := tenantPolicyGaps(ctx, dsn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, ddl)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		for _, g := range gaps {
			if strings.Contains(g, "scratch_gate") {
				t.Errorf("a correctly protected table was reported: %s", g)
			}
		}
	}
}

// goodGate is a correctly protected scratch tenant table.
const goodGate = `CREATE TABLE scratch_gate (tenant_id text NOT NULL);
	ALTER TABLE scratch_gate ENABLE ROW LEVEL SECURITY; ALTER TABLE scratch_gate FORCE ROW LEVEL SECURITY;
	CREATE POLICY tenant_scope ON scratch_gate USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
		WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))`

// TestRLSEmptySettingControl: on real rows, the 0014 form leaks a tenant_id
// empty-string row to a statement whose setting is empty and the 0021 form does not.
func TestRLSEmptySettingControl(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	for _, q := range []string{
		`CREATE TABLE scratch_empty (tenant_id text NOT NULL)`,
		`INSERT INTO scratch_empty VALUES (''), ('t-a')`,
		`ALTER TABLE scratch_empty ENABLE ROW LEVEL SECURITY`,
		`ALTER TABLE scratch_empty FORCE ROW LEVEL SECURITY`,
		`CREATE POLICY tenant_scope ON scratch_empty USING (tenant_id = current_setting('app.tenant_id', true))`,
		`SELECT set_config('app.tenant_id', '', true)`,
	} {
		if _, err := tx.Exec(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	count := func() int {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM scratch_empty`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := count(); n != 1 {
		t.Fatalf("control is void: the 0014 form should leak the '' row to an empty setting, saw %d", n)
	}
	if _, err := tx.Exec(ctx, `ALTER POLICY tenant_scope ON scratch_empty USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))`); err != nil {
		t.Fatal(err)
	}
	if n := count(); n != 0 {
		t.Fatalf("the 0021 form shows %d row(s) to an empty setting, want 0", n)
	}
}

// TestRLSStoreRefusesNoTenant is the store half of guard 2: a tenant-scoped
// call without a tenant is ErrNoTenant (never all rows, never a silent empty
// answer), and it never reaches Postgres.
func TestRLSStoreRefusesNoTenant(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	rlsTenant(t, pg) // rows exist, so "empty" would be a lie, not a no-op
	for _, tenant := range []string{"", " ", "\t"} {
		if err := pg.inTenant(ctx, tenant, func(pgx.Tx) error {
			t.Fatalf("inTenant(%q) ran its body", tenant)
			return nil
		}); !errors.Is(err, ErrNoTenant) {
			t.Errorf("inTenant(%q): %v, want ErrNoTenant", tenant, err)
		}
		if _, err := pg.execTenant(ctx, tenant, `DELETE FROM messages`); !errors.Is(err, ErrNoTenant) {
			t.Errorf("execTenant(%q): %v, want ErrNoTenant", tenant, err)
		}
		var n int
		if err := pg.queryRowTenant(ctx, tenant, `SELECT count(*) FROM messages`, nil, &n); !errors.Is(err, ErrNoTenant) {
			t.Errorf("queryRowTenant(%q): %v, want ErrNoTenant", tenant, err)
		}
		if _, err := pg.Roster(ctx, tenant); !errors.Is(err, ErrNoTenant) {
			t.Errorf("Roster(%q): %v, want ErrNoTenant (public API)", tenant, err)
		}
	}
	// CONTROL: the same batch path WITH a tenant runs.
	var n int
	if err := pg.queryRowTenant(ctx, "t-none-such", `SELECT count(*) FROM messages`, nil, &n); err != nil || n != 0 {
		t.Fatalf("control: a named tenant must run (0 rows): %d %v", n, err)
	}
}

// TestRLSHubRoleCannotLiftRLS: the role the hub connects as must not be able
// to switch row level security off, or become a role that can. It is the
// Cloud SQL shape when the hub login is NOT the table owner; see
// hubRoleCanLiftRLS for what is checked.
func TestRLSHubRoleCannotLiftRLS(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_RUNTIME_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_RUNTIME_DSN unset (hub-pg.tst.sh sets it to the runtime role)")
	}
	pg := rlsStore(t) // migrates as the owner
	ctx := context.Background()
	rt, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Close()
	why, err := rt.HubRoleCanLiftRLS(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(why) > 0 {
		t.Fatalf("runtime role can lift RLS: %v", why)
	}
	// CONTROL: the owner role can (it owns the tables), so the check is live.
	why, err = pg.HubRoleCanLiftRLS(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(why) == 0 {
		t.Fatal("control is void: the owner role should be reported as able to lift RLS")
	}
	// And the behaviour behind it: ALTER from the runtime role is refused.
	if _, err := rt.pool.Exec(ctx, `ALTER TABLE messages NO FORCE ROW LEVEL SECURITY`); err == nil {
		t.Fatal("runtime role altered row security on messages")
	}
}
