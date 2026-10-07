package store

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/100 T004, spec section 6 T1..T4: the search index's one door
// (rdb 0143, spool_search_candidates) must fail on a leak. Postgres only,
// as the runtime login hub-pg.tst.sh hands over (SPOOL_TEST_PG_RUNTIME_DSN,
// not BYPASSRLS). Each check is a function that returns its gaps; the plain
// run wants none, and each plant (a rolled-back transaction as the migrate
// login, never committed, so trunk never turns red) wants its own. The names
// start TestRLS, so hub-pg.tst.sh's RLS control counts them: a skip there
// is a failure. No t.Run: that control greps every "--- PASS: TestRLS".

// rowQuerier is the pool or a transaction.
type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// searchSeed is tenants A and B, each with the shared word, a word of its
// own and a DM between two other members (HUM-2 to CLE-01) carrying the
// shared word: the function is the tenant pin and a match, nothing more,
// so the DM is A's candidate too (the hub's read door drops it later).
type searchSeed struct {
	a, b           string   // tenant ids
	shared         string   // the word both tenants hold
	onlyA, onlyB   string   // a word each
	aIDs, bIDs     []string // every msg_id carrying the shared word, sorted
	aOwnID, bOwnID string   // the msg_id carrying each tenant's own word
}

// zqWord is a fresh letters-only word, so the store suite's other seeds
// never match it and the spool_search parser keeps it one token.
func zqWord() string {
	b := make([]byte, 10)
	rand.Read(b) //nolint:errcheck
	for i := range b {
		b[i] = 'a' + b[i]%26
	}
	return "zq" + string(b)
}

func seedSearch(t *testing.T, pg *Postgres) searchSeed {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC()
	s := searchSeed{a: newTenant(t, pg), b: newTenant(t, pg), shared: zqWord(), onlyA: zqWord(), onlyB: zqWord()}
	put := func(tenant, body string, dm bool) string {
		m := msgFor(tenant, uuid4(), "box-a", now, now, "env-"+uuid4())
		m.Body = body
		if dm {
			m.Channel, m.Kind, m.FromID, m.FromBox, m.ToID = "", "note", "HUM-2", "box-wui", "CLE-01"
		}
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return m.MsgID
	}
	s.aOwnID = put(s.a, s.shared+" "+s.onlyA, false)
	s.aIDs = []string{s.aOwnID, put(s.a, s.shared, false), put(s.a, "dm "+s.shared, true)}
	s.bOwnID = put(s.b, s.shared+" "+s.onlyB, false)
	s.bIDs = []string{s.bOwnID, put(s.b, "dm "+s.shared, true)}
	sort.Strings(s.aIDs)
	sort.Strings(s.bIDs)
	return s
}

// candidates calls spool_search_candidates in a savepoint of tx, with
// app.rls_scope and app.tenant_id set as given ("-" leaves one unset).
func candidates(ctx context.Context, tx pgx.Tx, scope, tenant, word string) ([]string, error) {
	sp, err := tx.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer sp.Rollback(ctx) //nolint:errcheck
	for _, kv := range [][2]string{{"app.rls_scope", scope}, {"app.tenant_id", tenant}} {
		if kv[1] == "-" {
			continue
		}
		if _, err := sp.Exec(ctx, `SELECT set_config($1, $2, true)`, kv[0], kv[1]); err != nil {
			return nil, err
		}
	}
	rows, err := sp.Query(ctx, `SELECT msg_id::text FROM spool_search_candidates(to_tsquery('spool_search', $1), 500)`, word)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	sort.Strings(ids)
	return ids, err
}

