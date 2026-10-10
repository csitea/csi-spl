package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/119 T001 (spec sections 7.3..7.5, 8.1..8.3, 11): the personal realm's
// DDL (rdb 0168), checked at SQL level with raw set_config, no store code
// (T002 brings inPerson). Postgres only, as the runtime login hub-pg.tst.sh
// hands over (SPOOL_TEST_PG_RUNTIME_DSN). Every check is a function that
// returns its gaps; the plain run wants none and each plant (a rolled-back
// transaction as the migrate login, never committed) wants its own. The
// names start TestRLS, so hub-pg.tst.sh's RLS control counts them. No t.Run:
// that control greps every "--- PASS: TestRLS".

var personalTables = []string{"profile", "settings", "hours_receipts", "receipt_due"}

// personalCatalogueGaps is T-C1..T-C6 plus the two definer roles, read from
// the catalogue. Each query returns a row only when its check fails, naming
// what it found. rt is the runtime login.
func personalCatalogueGaps(ctx context.Context, q rowQuerier, rt string) []string {
	checks := []struct{ what, sql string }{
		{"T-C1 personal holds exactly profile, settings, hours_receipts, receipt_due", `
			SELECT COALESCE(string_agg(c.relname, ',' ORDER BY c.relname), 'none') FROM pg_class c
			WHERE c.relnamespace = 'personal'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
			HAVING string_agg(c.relname, ',' ORDER BY c.relname) IS DISTINCT FROM 'hours_receipts,profile,receipt_due,settings'`},
		{"T-C1 every personal table is ENABLE + FORCE row security", `
			SELECT string_agg(format('%s enable=%s force=%s', relname, relrowsecurity, relforcerowsecurity), '; ') FROM pg_class
			WHERE relnamespace = 'personal'::regnamespace AND relkind IN ('r', 'p') AND NOT (relrowsecurity AND relforcerowsecurity)
			HAVING count(*) > 0`},
		{"T-C1 policies are exactly person_scope per table plus realm_sweeper_read on receipt_due", `
			SELECT COALESCE(string_agg(format('%s.%s', tablename, policyname), ',' ORDER BY tablename, policyname), 'none')
			FROM pg_policies WHERE schemaname = 'personal'
			HAVING string_agg(format('%s.%s', tablename, policyname), ',' ORDER BY tablename, policyname) IS DISTINCT FROM
			       'hours_receipts.person_scope,profile.person_scope,receipt_due.person_scope,receipt_due.realm_sweeper_read,settings.person_scope'`},
		{"T-C1 person_scope is PERMISSIVE ALL TO PUBLIC with the NULLIF person, tenant-unset and not-operator clauses in USING and WITH CHECK", `
			SELECT string_agg(tablename, ',') FROM pg_policies
			WHERE schemaname = 'personal' AND policyname = 'person_scope'
			  AND NOT (permissive = 'PERMISSIVE' AND cmd = 'ALL' AND roles = '{public}'
			       AND qual = with_check
			       AND qual LIKE '%person_id = NULLIF(current_setting(''app.person_id''::text, true), ''''::text)%'
			       AND qual LIKE '%NULLIF(current_setting(''app.tenant_id''::text, true), ''''::text) IS NULL%'
			       AND qual LIKE '%current_setting(''app.rls_scope''::text, true) IS DISTINCT FROM ''operator''::text%')
			HAVING count(*) > 0`},
		{"T-C1 realm_sweeper_read is FOR SELECT TO spool_realm_sweeper on open rows", `
			SELECT format('cmd=%s roles=%s qual=%s', cmd, roles, qual) FROM pg_policies
			WHERE schemaname = 'personal' AND policyname = 'realm_sweeper_read'
			  AND NOT (cmd = 'SELECT' AND roles = '{spool_realm_sweeper}' AND qual = '(done_at IS NULL)')`},
		{"T-C2 no FK from personal to a table outside personal except public.humans", `
			SELECT string_agg(format('%s -> %s', conrelid::regclass, confrelid::regclass), ', ') FROM pg_constraint
			WHERE contype = 'f' AND connamespace = 'personal'::regnamespace
			  AND confrelid <> 'public.humans'::regclass
			  AND (SELECT relnamespace FROM pg_class WHERE oid = confrelid) <> 'personal'::regnamespace
			HAVING count(*) > 0`},
		{"T-C2 every personal table has person_id first with the FK to humans", `
			SELECT string_agg(c.relname, ',') FROM pg_class c
			WHERE c.relnamespace = 'personal'::regnamespace AND c.relkind = 'r'
			  AND NOT (EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum = 1 AND a.attname = 'person_id' AND a.attnotnull)
			       AND EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f'
			                    AND k.confrelid = 'public.humans'::regclass AND k.confdeltype = 'c'))
			HAVING count(*) > 0`},
		{"T-C2 no column named tenant_id in personal", `
			SELECT string_agg(c.relname, ',') FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
			WHERE c.relnamespace = 'personal'::regnamespace AND a.attname = 'tenant_id' AND NOT a.attisdropped
			HAVING count(*) > 0`},
		{"T-C3 the runtime has no UPDATE, DELETE or TRUNCATE on hours_receipts", fmt.Sprintf(`
			SELECT 'has ' || string_agg(p, ',') FROM unnest(ARRAY['UPDATE', 'DELETE', 'TRUNCATE']) p
			WHERE has_table_privilege(%s, 'personal.hours_receipts', p)
			HAVING count(*) > 0`, quoteLit(rt))},
		{"T-C3 no default privileges in personal", `
			SELECT string_agg(format('%s %s', defaclobjtype, defaclacl), '; ') FROM pg_default_acl
			WHERE defaclnamespace = 'personal'::regnamespace HAVING count(*) > 0`},
		{"T-C3 spool_search_reader has no USAGE on personal", `
			SELECT 'usage' WHERE has_schema_privilege('spool_search_reader', 'personal', 'USAGE')`},
		{"T-C4 hours_receipts columns are exactly 8.2's list", `
			SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute
			WHERE attrelid = 'personal.hours_receipts'::regclass AND attnum > 0 AND NOT attisdropped
			HAVING string_agg(attname, ',' ORDER BY attnum) IS DISTINCT FROM
			  'person_id,workspace_id,workspace_name,day,minutes,label,kind,period_start,period_end,approval_state,approver_name,decided_at,rev,copied_at'`},
		{"T-C5 profile columns are exactly 7.3's (no name column)", `
			SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute
			WHERE attrelid = 'personal.profile'::regclass AND attnum > 0 AND NOT attisdropped
			HAVING string_agg(attname, ',' ORDER BY attnum) IS DISTINCT FROM 'person_id,time_zone,locale,comm_prefs,updated_at'`},
		{"T-C6 the runtime's UPDATE in personal is profile, settings, receipt_due; DELETE profile, settings", fmt.Sprintf(`
			SELECT string_agg(format('%%s %%s', p, c.relname), ', ' ORDER BY p, c.relname) FROM pg_class c,
			       unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
			WHERE c.relnamespace = 'personal'::regnamespace AND c.relkind = 'r'
			  AND has_table_privilege(%s, c.oid, p)
			HAVING string_agg(format('%%s %%s', p, c.relname), ', ' ORDER BY p, c.relname) IS DISTINCT FROM
			  'DELETE profile, DELETE settings, INSERT hours_receipts, INSERT profile, INSERT receipt_due, INSERT settings, SELECT hours_receipts, SELECT profile, SELECT receipt_due, SELECT settings, UPDATE profile, UPDATE receipt_due, UPDATE settings'`, quoteLit(rt))},
		{"T-C6 the only function deleting from hours_receipts is personal.delete_my_receipts", `
			SELECT string_agg(oid::regprocedure::text, ', ') FROM pg_proc
			WHERE prosrc ~* 'delete\s+from\s+(personal\.)?hours_receipts'
			  AND oid <> 'personal.delete_my_receipts(text)'::regprocedure
			HAVING count(*) > 0`},
		{"T-C6 the runtime can EXECUTE both realm definers, PUBLIC neither", fmt.Sprintf(`
			SELECT string_agg(oid::regprocedure::text, ', ') FROM pg_proc
			WHERE oid IN ('personal.delete_my_receipts(text)'::regprocedure, 'personal.due_receipts(timestamptz)'::regprocedure)
			  AND (NOT has_function_privilege(%s, oid, 'EXECUTE')
			       OR EXISTS (SELECT 1 FROM aclexplode(proacl) a WHERE a.grantee = 0))
			HAVING count(*) > 0`, quoteLit(rt))},
		{"the two realm roles are NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE", `
			SELECT string_agg(rolname, ',') FROM pg_roles
			WHERE rolname IN ('spool_realm_sweeper', 'spool_realm_eraser')
			  AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)
			HAVING count(*) > 0`},
		{"each realm role owns exactly its one SECURITY DEFINER function with search_path pg_catalog, pg_temp", `
			SELECT COALESCE(string_agg(format('%s owner=%s definer=%s config=%s', p.oid::regprocedure, pg_get_userbyid(p.proowner),
			                                  p.prosecdef, p.proconfig), '; '), 'none')
			FROM pg_proc p WHERE p.proowner IN ('spool_realm_sweeper'::regrole, 'spool_realm_eraser'::regrole)
			   OR p.pronamespace = 'personal'::regnamespace
			HAVING count(*) <> 2 OR bool_or(NOT p.prosecdef OR p.proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog, pg_temp']
			    OR NOT ((p.oid = 'personal.due_receipts(timestamptz)'::regprocedure AND p.proowner = 'spool_realm_sweeper'::regrole)
			         OR (p.oid = 'personal.delete_my_receipts(text)'::regprocedure AND p.proowner = 'spool_realm_eraser'::regrole)))`},
		{"no login holds a realm role's privileges", `
			SELECT string_agg(format('%s via %s', l.rolname, r.rolname), ', ') FROM pg_roles l, pg_roles r
			WHERE l.rolcanlogin AND NOT l.rolsuper AND r.rolname IN ('spool_realm_sweeper', 'spool_realm_eraser')
			  AND l.oid <> r.oid AND pg_has_role(l.oid, r.oid, 'USAGE')
			HAVING count(*) > 0`},
		{"T-R7 due_receipts returns only (person_id, workspace_id)", `
			SELECT format('%s %s', array_to_string(proargnames, ','), array_to_string(proargmodes, ',')) FROM pg_proc
			WHERE oid = 'personal.due_receipts(timestamptz)'::regprocedure
			  AND array_to_string(proargnames, ',') || '/' || array_to_string(proargmodes, ',') IS DISTINCT FROM 'now,person_id,workspace_id/i,t,t'`},
		{"T-R7 spool_realm_sweeper holds no grant on profile, settings, hours_receipts", `
			SELECT string_agg(format('%s %s', p, t), ', ') FROM unnest(ARRAY['personal.profile', 'personal.settings', 'personal.hours_receipts']) t,
			       unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
			WHERE has_table_privilege('spool_realm_sweeper', t, p)
			   OR (p <> 'DELETE' AND has_any_column_privilege('spool_realm_sweeper', t, p))
			HAVING count(*) > 0`},
	}
	var gaps []string
	for _, c := range checks {
		var bad *string
		err := q.QueryRow(ctx, c.sql).Scan(&bad)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
		case err != nil:
			gaps = append(gaps, fmt.Sprintf("%s: %v", c.what, err))
		default:
			gaps = append(gaps, fmt.Sprintf("%s: found %s", c.what, show(bad)))
		}
	}
	return gaps
}

