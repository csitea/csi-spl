package store

import (
	"context"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// rdb 0141 (specs/100 T002, S1r): the search index and its one door. The
// file applies a second time through Migrate and changes nothing; the
// catalogue then pins the shape spec section 5.1 asks for; and, as the
// runtime login, spool_search_candidates returns the session tenant's
// candidates only, at most cap + 1, never a temp table's rows.
const searchIndexFile = "0141_messages_search_index.sql"

func TestSearchIndexMigrate0141(t *testing.T) {
	pg := rlsStore(t) // migrated once, as the plain owner
	ctx := context.Background()

	// Apply #2 through Migrate: forget the ledger row, the runner re-runs it.
	if _, err := pg.pool.Exec(ctx, `DELETE FROM spool_schema_migrations WHERE filename = $1`, searchIndexFile); err != nil {
		t.Fatal(err)
	}
	applied, err := Migrate(ctx, pg.Pool(), sqlDir(t))
	if err != nil {
		t.Fatalf("second apply of %s: %v", searchIndexFile, err)
	}
	var again bool
	for _, a := range applied {
		again = again || (a.File == searchIndexFile && !a.Skipped)
	}
	if !again {
		t.Fatalf("%s was not re-applied: %+v", searchIndexFile, applied)
	}

	one := func(q string, args ...any) string {
		t.Helper()
		var s string
		if err := pg.pool.QueryRow(ctx, q, args...).Scan(&s); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return s
	}
	pins := []struct{ what, q, want string }{
		{"reader role", `SELECT format('login=%s super=%s bypassrls=%s', rolcanlogin, rolsuper, rolbypassrls)
			FROM pg_roles WHERE rolname = 'spool_search_reader'`, "login=f super=f bypassrls=f"},
		{"index", `SELECT COALESCE((SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'messages_search'), '')`,
			"USING gin (tenant_id, search_tsv)"},
		{"index count", `SELECT count(*)::text FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'messages_search'`, "1"},
		{"function", `SELECT format('owner=%s definer=%s volatile=%s rows=%s lang=%s config=%s',
				pg_get_userbyid(p.proowner), p.prosecdef, p.provolatile, p.prorows, l.lanname, array_to_string(p.proconfig, ';'))
			FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
			WHERE p.oid = 'public.spool_search_candidates(tsquery, integer)'::regprocedure`,
			`owner=spool_search_reader definer=t volatile=s rows=200 lang=sql config=search_path=pg_catalog, public, pg_temp`},
		{"body names public.messages", `SELECT (prosrc LIKE '%FROM public.messages m%' AND prosrc LIKE '%app.tenant_id%')::text
			FROM pg_proc WHERE oid = 'public.spool_search_candidates(tsquery, integer)'::regprocedure`, "true"},
		{"no EXECUTE to PUBLIC", `SELECT (NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
			WHERE p.oid = 'public.spool_search_candidates(tsquery, integer)'::regprocedure AND a.grantee = 0))::text`, "true"},
		{"policy", `SELECT format('%s %s %s %s', cmd, permissive, array_to_string(roles, ','), qual)
			FROM pg_policies WHERE schemaname = current_schema() AND tablename = 'messages' AND policyname = 'search_reader_all'`,
			"SELECT PERMISSIVE spool_search_reader true"},
		{"no other policy for the reader", `SELECT count(*)::text FROM pg_policies
			WHERE schemaname = current_schema() AND 'spool_search_reader' = ANY (roles) AND policyname <> 'search_reader_all'`, "0"},
		{"reader writes nothing", `SELECT (has_table_privilege('spool_search_reader', 'messages', 'INSERT, UPDATE, DELETE, TRUNCATE')
			OR has_column_privilege('spool_search_reader', 'messages', 'body', 'SELECT'))::text`, "false"},
		{"reader reads its four columns", `SELECT (has_column_privilege('spool_search_reader', 'messages', 'tenant_id', 'SELECT')
			AND has_column_privilege('spool_search_reader', 'messages', 'msg_id', 'SELECT')
			AND has_column_privilege('spool_search_reader', 'messages', 'received_at', 'SELECT')
			AND has_column_privilege('spool_search_reader', 'messages', 'search_tsv', 'SELECT'))::text`, "true"},
		{"no login inherits the reader", `SELECT (string_agg(rolname, ',') IS NULL)::text FROM pg_roles
			WHERE rolcanlogin AND NOT rolsuper AND pg_has_role(oid, 'spool_search_reader', 'USAGE')`, "true"},
		{"messages still FORCE RLS", `SELECT (relrowsecurity AND relforcerowsecurity)::text FROM pg_class WHERE oid = 'public.messages'::regclass`, "true"},
	}
	for _, p := range pins {
		if got := one(p.q); !strings.Contains(got, p.want) {
			t.Errorf("%s: got %q, want %q", p.what, got, p.want)
		}
	}

	rtDSN := os.Getenv("SPOOL_TEST_PG_RUNTIME_DSN")
	if rtDSN == "" {
		t.Log("SPOOL_TEST_PG_RUNTIME_DSN unset: the runtime half is not run (hub-pg.tst.sh sets it)")
		return
	}
	// Seed: tenant A has the shared word three times and its own word; B has
	// the shared word and its own.
	now := time.Now().UTC()
	tA, tB := newTenant(t, pg), newTenant(t, pg)
	seed := func(tenant, body string) string {
		m := msgFor(tenant, uuid4(), "box-a", now, now, "env-"+uuid4())
		m.Body = body
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return m.MsgID
	}
	a1, a2, a3 := seed(tA, "zqshared zqonlya"), seed(tA, "zqshared"), seed(tA, "zqshared")
	seed(tB, "zqshared zqonlyb")

	rt, err := pgx.Connect(ctx, rtDSN)
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Close(ctx)
	var member bool
	if err := rt.QueryRow(ctx, `SELECT pg_has_role(current_user, 'spool_search_reader', 'MEMBER')`).Scan(&member); err != nil {
		t.Fatal(err)
	}
	if member {
		t.Fatal("the runtime login is a member of spool_search_reader: it would read every tenant through USING (true)")
	}
	// call runs the function as the runtime login, tenant set (or not), in a
	// rolled-back transaction; shadow first creates a temp table messages
	// holding a row the function must never return.
	call := func(tenant, word string, cap int, shadow bool) []string {
		t.Helper()
		tx, err := rt.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx) //nolint:errcheck
		if tenant != "" {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
				t.Fatal(err)
			}
		}
		if shadow {
			if _, err := tx.Exec(ctx, `CREATE TEMP TABLE messages ON COMMIT DROP AS
				SELECT $1::text AS tenant_id, gen_random_uuid() AS msg_id, now() AS received_at,
				       to_tsvector('spool_search', $2::text) AS search_tsv`, tenant, word); err != nil {
				t.Fatal(err)
			}
		}
		rows, err := tx.Query(ctx, `SELECT msg_id::text FROM spool_search_candidates(to_tsquery('spool_search', $1), $2)`, word, cap)
		if err != nil {
			t.Fatalf("spool_search_candidates as the runtime login: %v", err)
		}
		ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatal(err)
		}
		sort.Strings(ids)
		return ids
	}
	want := []string{a1, a2, a3}
	sort.Strings(want)
	cases := []struct {
		name, tenant, word string
		cap                int
		shadow             bool
		want               []string
	}{
		{"own tenant, shared word", tA, "zqshared", 500, false, want},
		{"own word", tA, "zqonlya", 500, false, []string{a1}},
		{"other tenant's word", tA, "zqonlyb", 500, false, nil},
		{"no tenant", "", "zqshared", 500, false, nil},
		{"temp table messages cannot shadow", tA, "zqonlya", 500, true, []string{a1}},
	}
	for _, c := range cases {
		if got := call(c.tenant, c.word, c.cap, c.shadow); strings.Join(got, ",") != strings.Join(c.want, ",") {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
	if got := call(tA, "zqshared", 1, false); len(got) != 2 {
		t.Errorf("cap 1 over 3 matches: got %d rows, want cap + 1 = 2", len(got))
	}
	// CONTROL: the runtime's own statement on messages is still bound by the
	// tenant policy: no tenant, no row, even with the index present.
	var n int
	if err := rt.QueryRow(ctx, `SELECT count(*) FROM messages WHERE search_tsv @@ to_tsquery('spool_search', 'zqshared')`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("runtime login without a tenant read %d messages", n)
	}
}
