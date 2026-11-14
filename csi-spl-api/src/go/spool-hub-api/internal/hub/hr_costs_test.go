package hub_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-5433 (rdb 0280, spec 123 16.2; owner HUM-10, t1 2d974709, polls
// a82c0089 and 2ff12c21): the hub's clock on 2026-11-03, so 2026-10 is open
// (it closes on 6 Nov) and 2026-09 is closed. An internal_accountant enters a
// person (the name), reads the name back; the product owner reads the code
// only and enters no person. A line in the closed month is 409 month_closed,
// a correction in the open month is stored; only the admin reopens (with a
// reason) and closes. The month report sums a person's lines under the
// component's label, never the code. RED CONTROL: without hrMonthClosed in
// handleCostEntryCreate the 2026-09 line answers 201.
func TestHRCostsLockAndNames(t *testing.T) {
	r := newFleetTokensRig(t)
	r.offset.Store(int64(time.Until(time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC))))
	acc, po := seat(t, r.e, r.op, rbac.InternalAccountant), seat(t, r.e, r.op, rbac.ProductOwner)
	code := "H-" + digits4(newTenantID(""))

	if c, got := call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-components", acc, nil); c != http.StatusOK || len(got["components"].([]any)) < 20 {
		t.Fatalf("components: %d %v", c, got)
	}
	person := map[string]any{"code": code, "name": "FirstName LastName", "department": "Dev", "employment_type": "hourly", "birth_year": 1990}
	c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/hr-people", acc, person)
	pid, _ := got["id"].(string)
	if c != http.StatusCreated || pid == "" || got["name"] != "FirstName LastName" {
		t.Fatalf("accountant creates a person: %d %v", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/hr-people", acc, person); c != http.StatusConflict {
		t.Errorf("taken code: %d %v, want 409", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/hr-people", po, map[string]any{"code": "Q-01", "name": "x", "employment_type": "employee"}); c != http.StatusForbidden {
		t.Errorf("product owner creates a person: %d %v, want 403", c, got)
	}
	nameOf := func(as string) (bool, string) {
		c, got := call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-people", as, nil)
		if c != http.StatusOK {
			t.Fatalf("people as %s: %d %v", as, c, got)
		}
		for _, x := range got["people"].([]any) {
			if p := x.(map[string]any); p["id"] == pid {
				n, _ := p["name"].(string)
				return got["names"] == true, n
			}
		}
		t.Fatalf("person %s not listed", pid)
		return false, ""
	}
	if names, n := nameOf(acc); !names || n != "FirstName LastName" {
		t.Errorf("accountant reads names %v %q, want the name", names, n)
	}
	if names, n := nameOf(po); names || n != "" {
		t.Errorf("product owner reads names %v %q, want none", names, n)
	}

	line := func(period, corrects string) map[string]any {
		m := map[string]any{"type": "hr", "label": code + " hourly pay", "amount": 1000, "currency": "EUR", "period": period,
			"person_id": pid, "component": "hourly_pay", "source": "payslip " + period}
		if corrects != "" {
			m["corrects_period"] = corrects
		}
		return m
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, acc, line("2026-10", "")); c != http.StatusCreated || got["person_id"] != pid || got["component"] != "hourly_pay" {
		t.Errorf("open month: %d %v, want 201", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, acc, line("2026-09", "")); c != http.StatusConflict || got["error"] != "month_closed" {
		t.Errorf("closed month: %d %v, want 409 month_closed", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, acc, line("2026-10", "2026-09")); c != http.StatusCreated || got["corrects_period"] != "2026-09" {
		t.Errorf("correction: %d %v, want 201", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, acc, map[string]any{"type": "hr", "label": "x", "amount": 1, "currency": "EUR", "period": "2026-10", "person_id": pid, "component": "no_such"}); c != http.StatusBadRequest {
		t.Errorf("unknown component: %d %v, want 400", c, got)
	}

	period := "/v1/operator/cost-periods/2026-09"
	if c, got := call(t, r.e, r.op, http.MethodGet, period, acc, nil); c != http.StatusOK || got["closed"] != true {
		t.Errorf("state: %d %v, want closed", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, period+"/reopen", acc, map[string]any{"reason": "late payslip"}); c != http.StatusForbidden {
		t.Errorf("accountant reopens: %d %v, want 403", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, period+"/reopen", r.admin, map[string]any{"reason": " "}); c != http.StatusBadRequest {
		t.Errorf("reopen, no reason: %d %v, want 400", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, period+"/reopen", r.admin, map[string]any{"reason": "late payslip"}); c != http.StatusOK || got["closed"] != false || got["reopen_reason"] != "late payslip" {
		t.Fatalf("admin reopens: %d %v", c, got)
	}
	c, got = call(t, r.e, r.op, http.MethodPost, costEntryPath, acc, line("2026-09", ""))
	late, _ := got["id"].(string)
	if c != http.StatusCreated {
		t.Fatalf("reopened month: %d %v, want 201", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, period+"/close", r.admin, nil); c != http.StatusOK || got["closed"] != true {
		t.Fatalf("admin closes: %d %v", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+late, acc, nil); c != http.StatusConflict {
		t.Errorf("delete in a closed month: %d %v, want 409", c, got)
	}

	c, rep := call(t, r.e, r.op, http.MethodGet, "/v1/tenant/costs?month=2026-10", r.admin, nil)
	raw, _ := json.Marshal(rep)
	if c != http.StatusOK || strings.Contains(string(raw), code) || !strings.Contains(string(raw), "Hourly pay (hours x rate)") {
		t.Errorf("month report: %d; want the component's label and never the code %s: %s", c, code, raw)
	}
}

// digits4 is 4 digits made from s.
func digits4(s string) string {
	out := []byte{}
	for i := 0; len(out) < 4; i++ {
		out = append(out, '0'+s[i%len(s)]%10)
	}
	return string(out)
}

// reopenMonth has the admin reopen month, past its 6th-of-next-month close
// (SPL-5433), so a test that writes hr lines into an old month still can.
func reopenMonth(t *testing.T, r *fleetTokensRig, month string) {
	t.Helper()
	if c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/cost-periods/"+month+"/reopen", r.admin, map[string]any{"reason": "test fixture month"}); c != http.StatusOK {
		t.Fatalf("reopen %s: %d %v", month, c, got)
	}
}

// SPL-5433: /v1/view/me's cost_writer is true for a costs.write member of the
// operator workspace (the internal_accountant, the admin), false for its
// product owner and for an accountant of another workspace: the WUI opens
// Expenses -> Cloud infra and HR on it. RED CONTROL: without the line that
// sets CostWriter in handleViewMe the accountant reads false.
func TestViewMeCostWriter(t *testing.T) {
	r := newFleetTokensRig(t)
	for _, c := range []struct {
		name, tenant, as string
		want             bool
	}{
		{"operator internal_accountant", r.op, seat(t, r.e, r.op, rbac.InternalAccountant), true},
		{"operator admin", r.op, r.admin, true},
		{"operator product owner", r.op, seat(t, r.e, r.op, rbac.ProductOwner), false},
		{"another workspace's accountant", r.other, seat(t, r.e, r.other, rbac.InternalAccountant), false},
	} {
		code, got := call(t, r.e, c.tenant, http.MethodGet, "/v1/view/me", c.as, nil)
		if code != http.StatusOK || got["cost_writer"] != c.want {
			t.Errorf("%s: %d cost_writer %v, want %v", c.name, code, got["cost_writer"], c.want)
		}
	}
}