// pinGaps is T1: scope A returns A's ids only, scope B B's only, and an
// unset or ” tenant returns no row, also under the operator scope. tx
// runs as the runtime login.
func pinGaps(ctx context.Context, tx pgx.Tx, s searchSeed) []string {
	var gaps []string
	cases := []struct {
		name, scope, tenant, word string
		want                      []string
	}{
		{"scope A, shared word", "-", s.a, s.shared, s.aIDs},
		{"scope B, shared word", "-", s.b, s.shared, s.bIDs},
		{"scope A, A's word", "-", s.a, s.onlyA, []string{s.aOwnID}},
		{"scope A, B's word", "-", s.a, s.onlyB, nil},
		{"scope B, B's word", "-", s.b, s.onlyB, []string{s.bOwnID}},
		{"tenant unset", "-", "-", s.shared, nil},
		{"tenant ''", "-", "", s.shared, nil},
		{"operator scope, tenant unset", "operator", "-", s.shared, nil},
		{"operator scope, tenant ''", "operator", "", s.shared, nil},
	}
	for _, c := range cases {
		got, err := candidates(ctx, tx, c.scope, c.tenant, c.word)
		if err != nil {
			gaps = append(gaps, fmt.Sprintf("%s: %v", c.name, err))
		} else if strings.Join(got, ",") != strings.Join(c.want, ",") {
			gaps = append(gaps, fmt.Sprintf("%s: got %d id(s) %v, want %d %v", c.name, len(got), got, len(c.want), c.want))
		}
	}
	return gaps
}

// runtimeSession connects as the runtime login and names it.
func runtimeSession(t *testing.T) (*pgx.Conn, string) {
	t.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_RUNTIME_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_RUNTIME_DSN unset (hub-pg.tst.sh sets it to the runtime role)")
	}
	ctx := context.Background()
	rt, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { rt.Close(ctx) })
	var name string
	if err := rt.QueryRow(ctx, `SELECT current_user`).Scan(&name); err != nil {
		t.Fatal(err)
	}
	return rt, name
}

// ownerTx opens a transaction as the migrate login that the test always
// rolls back: the plants live and die in it.
func ownerTx(t *testing.T, pg *Postgres) pgx.Tx {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tx.Rollback(ctx) }) //nolint:errcheck
	return tx
}