func quoteLit(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// TestRLSPersonalCatalogue is T-C1..T-C6 and T-R7's catalogue half. CONTROL:
// each plant, in a rolled-back transaction as the migrate login, turns its
// own check(s) red ("|" separates two, in check order) and no other.
func TestRLSPersonalCatalogue(t *testing.T) {
	pg := rlsStore(t)
	_, rt := runtimeSession(t)
	ctx := context.Background()
	for _, g := range personalCatalogueGaps(ctx, pg.pool, rt) {
		t.Error(g)
	}
	rtID := pgx.Identifier{rt}.Sanitize()
	plants := []struct {
		name, want string
		sql        []string
	}{
		{"a table without FORCE", "ENABLE + FORCE", []string{`ALTER TABLE personal.settings NO FORCE ROW LEVEL SECURITY`}},
		{"an operator_scope policy", "policies are exactly", []string{
			`CREATE POLICY operator_scope ON personal.profile USING (current_setting('app.rls_scope', true) = 'operator')`}},
		{"person_scope without the tenant clause", "tenant-unset", []string{
			`DROP POLICY person_scope ON personal.profile`,
			`CREATE POLICY person_scope ON personal.profile
				USING (person_id = NULLIF(current_setting('app.person_id', true), '')
				       AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
				WITH CHECK (person_id = NULLIF(current_setting('app.person_id', true), '')
				       AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')`}},
		{"person_scope without the NULLIF", "tenant-unset", []string{
			`DROP POLICY person_scope ON personal.settings`,
			`CREATE POLICY person_scope ON personal.settings
				USING (person_id = current_setting('app.person_id', true)
				       AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
				       AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
				WITH CHECK (person_id = current_setting('app.person_id', true)
				       AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
				       AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')`}},
		{"an FK to tenants", "no FK from personal", []string{
			`ALTER TABLE personal.receipt_due ADD CONSTRAINT planted_fk FOREIGN KEY (workspace_id) REFERENCES public.tenants (tenant_id)`}},
		{"UPDATE on hours_receipts for the runtime", "no UPDATE, DELETE|the runtime's UPDATE in personal", []string{
			`GRANT UPDATE ON personal.hours_receipts TO ` + rtID}},
		{"a default privilege in personal", "no default privileges", []string{
			`ALTER DEFAULT PRIVILEGES IN SCHEMA personal GRANT SELECT ON TABLES TO ` + rtID}},
		{"USAGE for spool_search_reader", "spool_search_reader", []string{
			`GRANT USAGE ON SCHEMA personal TO spool_search_reader`}},
		{"a note column on hours_receipts", "8.2's list", []string{`ALTER TABLE personal.hours_receipts ADD COLUMN note text`}},
		{"a display_name column on profile", "7.3's", []string{`ALTER TABLE personal.profile ADD COLUMN display_name text`}},
		{"a second deleter of hours_receipts", "the only function deleting", []string{
			`CREATE FUNCTION public.planted_delete() RETURNS void LANGUAGE sql AS 'DELETE FROM personal.hours_receipts'`}},
		{"the sweeper may log in", "NOLOGIN", []string{`ALTER ROLE spool_realm_sweeper LOGIN`}},
		{"the sweeper reads profile", "T-R7 spool_realm_sweeper holds no grant", []string{
			`GRANT SELECT (person_id) ON personal.profile TO spool_realm_sweeper`}},
	}
	for _, p := range plants {
		func() {
			tx, err := pg.pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(ctx) //nolint:errcheck
			for _, q := range p.sql {
				if _, err := tx.Exec(ctx, q); err != nil {
					t.Fatalf("plant %s: %s: %v", p.name, q, err)
				}
			}
			gaps := personalCatalogueGaps(ctx, tx, rt)
			want := strings.Split(p.want, "|")
			ok := len(gaps) == len(want)
			for i := 0; ok && i < len(want); i++ {
				ok = strings.Contains(gaps[i], want[i])
			}
			if !ok {
				t.Errorf("plant %s: want exactly the %q check(s) red, got %d: %v", p.name, want, len(gaps), gaps)
			}
		}()
	}
}

// realmSeed is two persons P and Q, each with a row in every personal table:
// receipts of workspaces W1 (rev 0 and 1) and W2, both receipt_due rows open,
// plus one closed receipt_due row of W3.
type realmSeed struct{ p, q, w1, w2, w3 string }

// scope sets the three settings transaction-locally; "" leaves one empty.
func scope(ctx context.Context, tx pgx.Tx, person, tenant, rls string) error {
	_, err := tx.Exec(ctx, `SELECT set_config('app.person_id', $1, true), set_config('app.tenant_id', $2, true),
		set_config('app.rls_scope', $3, true)`, person, tenant, rls)
	return err
}

// inSavepoint runs fn in a savepoint of tx and always rolls it back.
func inSavepoint(ctx context.Context, tx pgx.Tx, fn func(sp pgx.Tx) error) error {
	sp, err := tx.Begin(ctx)
	if err != nil {
		return err
	}
	defer sp.Rollback(ctx) //nolint:errcheck
	return fn(sp)
}

// seedRealm opens a rolled-back transaction as the migrate login, runs the
// plants, seeds P and Q through the person scope (FORCE binds the owner
// too), and checks T-N6 there: the owner without the setting reads 0 rows.
// It then hands the transaction to the runtime login.
func seedRealm(t *testing.T, pg *Postgres, rt string, plants ...string) (pgx.Tx, realmSeed) {
	t.Helper()
	ctx := context.Background()
	tx := ownerTx(t, pg)
	for _, q := range plants {
		if _, err := tx.Exec(ctx, q); err != nil {
			t.Fatalf("plant: %s: %v", q, err)
		}
	}
	n := time.Now().UnixNano() % 1_000_000_000
	s := realmSeed{p: fmt.Sprintf("HUM-9%d1", n), q: fmt.Sprintf("HUM-9%d2", n), w1: "ws-r1-" + uuid4(), w2: "ws-r2-" + uuid4(), w3: "ws-r3-" + uuid4()}
	day := time.Date(2026, 9, 7, 0, 0, 0, 0, time.UTC)
	for _, who := range []string{s.p, s.q} {
		stmts := []struct {
			sql  string
			args []any
		}{
			{`INSERT INTO humans (human_id, display_name) VALUES ($1, 'FirstName LastName')`, []any{who}},
			{`SELECT set_config('app.person_id', $1, true)`, []any{who}},
			{`INSERT INTO personal.profile (person_id, time_zone) VALUES ($1, 'Europe/Helsinki')`, []any{who}},
			{`INSERT INTO personal.settings (person_id, valid_from, hours_limit_day_minutes) VALUES ($1, $2, 480)`, []any{who, day}},
			{`INSERT INTO personal.hours_receipts (person_id, workspace_id, workspace_name, day, minutes, label, kind,
				period_start, period_end, approval_state, rev)
				SELECT $1, w, 'Workspace', $3::date, 60, 'topic', 'work', $3::date, $3::date + 6, 'open', r
				FROM (VALUES ($2::text, 0), ($2, 1), ($4, 0)) v (w, r)`, []any{who, s.w1, day, s.w2}},
			{`INSERT INTO personal.receipt_due (person_id, workspace_id, reason, due_at, done_at)
				VALUES ($1, $2, 'removed', now() - interval '1 day', NULL), ($1, $3, 'access_until', now() - interval '1 day', NULL),
				       ($1, $4, 'removed', now() - interval '1 day', now())`, []any{who, s.w1, s.w2, s.w3}},
		}
		for _, st := range stmts {
			if _, err := tx.Exec(ctx, st.sql, st.args...); err != nil {
				t.Fatalf("seed %s: %s: %v", who, st.sql, err)
			}
		}
	}
	if err := scope(ctx, tx, "", "", ""); err != nil {
		t.Fatal(err)
	}
	for _, tb := range personalTables {
		var c int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM personal.`+tb).Scan(&c); err != nil {
			t.Fatal(err)
		}
		if c != 0 {
			t.Errorf("T-N6: the schema owner without the setting reads %d row(s) of personal.%s, want 0 (FORCE)", c, tb)
		}
	}
	becomeRuntime(t, tx, rt)
	return tx, s
}

// personalPolicyGaps is the policy at SQL level as the runtime, under the
// raw settings: P reads only P (T-N1), and a set tenant (T-N2, T-N3), the
// operator scope (T-N4) or an empty person (T-N5) read 0 rows and write
// none.
func personalPolicyGaps(ctx context.Context, tx pgx.Tx, s realmSeed) []string {
	var gaps []string
	count := func(person, tenant, rls, tb, who string) (int, error) {
		var c int
		err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
			if err := scope(ctx, sp, person, tenant, rls); err != nil {
				return err
			}
			return sp.QueryRow(ctx, `SELECT count(*) FROM personal.`+tb+` WHERE person_id = $1`, who).Scan(&c)
		})
		return c, err
	}
	insert := func(person, tenant, rls, who string) error {
		return inSavepoint(ctx, tx, func(sp pgx.Tx) error {
			if err := scope(ctx, sp, person, tenant, rls); err != nil {
				return err
			}
			_, err := sp.Exec(ctx, `INSERT INTO personal.settings (person_id, valid_from) VALUES ($1, '2030-01-01')`, who)
			return err
		})
	}
	for _, tb := range personalTables {
		cases := []struct {
			name, person, tenant, rls, who string
			want                           bool // rows wanted
		}{
			{"P reads P (control)", s.p, "", "", s.p, true},
			{"P reads Q", s.p, "", "", s.q, false},
			{"P with a tenant set", s.p, s.w1, "", s.p, false},
			{"P under the operator scope", s.p, "", "operator", s.p, false},
			{"operator scope alone", "", "", "operator", s.p, false},
			{"tenant scope alone", "", s.w1, "", s.p, false},
			{"person ''", "", "", "", s.p, false},
		}
		for _, c := range cases {
			n, err := count(c.person, c.tenant, c.rls, tb, c.who)
			switch {
			case err != nil:
				gaps = append(gaps, fmt.Sprintf("%s on %s: %v", c.name, tb, err))
			case c.want && n == 0:
				gaps = append(gaps, fmt.Sprintf("%s on %s: 0 rows, want > 0", c.name, tb))
			case !c.want && n != 0:
				gaps = append(gaps, fmt.Sprintf("%s on %s: %d row(s), want 0", c.name, tb, n))
			}
		}
	}
	writes := []struct {
		name, person, tenant, rls, who string
		ok                             bool
	}{
		{"P writes P (control)", s.p, "", "", s.p, true},
		{"P writes a row stamped Q", s.p, "", "", s.q, false},
		{"P with a tenant set writes P", s.p, s.w1, "", s.p, false},
		{"P under the operator scope writes P", s.p, "", "operator", s.p, false},
		{"person '' writes P", "", "", "", s.p, false},
	}
	for _, w := range writes {
		err := insert(w.person, w.tenant, w.rls, w.who)
		switch {
		case w.ok && err != nil:
			gaps = append(gaps, fmt.Sprintf("%s: %v", w.name, err))
		case !w.ok && sqlState(err) != "42501":
			gaps = append(gaps, fmt.Sprintf("%s: err %v, want the policy's 42501", w.name, err))
		}
	}
	return gaps
}

// TestRLSPersonalPolicy is T-N1..T-N6 at SQL level. CONTROL: the person
// scope without its tenant clause, and an operator_scope policy, each turn
// exactly their cases red.
func TestRLSPersonalPolicy(t *testing.T) {
	pg := rlsStore(t)
	_, rt := runtimeSession(t)
	ctx := context.Background()
	tx, s := seedRealm(t, pg, rt)
	for _, g := range personalPolicyGaps(ctx, tx, s) {
		t.Error(g)
	}
	tx.Rollback(ctx) //nolint:errcheck // the controls' DROP POLICY waits on this tx's locks

	noTenant := []string{`DROP POLICY person_scope ON personal.settings`,
		`CREATE POLICY person_scope ON personal.settings
			USING (person_id = NULLIF(current_setting('app.person_id', true), '')
			       AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
			WITH CHECK (person_id = NULLIF(current_setting('app.person_id', true), '')
			       AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')`}
	operator := []string{`CREATE POLICY operator_scope ON personal.profile
		USING (current_setting('app.rls_scope', true) = 'operator')
		WITH CHECK (current_setting('app.rls_scope', true) = 'operator')`}
	for _, c := range []struct {
		name   string
		plants []string
		want   []string
	}{
		{"no tenant clause", noTenant, []string{"P with a tenant set on settings:", "P with a tenant set writes P:"}},
		{"an operator_scope policy", operator, []string{"P under the operator scope on profile:", "operator scope alone on profile:"}},
	} {
		ctl, cs := seedRealm(t, pg, rt, c.plants...)
		red := personalPolicyGaps(ctx, ctl, cs)
		ctl.Rollback(ctx) //nolint:errcheck
		if len(red) != len(c.want) {
			t.Errorf("control %s: want %d red, got %d: %v", c.name, len(c.want), len(red), red)
		}
		joined := strings.Join(red, "\n")
		for _, w := range c.want {
			if !strings.Contains(joined, w) {
				t.Errorf("control %s: %q stayed green:\n%s", c.name, w, joined)
			}
		}
	}
}

// receiptGaps is T-R6, T-R7 and T-R8 as the runtime: receipts are
// append-only even in P's own scope; due_receipts lists the open due rows;
// delete_my_receipts refuses every scope but the person's, and in it removes
// exactly P's rows of W1 (every rev) and closes P's due row of W1.
func receiptGaps(ctx context.Context, tx pgx.Tx, s realmSeed) []string {
	var gaps []string
	gap := func(f string, a ...any) { gaps = append(gaps, fmt.Sprintf(f, a...)) }
	// T-R6
	for _, sc := range []struct{ name, person string }{{"in P's scope", s.p}, {"no scope", ""}} {
		for _, q := range []string{
			`UPDATE personal.hours_receipts SET minutes = 1 WHERE person_id = $1`,
			`DELETE FROM personal.hours_receipts WHERE person_id = $1`,
		} {
			err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
				if err := scope(ctx, sp, sc.person, "", ""); err != nil {
					return err
				}
				_, err := sp.Exec(ctx, q, s.p)
				return err
			})
			if sqlState(err) != "42501" {
				gap("T-R6 %s %s: err %v, want 42501", sc.name, strings.Fields(q)[0], err)
			}
		}
	}
	// T-R7: P's and Q's open due rows of W1 and W2 come back, W3 (closed) not.
	due := func() (map[string]bool, error) {
		got := map[string]bool{}
		err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
			if err := scope(ctx, sp, "", "", ""); err != nil {
				return err
			}
			rows, err := sp.Query(ctx, `SELECT * FROM personal.due_receipts(now()) WHERE person_id IN ($1, $2)`, s.p, s.q)
			if err != nil {
				return err
			}
			defer rows.Close()
			if n := len(rows.FieldDescriptions()); n != 2 {
				return fmt.Errorf("%d columns", n)
			}
			for rows.Next() {
				var p, w string
				if err := rows.Scan(&p, &w); err != nil {
					return err
				}
				got[p+"/"+w] = true
			}
			return rows.Err()
		})
		return got, err
	}
	got, err := due()
	want := []string{s.p + "/" + s.w1, s.p + "/" + s.w2, s.q + "/" + s.w1, s.q + "/" + s.w2}
	if err != nil || len(got) != len(want) {
		gap("T-R7 due_receipts: got %v err %v, want %v", got, err, want)
	} else {
		for _, w := range want {
			if !got[w] {
				gap("T-R7 due_receipts lacks %s: %v", w, got)
			}
		}
	}
	// T-R8: every scope but P's own is refused, and deletes nothing.
	total := func(sp pgx.Tx, who, ws string) (int, error) {
		var c int
		if err := scope(ctx, sp, who, "", ""); err != nil {
			return 0, err
		}
		err := sp.QueryRow(ctx, `SELECT count(*) FROM personal.hours_receipts WHERE workspace_id = $1`, ws).Scan(&c)
		return c, err
	}
	for _, r := range []struct{ name, person, tenant, rls string }{
		{"under a tenant scope", "", s.w1, ""},
		{"P with a tenant set", s.p, s.w1, ""},
		{"under the operator scope", "", "", "operator"},
		{"P under the operator scope", s.p, "", "operator"},
		{"no person", "", "", ""},
		{"a malformed person", "HUM-1; --", "", ""},
	} {
		err := inSavepoint(ctx, tx, func(sp pgx.Tx) error {
			if err := scope(ctx, sp, r.person, r.tenant, r.rls); err != nil {
				return err
			}
			if _, err := sp.Exec(ctx, `SELECT personal.delete_my_receipts($1)`, s.w1); err != nil {
				return err
			}
			if c, err := total(sp, s.p, s.w1); err != nil || c != 2 {
				return fmt.Errorf("P's W1 rows after the call: %d (%v), want 2", c, err)
			}
			return nil
		})
		if sqlState(err) != "42501" {
			gap("T-R8 delete_my_receipts %s: err %v, want the refusal 42501", r.name, err)
		}
	}
	err = inSavepoint(ctx, tx, func(sp pgx.Tx) error {
		if err := scope(ctx, sp, s.p, "", ""); err != nil {
			return err
		}
		var n int
		if err := sp.QueryRow(ctx, `SELECT personal.delete_my_receipts($1)`, s.w1).Scan(&n); err != nil {
			return err
		}
		if n != 2 {
			gap("T-R8 P deleted %d row(s) of W1, want 2 (rev 0 and 1)", n)
		}
		for _, c := range []struct {
			who, ws string
			want    int
		}{{s.p, s.w1, 0}, {s.p, s.w2, 1}, {s.q, s.w1, 2}} {
			if got, err := total(sp, c.who, c.ws); err != nil || got != c.want {
				gap("T-R8 after P's delete of W1: %s has %d row(s) of its %s receipts (%v), want %d", c.who, got, c.ws, err, c.want)
			}
		}
		left, err := due()
		if err != nil || left[s.p+"/"+s.w1] || !left[s.p+"/"+s.w2] || !left[s.q+"/"+s.w1] {
			gap("T-R8 due rows after P's delete of W1: %v (%v), want P/W1 closed, P/W2 and Q/W1 open", left, err)
		}
		return nil
	})
	if err != nil {
		gap("T-R8 delete_my_receipts in P's scope: %v", err)
	}
	return gaps
}

