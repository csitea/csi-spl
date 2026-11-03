package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-4697: Reporting -> Incomes. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (rdb 0256's RLS). RED CONTROL (base): neither route
// existed, every call answered 404.

const (
	incomesReportPath = "/v1/reporting/incomes"
	incomesImportPath = "/v1/operator/incomes"
)

// incomeJSON is a synthetic invoice: no real figure or payer (csi-spl is public).
func incomeJSON(no, month string) map[string]any {
	return map[string]any{"invoice_no": no, "payer": "ACME", "period": month, "issue_date": month + "-28",
		"due_date": month + "-28", "hours": 10, "unit_price": 10, "net": 100, "vat_pct": 25, "vat": 25, "total": 125, "currency": "EUR"}
}

// TestReportingIncomesRoutes: the operator's admin imports into a workspace
// (an upsert: the same batch again only updates); a non-operator import is
// 403, a bad row is 400 with its index, an unknown workspace 404. The
// workspace's owner (biz_owner) reads its year; every other role, the
// operator's admin of another workspace and the anonymous guest get 403
// tenant.owner. CONTROL: the owner's read answers 200 with the rows.
func TestReportingIncomesRoutes(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	batch := map[string]any{"tenant": other, "invoices": []any{incomeJSON("INV-0001", "2025-02"), incomeJSON("INV-0002", "2025-03")}}
	for name, as := range map[string][2]string{"workspace admin": {other, whoOther[rbac.Admin]}, "operator developer": {op, who[rbac.Developer]}, "anonymous": {op, ""}} {
		if code, got := call(t, e, as[0], http.MethodPut, incomesImportPath, as[1], batch); code != http.StatusForbidden {
			t.Errorf("import as %s: %d %v, want 403", name, code, got)
		}
	}
	if code, got := call(t, e, op, http.MethodPut, incomesImportPath, who[rbac.Admin], batch); code != http.StatusOK || got["inserted"] != 2.0 || got["updated"] != 0.0 {
		t.Fatalf("import: %d %v, want 2 inserted", code, got)
	}
	if code, got := call(t, e, op, http.MethodPut, incomesImportPath, who[rbac.Admin], batch); code != http.StatusOK || got["inserted"] != 0.0 || got["updated"] != 2.0 {
		t.Fatalf("import again: %d %v, want 2 updated", code, got)
	}
	bad := incomeJSON("INV-0003", "2025-04")
	bad["total"] = 126
	if code, got := call(t, e, op, http.MethodPut, incomesImportPath, who[rbac.Admin],
		map[string]any{"tenant": other, "invoices": []any{incomeJSON("INV-0004", "2025-05"), bad}}); code != http.StatusBadRequest || got["index"] != 1.0 {
		t.Errorf("bad row: %d %v, want 400 index 1", code, got)
	}
	if code, got := call(t, e, op, http.MethodPut, incomesImportPath, who[rbac.Admin],
		map[string]any{"tenant": "t-nope-" + other, "invoices": []any{incomeJSON("INV-0005", "2025-05")}}); code != http.StatusNotFound {
		t.Errorf("unknown workspace: %d %v, want 404", code, got)
	}
	for _, role := range rbac.RoleIDs {
		code, got := call(t, e, other, http.MethodGet, incomesReportPath+"?year=2025", whoOther[role], nil)
		if role != rbac.BizOwner {
			if code != http.StatusForbidden || got["permission"] != "tenant.owner" {
				t.Errorf("%s: %d %v, want 403 tenant.owner", role, code, got)
			}
			continue
		}
		inv, _ := got["invoices"].([]any)
		if code != http.StatusOK || got["year"] != 2025.0 || len(inv) != 2 || inv[0].(map[string]any)["invoice_no"] != "INV-0001" {
			t.Fatalf("CONTROL owner: %d %v", code, got)
		}
	}
	if code, got := call(t, e, other, http.MethodGet, incomesReportPath, whoOther[rbac.BizOwner], nil); code != http.StatusOK || got["year"] != 2025.0 {
		t.Errorf("no year = the newest with rows: %d %v", code, got)
	}
	if code, got := call(t, e, other, http.MethodGet, incomesReportPath+"?year=25", whoOther[rbac.BizOwner], nil); code != http.StatusBadRequest {
		t.Errorf("bad year: %d %v, want 400", code, got)
	}
	if code, got := call(t, e, other, http.MethodGet, incomesReportPath, "", nil); code != http.StatusForbidden {
		t.Errorf("anonymous: %d %v, want 403", code, got)
	}
	for _, role := range []string{rbac.BizOwner, rbac.Admin} {
		if code, got := call(t, e, other, http.MethodGet, incomesReportPath+"?year=2025", who[role], nil); code != http.StatusForbidden {
			t.Errorf("the operator's %s on another workspace's host: %d %v, want 403", role, code, got)
		}
	}
	code, got := call(t, e, op, http.MethodGet, incomesReportPath+"?year=2025", who[rbac.BizOwner], nil)
	if inv, _ := got["invoices"].([]any); code != http.StatusOK || len(inv) != 0 {
		t.Errorf("another workspace's owner: %d %v, want none of these rows", code, got)
	}
}

// TestReportingIncomesNotInSQLTab (Postgres only: the memory store has no
// SQL executor): the workspace's admin, refused the owner's read, is also
// refused the rows through the Reporting SQL tab (forbidden_relation).
// RED CONTROL (a6b728201, c-357 W1): the SQL tab answered 200 with the row.
func TestReportingIncomesNotInSQLTab(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("Postgres only (hub-pg.tst.sh): the memory store has no SQL executor")
	}
	batch := map[string]any{"tenant": other, "invoices": []any{incomeJSON("INV-0001", "2025-02")}}
	if code, got := call(t, e, op, http.MethodPut, incomesImportPath, who[rbac.Admin], batch); code != http.StatusOK {
		t.Fatalf("import: %d %v", code, got)
	}
	if code, got := call(t, e, other, http.MethodGet, incomesReportPath+"?year=2025", whoOther[rbac.Admin], nil); code != http.StatusForbidden {
		t.Errorf("admin's owner read: %d %v, want 403", code, got)
	}
	q := map[string]any{"query": "SELECT invoice_no, payer, total FROM income_invoices"}
	if code, got := call(t, e, other, http.MethodPost, sqlPath, whoOther[rbac.Admin], q); code != http.StatusBadRequest || got["error"] != "forbidden_relation" {
		t.Errorf("admin's SQL-tab read of income_invoices: %d %v, want 400 forbidden_relation", code, got)
	}
	if code, got := call(t, e, other, http.MethodPost, sqlPath, whoOther[rbac.Admin], map[string]any{"query": "SELECT 1"}); code != http.StatusOK {
		t.Errorf("CONTROL admin's SQL tab: %d %v, want 200", code, got)
	}
}