// becomeRuntime switches the owner's transaction to the runtime login, so a
// plant made a statement earlier is seen by it (DDL is transactional; the
// runtime's own session would not see it). The owner created the runtime
// role (runtime-role.sql), so holds ADMIN on it and can take SET for this
// transaction only.
func becomeRuntime(t *testing.T, tx pgx.Tx, rtRole string) {
	t.Helper()
	ctx := context.Background()
	for _, q := range []string{
		fmt.Sprintf(`GRANT %s TO CURRENT_USER WITH SET TRUE, INHERIT FALSE`, pgx.Identifier{rtRole}.Sanitize()),
		fmt.Sprintf(`SET LOCAL ROLE %s`, pgx.Identifier{rtRole}.Sanitize()),
	} {
		if _, err := tx.Exec(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
}

// TestRLSSearchIndexPin is T1, door 1 on its own: the function pins the
// session tenant, as the runtime login.
func TestRLSSearchIndexPin(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeSession(t)
	ctx := context.Background()
	s := seedSearch(t, pg)
	tx, err := rt.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	for _, g := range pinGaps(ctx, tx, s) {
		t.Error("T1: " + g)
	}
}

// TestRLSSearchIndexPlantedLeak is T2: as the migrate login, in a
// rolled-back transaction, the function is replaced by one with no tenant
// pin. T1 must then FAIL (it is not vacuous), and the outer statement under
// FORCE RLS must still return the session tenant's rows only (door 2: the
// store-level half of T6; the API-level T6 runs once T006's hub probe
// lands). The runtime login itself cannot make this plant (T4).
func TestRLSSearchIndexPlantedLeak(t *testing.T) {
	pg := rlsStore(t)
	_, rtRole := runtimeSession(t)
	ctx := context.Background()
	s := seedSearch(t, pg)
	tx := ownerTx(t, pg)
	for _, q := range []string{
		`SET LOCAL ROLE spool_search_reader`,
		`CREATE OR REPLACE FUNCTION public.spool_search_candidates(q tsquery, cap int)
			RETURNS TABLE (msg_id uuid, received_at timestamptz)
			LANGUAGE sql STABLE SECURITY DEFINER ROWS 200
			SET search_path = pg_catalog, public, pg_temp
		AS $fn$
			SELECT m.msg_id, m.received_at FROM public.messages m
			WHERE m.search_tsv @@ q
			LIMIT cap + 1
		$fn$`,
		`RESET ROLE`,
	} {
		if _, err := tx.Exec(ctx, q); err != nil {
			t.Fatalf("plant: %s: %v", q, err)
		}
	}
	becomeRuntime(t, tx, rtRole)

	gaps := pinGaps(ctx, tx, s)
	if len(gaps) == 0 {
		t.Fatal("T2: T1 stayed green with the tenant pin removed: T1 is vacuous")
	}
	red := strings.Join(gaps, "\n")
	for _, want := range []string{"scope A, shared word", "scope A, B's word", "tenant unset", "operator scope, tenant ''"} {
		if !strings.Contains(red, want+":") {
			t.Errorf("T2: T1 did not go red on %q:\n%s", want, red)
		}
	}

	// Door 2 still holds: the runtime's own statement, scope A, over every
	// candidate id the leaky function returned, sees A's rows only.
	ids, err := candidates(ctx, tx, "-", s.a, s.shared)
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) < len(s.aIDs)+len(s.bIDs) {
		t.Fatalf("T2: the planted function returned %d id(s), want at least A's %d and B's %d", len(ids), len(s.aIDs), len(s.bIDs))
	}
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, s.a); err != nil {
		t.Fatal(err)
	}
	rows, err := tx.Query(ctx, `SELECT m.msg_id::text FROM messages m WHERE m.msg_id = ANY($1::uuid[])
		AND m.search_tsv @@ to_tsquery('spool_search', $2) ORDER BY 1`, ids, s.shared)
	if err != nil {
		t.Fatal(err)
	}
	got, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, ",") != strings.Join(s.aIDs, ",") {
		t.Errorf("T2: door 2 under FORCE RLS returned %v, want A's %v only", got, s.aIDs)
	}
}