// TestRLSPersonalReceipts is T-R6, T-R7 (the sweeper's own reach included)
// and T-R8. CONTROL: delete_my_receipts without its person check (planted as
// spool_realm_eraser) turns every refusal red; the person_scope policy
// still holds, so it deletes nothing outside P's own scope.
func TestRLSPersonalReceipts(t *testing.T) {
	pg := rlsStore(t)
	_, rt := runtimeSession(t)
	ctx := context.Background()

	// T-R7, the sweeper's reach: as spool_realm_sweeper, profile, settings
	// and hours_receipts are refused; receipt_due shows open rows only.
	sw := ownerTx(t, pg)
	for _, q := range []string{`SET LOCAL ROLE spool_realm_sweeper`, `SELECT set_config('app.person_id', '', true)`} {
		if _, err := sw.Exec(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	for _, tb := range []string{"profile", "settings", "hours_receipts"} {
		err := inSavepoint(ctx, sw, func(sp pgx.Tx) error {
			_, err := sp.Exec(ctx, `SELECT person_id FROM personal.`+tb)
			return err
		})
		if sqlState(err) != "42501" {
			t.Errorf("T-R7: spool_realm_sweeper reading personal.%s: err %v, want 42501", tb, err)
		}
	}
	var closed int
	if err := sw.QueryRow(ctx, `SELECT count(*) FROM personal.receipt_due WHERE done_at IS NOT NULL`).Scan(&closed); err != nil || closed != 0 {
		t.Errorf("T-R7: spool_realm_sweeper sees %d closed receipt_due row(s) (%v), want 0", closed, err)
	}
	sw.Rollback(ctx) //nolint:errcheck

	tx, s := seedRealm(t, pg, rt)
	for _, g := range receiptGaps(ctx, tx, s) {
		t.Error(g)
	}
	tx.Rollback(ctx) //nolint:errcheck // the control's CREATE OR REPLACE waits on this tx's locks

	ctl, cs := seedRealm(t, pg, rt,
		`SET LOCAL ROLE spool_realm_eraser`,
		`CREATE OR REPLACE FUNCTION personal.delete_my_receipts(workspace_id text) RETURNS integer
			LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
		AS $fn$
		DECLARE n integer;
		BEGIN
			DELETE FROM personal.hours_receipts r WHERE r.workspace_id = delete_my_receipts.workspace_id;
			GET DIAGNOSTICS n = ROW_COUNT;
			RETURN n;
		END
		$fn$`,
		`RESET ROLE`)
	red := strings.Join(receiptGaps(ctx, ctl, cs), "\n")
	for _, w := range []string{"under a tenant scope", "P with a tenant set", "under the operator scope", "no person", "a malformed person"} {
		if !strings.Contains(red, "delete_my_receipts "+w+":") {
			t.Errorf("control: the refusal %q stayed green with the person check dropped:\n%s", w, red)
		}
	}
	if strings.Contains(red, "after the call") {
		t.Errorf("control: with the check dropped the policy still must keep every row outside P's scope:\n%s", red)
	}
}
