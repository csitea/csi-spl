package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/jackc/pgx/v5"
)

// Spec 143 T032 (SPL-2789): POST /v1/reporting/sql. On Postgres
// (hub-pg.tst.sh) the real executor runs under RLS; on the memory store a
// stand-in answers the one query the tests send, for the tenant the hub
// passed, so the role, the guard, the tenant and the audit rules are proved
// on both. The executor's own red controls are store/reporting_sql_test.go.

const sqlPath = "/v1/reporting/sql"

// sqlStub is the memory store's stand-in for the executor and the audit.
type sqlStub struct {
	*store.Memory
	mu       sync.Mutex
	audits   []store.ReportingSQLAudit
	failNext bool
}

func (s *sqlStub) RunReportingSQL(_ context.Context, tenant, _ string) (store.ReportingSQLResult, error) {
	v := tenant
	return store.ReportingSQLResult{Columns: []store.ReportingSQLColumn{{Name: "tenant_id", Type: "text"}},
		Rows: [][]*string{{&v}}}, nil
}

func (s *sqlStub) AuditReportingSQL(_ context.Context, a store.ReportingSQLAudit) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failNext {
		s.failNext = false
		return errors.New("audit down")
	}
	s.audits = append(s.audits, a)
	return nil
}

type sqlEnv struct {
	e         *env
	a, b      string
	whoA      map[string]string
	adminB    string
	stub      *sqlStub
	auditRows func(tenant, human string) []string
}