// catalogueGaps is T3: the reader role, its policy, its grants and the
// function, read from the catalogue. Each query returns a row only when its
// check fails, naming what it found.
func catalogueGaps(ctx context.Context, q rowQuerier) []string {
	checks := []struct{ what, sql string }{
		{"the reader's one policy is search_reader_all ON messages FOR SELECT TO spool_search_reader", `
			SELECT COALESCE(string_agg(format('%s on %s cmd=%s roles=%s', policyname, tablename, cmd, array_to_string(roles, ',')), '; '), 'none')
			FROM pg_policies WHERE 'spool_search_reader' = ANY (roles) OR policyname = 'search_reader_all'
			HAVING count(*) <> 1 OR bool_or(policyname <> 'search_reader_all' OR tablename <> 'messages'
			                                OR cmd <> 'SELECT' OR roles <> '{spool_search_reader}')`},
		{"messages is ENABLE + FORCE row security", `
			SELECT format('enable=%s force=%s', relrowsecurity, relforcerowsecurity) FROM pg_class
			WHERE oid = 'public.messages'::regclass AND NOT (relrowsecurity AND relforcerowsecurity)`},
		{"spool_search_reader is NOLOGIN NOSUPERUSER NOBYPASSRLS", `
			SELECT format('login=%s super=%s bypassrls=%s createrole=%s createdb=%s replication=%s',
			              rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication)
			FROM pg_roles WHERE rolname = 'spool_search_reader'
			  AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication)`},
		{"spool_search_reader has no member but the schema owner, never by inheritance", `
			SELECT string_agg(format('%s inherit=%s', pg_get_userbyid(m.member), m.inherit_option), ', ')
			FROM pg_auth_members m WHERE m.roleid = 'spool_search_reader'::regrole
			  AND (m.inherit_option OR m.member <> (SELECT relowner FROM pg_class WHERE oid = 'public.messages'::regclass))
			HAVING count(*) > 0`},
		{"no login holds spool_search_reader's privileges", `
			SELECT string_agg(rolname, ', ') FROM pg_roles
			WHERE rolcanlogin AND NOT rolsuper AND rolname <> 'spool_search_reader'
			  AND pg_has_role(oid, 'spool_search_reader', 'USAGE')
			HAVING count(*) > 0`},
		{"spool_search_reader owns exactly one function", `
			SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', '), 'none') FROM pg_proc p
			WHERE p.proowner = 'spool_search_reader'::regrole
			HAVING count(*) <> 1 OR bool_or(p.oid <> 'public.spool_search_candidates(tsquery, integer)'::regprocedure)`},
		{"spool_search_reader holds no table-level grant", `
			SELECT string_agg(DISTINCT c.oid::regclass::text, ', ') FROM pg_class c, aclexplode(c.relacl) a
			WHERE a.grantee = 'spool_search_reader'::regrole
			HAVING count(*) > 0`},
		{"spool_search_reader holds column SELECT on messages' four search columns only", `
			SELECT COALESCE(string_agg(format('%s.%s %s', c.relname, at.attname, a.privilege_type), ', '), 'none')
			FROM pg_attribute at JOIN pg_class c ON c.oid = at.attrelid, aclexplode(at.attacl) a
			WHERE a.grantee = 'spool_search_reader'::regrole
			HAVING count(*) <> 4 OR bool_or(c.oid <> 'public.messages'::regclass OR a.privilege_type <> 'SELECT'
			    OR at.attname NOT IN ('tenant_id', 'msg_id', 'received_at', 'search_tsv'))`},
		{"one spool_search_candidates(tsquery, int), no tenant parameter, SECURITY DEFINER, LANGUAGE sql", `
			SELECT COALESCE(string_agg(format('%s names=%s definer=%s lang=%s', p.oid::regprocedure,
			                         array_to_string(p.proargnames, ','), p.prosecdef, l.lanname), '; '), 'none')
			FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang WHERE p.proname = 'spool_search_candidates'
			HAVING count(*) <> 1 OR bool_or(p.oid <> 'public.spool_search_candidates(tsquery, integer)'::regprocedure
			    OR array_to_string(p.proargnames, ',') ILIKE '%tenant%' OR NOT p.prosecdef OR l.lanname <> 'sql')`},
		{"search_path is exactly pg_catalog, public, pg_temp (pg_temp last)", `
			SELECT COALESCE(array_to_string(proconfig, ';'), 'unset') FROM pg_proc
			WHERE oid = 'public.spool_search_candidates(tsquery, integer)'::regprocedure
			  AND proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog, public, pg_temp']`},
		{"the body names public.messages and pins NULLIF(current_setting('app.tenant_id', true), '')", `
			SELECT left(regexp_replace(prosrc, '\s+', ' ', 'g'), 300) FROM pg_proc
			WHERE oid = 'public.spool_search_candidates(tsquery, integer)'::regprocedure
			  AND NOT (prosrc LIKE '%FROM public.messages m%'
			       AND prosrc LIKE '%m.tenant_id = NULLIF(current_setting(''app.tenant_id'', true), '''')%')`},
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

// TestRLSSearchIndexCatalogue is T3. CONTROL: three plants, each in a
// rolled-back transaction as the migrate login, each turn their own check
// red and no other: the reader can log in, search_path puts pg_temp first,
// the policy widens to every command.
func TestRLSSearchIndexCatalogue(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	for _, g := range catalogueGaps(ctx, pg.pool) {
		t.Error("T3: " + g)
	}
	plants := []struct {
		name, want string
		sql        []string
	}{
		{"reader can log in", "NOLOGIN", []string{`ALTER ROLE spool_search_reader LOGIN`}},
		{"pg_temp first", "pg_temp last", []string{
			`SET LOCAL ROLE spool_search_reader`,
			`ALTER FUNCTION public.spool_search_candidates(tsquery, int) SET search_path = pg_temp, pg_catalog, public`,
			`RESET ROLE`,
		}},
		{"policy FOR ALL", "FOR SELECT", []string{
			`DROP POLICY search_reader_all ON messages`,
			`CREATE POLICY search_reader_all ON messages FOR ALL TO spool_search_reader USING (true)`,
		}},
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
					t.Fatalf("T3 plant %s: %s: %v", p.name, q, err)
				}
			}
			gaps := catalogueGaps(ctx, tx)
			if len(gaps) != 1 || !strings.Contains(gaps[0], p.want) {
				t.Errorf("T3 plant %s: want exactly the %q check red, got %d: %v", p.name, p.want, len(gaps), gaps)
			}
		}()
	}
}

