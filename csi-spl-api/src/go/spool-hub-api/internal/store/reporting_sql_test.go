package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 143 build row 5, the SQL tab's executor (tasks T031, SPL-2789).
// Postgres only (hub-pg.tst.sh): each case runs an admin's text through
// RunReportingSQL, or a write straight through its envelope with every app
// check bypassed (spec 143 6.2: "write queries fail at the database level
// even if a caller bypasses the application parser").

// sqlTwoTenants seeds tenants A and B, one message each.
func sqlTwoTenants(t *testing.T) (*Postgres, string, string) {
	t.Helper()
	pg := rlsStore(t)
	a, _ := rlsTenant(t, pg)
	b, _ := rlsTenant(t, pg)
	return pg, a, b
}

func runSQL(t *testing.T, pg *Postgres, tenant, q string) (ReportingSQLResult, error) {
	t.Helper()
	return pg.RunReportingSQL(context.Background(), tenant, q)
}

// one reads a single-cell answer.
func one(t *testing.T, r ReportingSQLResult) string {
	t.Helper()
	if len(r.Rows) != 1 || len(r.Rows[0]) != 1 || r.Rows[0][0] == nil {
		t.Fatalf("want one non-null cell, got %d rows %+v", len(r.Rows), r.Rows)
	}
	return *r.Rows[0][0]
}

// TestSQLExecutorIsolation (T031 GATE, red control "cross-tenant read"):
// workspace A's admin reads A's message and none of B's, by naming B or not.
func TestSQLExecutorIsolation(t *testing.T) {
	pg, a, b := sqlTwoTenants(t)
	r, err := runSQL(t, pg, a, `SELECT count(*) FROM messages`)
	if err != nil || one(t, r) != "1" {
		t.Fatalf("A's own messages: %v %v, want 1", r.Rows, err)
	}
	r, err = runSQL(t, pg, a, `SELECT msg_id, tenant_id FROM messages WHERE tenant_id = '`+b+`'`)
	if err != nil || len(r.Rows) != 0 {
		t.Fatalf("A naming B: %d rows %v, want 0", len(r.Rows), err)
	}
	r, err = runSQL(t, pg, a, `SELECT DISTINCT tenant_id FROM tenants`)
	if err != nil || one(t, r) != a {
		t.Fatalf("tenants as A: %v %v, want only A", r.Rows, err)
	}
	if r.Columns[0].Name != "tenant_id" || r.Columns[0].Type != "text" {
		t.Errorf("columns %+v, want tenant_id text", r.Columns)
	}
}

// TestSQLExecutorOperatorScopeControl is the CONTROL of the function list:
// in the envelope with the plan check bypassed, set_config lifts the scope
// to the operator's and reads B's message, so the list is what stops it.
// Through RunReportingSQL the same text is forbidden_function.
func TestSQLExecutorOperatorScopeControl(t *testing.T) {
	pg, a, _ := sqlTwoTenants(t)
	ctx := context.Background()
	const lift = `SELECT set_config('app.rls_scope', 'operator', true), (SELECT count(*) FROM messages)`
	var scope string
	var n int64
	err := pg.reportingSQLTx(ctx, a, func(tx pgx.Tx) error { return tx.QueryRow(ctx, lift).Scan(&scope, &n) })
	if err != nil || n < 2 {
		t.Fatalf("control: bypassed envelope read %d messages (%v); want both tenants', or this test proves nothing", n, err)
	}
	var ref *ReportingSQLRefusal
	if _, err := runSQL(t, pg, a, lift); !errors.As(err, &ref) || ref.Code != "forbidden_function" || ref.Name != "set_config" {
		t.Fatalf("set_config through the tab: %v, want forbidden_function set_config", err)
	}
}

// TestSQLExecutorReadOnlyAtDatabase (red controls "write" and "DDL"): with
// every app check bypassed, the envelope's READ ONLY transaction refuses a
// write and DDL itself; through RunReportingSQL they are refused too.
func TestSQLExecutorReadOnlyAtDatabase(t *testing.T) {
	pg, a, _ := sqlTwoTenants(t)
	ctx := context.Background()
	for _, q := range []string{
		`INSERT INTO sql_query_audit (audit_id, tenant_id, human_id, query_text, duration_ms) VALUES ('` + uuid4() + `', '` + a + `', 'HUM-1', 'x', 0)`,
		`UPDATE messages SET body = 'x'`,
		`DELETE FROM messages`,
		`DROP TABLE messages`,
		`CREATE TABLE sql_tab_probe (x int)`,
		`ALTER TABLE messages NO FORCE ROW LEVEL SECURITY`,
	} {
		err := pg.reportingSQLTx(ctx, a, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, q); return err })
		if !errors.Is(reportingSQLErr(err), ErrReportingSQLReadOnly) {
			t.Errorf("bypassed envelope %q: %v, want the read-only refusal", q, err)
		}
		if _, err := runSQL(t, pg, a, q); err == nil {
			t.Errorf("through the tab %q: no error", q)
		}
	}
	if _, err := runSQL(t, pg, a, `WITH d AS (DELETE FROM messages RETURNING 1) SELECT count(*) FROM d`); !errors.Is(err, ErrReportingSQLReadOnly) {
		t.Errorf("data-modifying CTE: %v, want the read-only refusal", err)
	}
	if r, err := runSQL(t, pg, a, `SELECT count(*) FROM messages`); err != nil || one(t, r) != "1" {
		t.Fatalf("after the refusals A still has 1 message: %v %v", r.Rows, err)
	}
}