// newSQLEnv makes workspaces A and B, one member per role in A, an admin
// in B.
func newSQLEnv(t *testing.T) sqlEnv {
	t.Helper()
	x := sqlEnv{a: newTenantID("sa"), b: newTenantID("sb"), whoA: map[string]string{}}
	x.e = rbacEnv(t, func(o *hub.Options) {
		if m, ok := o.Store.(*store.Memory); ok {
			x.stub = &sqlStub{Memory: m}
			o.Store = x.stub
		}
	})
	ctx := context.Background()
	for _, id := range []string{x.a, x.b} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := x.e.st.CreateTenant(ctx, store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	for _, r := range rbac.RoleIDs {
		x.whoA[r] = seat(t, x.e, x.a, r)
	}
	x.adminB = seat(t, x.e, x.b, rbac.Admin)
	x.auditRows = func(tenant, human string) []string { return x.stubAudits(tenant, human) }
	if pg, ok := x.e.st.(*store.Postgres); ok {
		x.auditRows = func(tenant, human string) []string { return pgAudits(t, pg, tenant, human) }
	}
	return x
}

func (x sqlEnv) stubAudits(tenant, human string) []string {
	x.stub.mu.Lock()
	defer x.stub.mu.Unlock()
	var out []string
	for _, a := range x.stub.audits {
		if a.Tenant == tenant && a.Human == human {
			out = append(out, a.Error)
		}
	}
	return out
}

// pgAudits reads the audit rows in tenant's own scope, oldest first.
func pgAudits(t *testing.T, pg *store.Postgres, tenant, human string) []string {
	t.Helper()
	var out []string
	ctx := context.Background()
	err := pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT error_message FROM sql_query_audit WHERE human_id = $1 ORDER BY executed_at, audit_id`, human)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, pgx.RowTo[string])
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// TestReportingSQLRoute (T032 GATE): A's admin runs a SELECT and reads its
// own workspace only; the answer has the spec 3.7 shape; the attempt is
// audited in A and not in B.
func TestReportingSQLRoute(t *testing.T) {
	x := newSQLEnv(t)
	q := map[string]any{"query": "SELECT DISTINCT tenant_id FROM tenants;"}
	code, body := call(t, x.e, x.a, http.MethodPost, sqlPath, x.whoA[rbac.Admin], q)
	if code != http.StatusOK {
		t.Fatalf("admin: %d %v", code, body)
	}
	cols, _ := body["columns"].([]any)
	rows, _ := body["rows"].([]any)
	if len(cols) != 1 || cols[0].(map[string]any)["name"] != "tenant_id" || len(rows) != 1 {
		t.Fatalf("shape: %v", body)
	}
	if got := rows[0].([]any)[0]; got != x.a {
		t.Fatalf("A's admin read tenant %v, want only %s", got, x.a)
	}
	if body["row_count"] != float64(1) || body["truncated"] != false || body["duration_ms"] == nil {
		t.Errorf("row_count/truncated/duration_ms: %v", body)
	}
	if got := x.auditRows(x.a, x.whoA[rbac.Admin]); len(got) != 1 || got[0] != "" {
		t.Errorf("A's audit of the run: %v, want one clean row", got)
	}
	if got := x.auditRows(x.b, x.whoA[rbac.Admin]); len(got) != 0 {
		t.Errorf("B's audit holds A's run: %v", got)
	}
	code, body = call(t, x.e, x.b, http.MethodPost, sqlPath, x.adminB, q)
	if rows, _ := body["rows"].([]any); code != http.StatusOK || len(rows) != 1 || rows[0].([]any)[0] != x.b {
		t.Errorf("B's admin: %d %v, want only %s", code, body, x.b)
	}
}

// TestReportingSQLNonAdmin (T032 RED CONTROL, spec red control
// "non-admin"): every role of A but admin gets 403 admin_required, and the
// attempt is audited; no session is refused before any audit.
func TestReportingSQLNonAdmin(t *testing.T) {
	x := newSQLEnv(t)
	q := map[string]any{"query": "SELECT 1"}
	for _, role := range rbac.RoleIDs {
		code, body := call(t, x.e, x.a, http.MethodPost, sqlPath, x.whoA[role], q)
		want := http.StatusForbidden
		if role == rbac.Admin {
			want = http.StatusOK
		}
		if code != want || (want == http.StatusForbidden && body["error"] != "admin_required") {
			t.Errorf("%s: %d %v, want %d", role, code, body, want)
		}
		if role == rbac.Admin {
			continue
		}
		if got := x.auditRows(x.a, x.whoA[role]); len(got) != 1 || got[0] != "admin_required" {
			t.Errorf("%s: audit %v, want one admin_required row", role, got)
		}
	}
	if code, _ := call(t, x.e, x.a, http.MethodPost, sqlPath, "", q); code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Errorf("no session: %d, want 401 or 403", code)
	}
	if code, body := call(t, x.e, x.a, http.MethodPost, sqlPath, x.adminB, q); code != http.StatusForbidden {
		t.Errorf("B's admin in A: %d %v, want 403", code, body)
	}
}

// TestReportingSQLRefusals: the guard's refusals reach the admin with their
// codes, each one audited with its reason.
func TestReportingSQLRefusals(t *testing.T) {
	x := newSQLEnv(t)
	admin := x.whoA[rbac.Admin]
	cases := []struct{ q, code string }{
		{"SELECT 1; DROP TABLE messages;", "single_statement_only"},
		{"DELETE FROM messages", "read_only_violation"},
		{"DROP TABLE messages", "read_only_violation"},
		{"SET ROLE spool_hub", "read_only_violation"},
		{"SELECT set_config('app.rls_scope', 'operator', true)", "forbidden_function"},
	}
	for _, c := range cases {
		code, body := call(t, x.e, x.a, http.MethodPost, sqlPath, admin, map[string]any{"query": c.q})
		if code != http.StatusBadRequest || body["error"] != c.code {
			t.Errorf("%q: %d %v, want 400 %s", c.q, code, body, c.code)
		}
	}
	got := x.auditRows(x.a, admin)
	if len(got) != len(cases) {
		t.Fatalf("audit rows %d, want %d: %v", len(got), len(cases), got)
	}
	if code, body := call(t, x.e, x.a, http.MethodPost, sqlPath, admin, map[string]any{"sql": "SELECT 1"}); code != http.StatusBadRequest || body["error"] != "bad_json" {
		t.Errorf("unknown field: %d %v, want bad_json", code, body)
	}
}

// TestReportingSQLAuditFirst (memory store only): a result whose audit row
// cannot be written is withheld (500 audit_failed).
func TestReportingSQLAuditFirst(t *testing.T) {
	x := newSQLEnv(t)
	if x.stub == nil {
		t.Skip("the stand-in fails the audit write; Postgres does not on demand")
	}
	x.stub.failNext = true
	code, body := call(t, x.e, x.a, http.MethodPost, sqlPath, x.whoA[rbac.Admin], map[string]any{"query": "SELECT 1"})
	if code != http.StatusInternalServerError || body["error"] != "audit_failed" || body["rows"] != nil {
		t.Fatalf("audit down: %d %v, want 500 audit_failed and no rows", code, body)
	}
}