// runtimeGaps is T4, run as the runtime login in tx: it is no member of
// spool_search_reader, and cannot SET ROLE to it, ALTER the function or
// CREATE OR REPLACE it. Each attempt runs in its own savepoint.
func runtimeGaps(ctx context.Context, tx pgx.Tx) []string {
	var gaps []string
	var member bool
	if err := tx.QueryRow(ctx, `SELECT pg_has_role(current_user, 'spool_search_reader', 'MEMBER')`).Scan(&member); err != nil {
		return []string{fmt.Sprintf("membership: %v", err)}
	}
	if member {
		gaps = append(gaps, "the runtime login is a member of spool_search_reader")
	}
	attempts := []struct{ what, sql string }{
		{"SET ROLE spool_search_reader", `SET LOCAL ROLE spool_search_reader`},
		{"ALTER FUNCTION", `ALTER FUNCTION public.spool_search_candidates(tsquery, int) SET search_path = pg_temp`},
		{"CREATE OR REPLACE FUNCTION", `CREATE OR REPLACE FUNCTION public.spool_search_candidates(q tsquery, cap int)
			RETURNS TABLE (msg_id uuid, received_at timestamptz)
			LANGUAGE sql STABLE SECURITY DEFINER ROWS 200
			SET search_path = pg_catalog, public, pg_temp
		AS $fn$ SELECT m.msg_id, m.received_at FROM public.messages m WHERE m.search_tsv @@ q LIMIT cap + 1 $fn$`},
	}
	for _, a := range attempts {
		sp, err := tx.Begin(ctx)
		if err != nil {
			return append(gaps, fmt.Sprintf("savepoint: %v", err))
		}
		if _, err := sp.Exec(ctx, a.sql); err == nil {
			gaps = append(gaps, "the runtime login can "+a.what)
		}
		sp.Rollback(ctx) //nolint:errcheck
	}
	return gaps
}

// TestRLSSearchIndexRuntimeNotReader is T4. CONTROL: GRANT
// spool_search_reader TO <runtime login>, planted by the migrate login in a
// rolled-back transaction, turns every T4 check red.
func TestRLSSearchIndexRuntimeNotReader(t *testing.T) {
	pg := rlsStore(t)
	rt, rtRole := runtimeSession(t)
	ctx := context.Background()

	tx, err := rt.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	for _, g := range runtimeGaps(ctx, tx) {
		t.Error("T4: " + g)
	}

	own := ownerTx(t, pg)
	plant := fmt.Sprintf(`GRANT spool_search_reader TO %s`, pgx.Identifier{rtRole}.Sanitize())
	if _, err := own.Exec(ctx, plant); err != nil {
		t.Fatalf("T4 plant: %s: %v", plant, err)
	}
	becomeRuntime(t, own, rtRole)
	if gaps := runtimeGaps(ctx, own); len(gaps) != 4 {
		t.Errorf("T4 plant (%s): want all 4 checks red, got %d: %v", plant, len(gaps), gaps)
	}
}