// TestSQLExecutorSingleStatement (red control "multi-statement"): the
// extended protocol refuses two statements even when the app does not.
func TestSQLExecutorSingleStatement(t *testing.T) {
	pg, a, _ := sqlTwoTenants(t)
	var qe *ReportingSQLQueryError
	if _, err := runSQL(t, pg, a, `SELECT 1; DROP TABLE messages`); !errors.As(err, &qe) || qe.SQLState != "42601" {
		t.Fatalf("two statements: %v, want 42601 from Postgres", err)
	}
}

// TestSQLExecutorTimeout (red control "timeout"): a query past the budget
// is cancelled by Postgres (57014). The budget is shortened here; the
// product's is 10 s (asserted).
func TestSQLExecutorTimeout(t *testing.T) {
	if ReportingSQLTimeout != 10*time.Second {
		t.Fatalf("ReportingSQLTimeout = %v, spec 143 B8 says 10 s", ReportingSQLTimeout)
	}
	pg, a, _ := sqlTwoTenants(t)
	defer func(d time.Duration) { reportingSQLBudget = d }(reportingSQLBudget)
	reportingSQLBudget = 300 * time.Millisecond
	start := time.Now()
	_, err := runSQL(t, pg, a, `SELECT count(*) FROM generate_series(1, 2000000000::int8)`)
	if !errors.Is(err, ErrReportingSQLTimeout) {
		t.Fatalf("slow query: %v, want the timeout", err)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("cancelled after %v, want about the 300 ms budget", d)
	}
}

// TestSQLExecutorRowCap (T031 red control): 2,500 rows come back as exactly
// 2,000 with truncated; exactly 2,000 rows are not truncated.
func TestSQLExecutorRowCap(t *testing.T) {
	pg, a, _ := sqlTwoTenants(t)
	r, err := runSQL(t, pg, a, `SELECT g FROM generate_series(1, 2500) g ORDER BY g`)
	if err != nil || len(r.Rows) != ReportingSQLRowCap || !r.Truncated {
		t.Fatalf("2,500 rows: %d truncated=%v %v, want 2000 true", len(r.Rows), r.Truncated, err)
	}
	if *r.Rows[0][0] != "1" || *r.Rows[1999][0] != "2000" {
		t.Errorf("first/last %s/%s, want 1/2000 in order", *r.Rows[0][0], *r.Rows[1999][0])
	}
	r, err = runSQL(t, pg, a, `SELECT g, NULL::text AS n FROM generate_series(1, 2000) g`)
	if err != nil || len(r.Rows) != 2000 || r.Truncated || r.Rows[0][1] != nil {
		t.Fatalf("2,000 rows: %d truncated=%v null=%v %v", len(r.Rows), r.Truncated, r.Rows[0][1], err)
	}
}

// TestSQLExecutorRefusesRelations: a table without workspace RLS, a
// catalogue, a table that keeps a secret and a per-member table are refused
// by the plan check, through a view or a subquery too.
func TestSQLExecutorRefusesRelations(t *testing.T) {
	pg, a, _ := sqlTwoTenants(t)
	for q, rel := range map[string]string{
		`SELECT * FROM humans`:                                                  "humans",
		`SELECT * FROM password_credentials`:                                    "password_credentials",
		`SELECT rolname FROM pg_roles`:                                          "pg_catalog.pg_authid",
		`SELECT count(*) FROM messages WHERE EXISTS (SELECT 1 FROM human_keys)`: "human_keys",
		`SELECT * FROM agent_join_tokens`:                                       "agent_join_tokens",
		`SELECT * FROM workspace_vendor_keys`:                                   "workspace_vendor_keys",
		`SELECT * FROM hours_entries`:                                           "hours_entries",
		`SELECT * FROM release_notes`:                                           "release_notes",
	} {
		var ref *ReportingSQLRefusal
		_, err := runSQL(t, pg, a, q)
		if !errors.As(err, &ref) || ref.Code != "forbidden_relation" || !strings.HasSuffix(ref.Name, rel) {
			t.Errorf("%s: %v, want forbidden_relation %s", q, err, rel)
		}
	}
	for _, q := range []string{`SELECT * FROM messages`, `SELECT c.channel_id, count(m.*) FROM channels c LEFT JOIN messages m ON m.channel = c.channel_id GROUP BY 1`} {
		if _, err := runSQL(t, pg, a, q); err != nil {
			t.Errorf("an open table %q: %v", q, err)
		}
	}
}

