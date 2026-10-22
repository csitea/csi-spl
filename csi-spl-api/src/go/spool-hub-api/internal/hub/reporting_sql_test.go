package hub_test

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 143 T060 (SPL-2832), the SQL tab's seven red controls end to end:
// each one is an HTTP POST /v1/reporting/sql through RBAC, the guard, the
// executor and the audit, and asserts the spec 3.7 answer code. A control
// that runs (200) where it must be refused fails the test. On Postgres
// (hub-pg.tst.sh) the real executor runs under RLS; the memory store has no
// executor, so the two controls that need one (cross-workspace, timeout)
// run on Postgres only. The layers underneath are proved one by one in
// store/reporting_sql_test.go and reporting_sql_route_test.go.

// sqlRefused asserts one query is refused with status and code, and that the
// attempt is A's newest audit row with that code.
func (x sqlEnv) sqlRefused(t *testing.T, as, q string, status int, code string) {
	t.Helper()
	before := len(x.auditRows(x.a, as))
	got, body := call(t, x.e, x.a, http.MethodPost, sqlPath, as, map[string]any{"query": q})
	if got == http.StatusOK {
		t.Fatalf("%q RAN (200 %v): the SQL tab must refuse it with %d %s", q, body["rows"], status, code)
	}
	if got != status || body["error"] != code {
		t.Errorf("%q: %d %v, want %d %s", q, got, body, status, code)
	}
	if body["rows"] != nil {
		t.Errorf("%q: a refusal carries rows %v", q, body["rows"])
	}
	audits := x.auditRows(x.a, as)
	if len(audits) != before+1 || !strings.HasPrefix(audits[len(audits)-1], code) {
		t.Errorf("%q: audit %v after %d rows, want one more row starting %s", q, audits, before, code)
	}
}

func (x sqlEnv) onPostgres() bool {
	_, ok := x.e.st.(*store.Postgres)
	return ok
}

// TestReportingSQLRedControls (T060 GATE): the seven red controls of spec
// 143 (3.2, 3.3, 6.2), each refused with its code, and A still read after
// them.
func TestReportingSQLRedControls(t *testing.T) {
	x := newSQLEnv(t)
	admin := x.whoA[rbac.Admin]

	t.Run("cross_workspace", func(t *testing.T) {
		if !x.onPostgres() {
			t.Skip("needs the real executor under RLS (hub-pg.tst.sh)")
		}
		q := map[string]any{"query": "SELECT tenant_id FROM tenants WHERE tenant_id = '" + x.b + "'"}
		code, body := call(t, x.e, x.b, http.MethodPost, sqlPath, x.adminB, q)
		if code != http.StatusOK || body["row_count"] != float64(1) {
			t.Fatalf("control: B's admin reading B: %d %v, want 1 row, or the next check proves nothing", code, body)
		}
		code, body = call(t, x.e, x.a, http.MethodPost, sqlPath, admin, q)
		if code != http.StatusOK || body["row_count"] != float64(0) {
			t.Fatalf("A's admin naming B: %d %v, want 200 with 0 rows (RLS scope of A)", code, body)
		}
	})

	t.Run("write", func(t *testing.T) {
		for _, q := range []string{
			"INSERT INTO tenants (tenant_id) VALUES ('x')",
			"UPDATE messages SET body = 'x'",
			"DELETE FROM messages",
			"WITH d AS (DELETE FROM messages RETURNING 1) SELECT count(*) FROM d",
			"TRUNCATE messages",
			"SELECT * INTO sql_tab_probe FROM messages",
		} {
			x.sqlRefused(t, admin, q, http.StatusBadRequest, "read_only_violation")
		}
	})

	t.Run("ddl", func(t *testing.T) {
		for _, q := range []string{
			"DROP TABLE messages",
			"CREATE TABLE sql_tab_probe (x int)",
			"ALTER TABLE messages NO FORCE ROW LEVEL SECURITY",
			"ALTER TABLE messages RENAME TO m2",
		} {
			x.sqlRefused(t, admin, q, http.StatusBadRequest, "read_only_violation")
		}
	})

	t.Run("multi_statement", func(t *testing.T) {
		for _, q := range []string{
			"SELECT 1; SELECT 2",
			"SELECT 1; DROP TABLE messages;",
			"SELECT 1;;",
		} {
			x.sqlRefused(t, admin, q, http.StatusBadRequest, "single_statement_only")
		}
	})

	t.Run("set_role", func(t *testing.T) {
		for _, c := range []struct{ q, code string }{
			{"SET ROLE spool_app", "read_only_violation"},
			{"SET SESSION AUTHORIZATION spool_app", "read_only_violation"},
			{"RESET ROLE", "read_only_violation"},
			{"SELECT set_config('role', 'spool_app', true)", "forbidden_function"},
			{"SELECT set_config('app.rls_scope', 'operator', true)", "forbidden_function"},
			{"SELECT pg_catalog.set_config('app.tenant_id', 'x', true)", "forbidden_function"},
		} {
			x.sqlRefused(t, admin, c.q, http.StatusBadRequest, c.code)
		}
	})

	t.Run("timeout", func(t *testing.T) {
		if !x.onPostgres() {
			t.Skip("needs the real executor's statement_timeout (hub-pg.tst.sh)")
		}
		if store.ReportingSQLTimeout != 10*time.Second {
			t.Fatalf("ReportingSQLTimeout = %v, spec 143 3.2 says 10 s", store.ReportingSQLTimeout)
		}
		start := time.Now()
		x.sqlRefused(t, admin, "SELECT count(*) FROM generate_series(1, 2000000000::int8)", http.StatusRequestTimeout, "query_timeout")
		if d := time.Since(start); d < 9*time.Second || d > 30*time.Second {
			t.Errorf("cancelled after %v, want about the 10 s budget", d)
		}
	})

	t.Run("non_admin", func(t *testing.T) {
		for _, role := range rbac.RoleIDs {
			if role == rbac.Admin {
				continue
			}
			x.sqlRefused(t, x.whoA[role], "SELECT 1", http.StatusForbidden, "admin_required")
		}
		if code, body := call(t, x.e, x.a, http.MethodPost, sqlPath, x.adminB, map[string]any{"query": "SELECT 1"}); code != http.StatusForbidden {
			t.Errorf("B's admin in A: %d %v, want 403", code, body)
		}
	})

	code, body := call(t, x.e, x.a, http.MethodPost, sqlPath, admin, map[string]any{"query": "SELECT DISTINCT tenant_id FROM tenants"})
	if rows, _ := body["rows"].([]any); code != http.StatusOK || len(rows) != 1 || rows[0].([]any)[0] != x.a {
		t.Errorf("after the red controls A's admin still reads A: %d %v", code, body)
	}
}