// TestSQLExecutorRefusesFunctions: a function off the list is refused by
// the plan check (quoted, qualified or in FROM). Two kinds pass the plan
// check and are the hub lexer's alone (hub TestSQLStaticGuard): an
// immutable call the planner folds into a constant (repeat), and
// current_setting and spool_agent_scope_ok (rdb 0219), which the RLS
// policies deparse into the plan.
func TestSQLExecutorRefusesFunctions(t *testing.T) {
	pg, a, _ := sqlTwoTenants(t)
	for _, q := range []string{
		`SELECT query_to_xml('SELECT 1', true, true, '')`,
		`SELECT "set_config"('app.tenant_id', 'x', true)`,
		`SELECT pg_catalog.pg_sleep(0)`,
		`SELECT * FROM pg_stat_get_activity(NULL)`,
	} {
		var ref *ReportingSQLRefusal
		if _, err := runSQL(t, pg, a, q); !errors.As(err, &ref) {
			t.Errorf("%s: %v, want a refusal", q, err)
		}
	}
}

// TestSQLPlanPolicyCall (no Postgres): rdb 0219's messages and deliveries
// policies deparse spool_agent_scope_ok into Filter, so the plan check takes
// that one name unqualified; the same name in another schema, and any other
// function of the hub's schema, stay refused (red control: drop the
// spool_agent_scope_ok case of planCallAllowed and the first row fails).
func TestSQLPlanPolicyCall(t *testing.T) {
	for expr, want := range map[string]bool{
		`((CASE WHEN (NULLIF(current_setting('app.agent_id'::text, true), ''::text) IS NULL) THEN 1 ELSE NULL::integer END IS NOT NULL) OR spool_agent_scope_ok(messages.tenant_id, messages.channel, messages.task_id, messages.is_private_scope))`: true,
		`public.spool_agent_scope_ok(m.tenant_id, m.channel, m.task_id, m.is_private_scope)`:     false,
		`pg_catalog.spool_agent_scope_ok(m.tenant_id, m.channel, m.task_id, m.is_private_scope)`: false,
		`"evil".spool_agent_scope_ok(m.tenant_id, m.channel, m.task_id, m.is_private_scope)`:     false,
		`embed_visitor_channel('a'::text, 'b'::text)`:                                            false,
		`public.embed_visitor_channel('a'::text, 'b'::text)`:                                     false,
	} {
		err := planExprCheck(expr)
		var ref *ReportingSQLRefusal
		if got := err == nil; got != want || (!want && !errors.As(err, &ref)) {
			t.Errorf("%s: err %v, want allowed=%v", expr, err, want)
		}
	}
}

// TestSQLExecutorErrors: Postgres's own message for a bad query.
func TestSQLExecutorErrors(t *testing.T) {
	pg, a, _ := sqlTwoTenants(t)
	var qe *ReportingSQLQueryError
	if _, err := runSQL(t, pg, a, `SELEC 1`); !errors.As(err, &qe) || qe.Code != "syntax_error" {
		t.Errorf("SELEC: %v, want syntax_error", err)
	}
	if _, err := runSQL(t, pg, a, `SELECT nope FROM messages`); !errors.As(err, &qe) || qe.Code != "syntax_error" {
		t.Errorf("unknown column: %v, want syntax_error", err)
	}
	if _, err := runSQL(t, pg, a, `SELECT 1/0`); !errors.As(err, &qe) || qe.Code != "query_error" {
		t.Errorf("1/0: %v, want query_error", err)
	}
	if _, err := pg.RunReportingSQL(context.Background(), "", `SELECT 1`); !errors.Is(err, ErrNoTenant) {
		t.Errorf("no tenant: %v, want ErrNoTenant", err)
	}
}

// TestSQLAuditScoped (red control "audit"): every attempt leaves a row its
// workspace reads and another workspace does not.
func TestSQLAuditScoped(t *testing.T) {
	pg, a, b := sqlTwoTenants(t)
	ctx := context.Background()
	at := time.Now()
	for _, e := range []string{"", "forbidden_relation"} {
		err := pg.AuditReportingSQL(ctx, ReportingSQLAudit{Tenant: a, Human: "HUM-7", Query: "SELECT 1 -- " + e, At: at,
			Duration: 12 * time.Millisecond, Rows: 1, Error: e, ClientIP: "192.0.2.1"})
		if err != nil {
			t.Fatal(err)
		}
	}
	count := func(tenant string) (n int) {
		err := pg.queryRowTenant(ctx, tenant, `SELECT count(*) FROM sql_query_audit WHERE human_id = 'HUM-7'`, nil, &n)
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	if na, nb := count(a), count(b); na != 2 || nb != 0 {
		t.Fatalf("audit rows A=%d B=%d, want 2 and 0", na, nb)
	}
	if err := pg.AuditReportingSQL(ctx, ReportingSQLAudit{Tenant: "", Human: "HUM-7", Query: "x", At: at}); !errors.Is(err, ErrNoTenant) {
		t.Errorf("audit without a tenant: %v, want ErrNoTenant", err)
	}
	if got := clip("aé", 2); got != "a" {
		t.Errorf("clip inside a rune: %q, want a", got)
	}
}
