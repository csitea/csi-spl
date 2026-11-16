package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-5433 step d (rdb 0286, spec 123 16.5; owner HUM-10, t1 2d974709, poll
// 2ff12c21 answer 4 B), made-up figures in 2005 (no other test uses that
// year). An internal_accountant sets the year's worker-share bands, a
// person's tax card and a payslip; the payroll then carries the worker side
// for them: the shares by age band, the tax over the year-to-date gross
// (January counted, so part of March is above the card's limit), the payslip's
// tax winning and flagged, the net. The product owner reads the bands but no
// tax card, and the payroll they read has no worker side; the employer side's
// cost is unchanged by it. A payslip in a closed month is 409 month_closed.
// RED CONTROL: without the readsHRNames check in handleHRPayroll the product
// owner's payroll carries "worker" and the test fails.
func TestHRPayrollWorkerSide(t *testing.T) {
	r := newFleetTokensRig(t)
	acc, po := seat(t, r.e, r.op, rbac.InternalAccountant), seat(t, r.e, r.op, rbac.ProductOwner)
	const month, year = "2005-03", "2005"
	reopenMonth(t, r, "2005-01")
	reopenMonth(t, r, month)
	code := "W-" + digits4(newTenantID(""))
	c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/hr-people", acc,
		map[string]any{"code": code, "name": "FirstName LastName", "employment_type": "employee", "birth_year": 1970})
	pid, _ := got["id"].(string)
	if c != http.StatusCreated || pid == "" {
		t.Fatalf("person: %d %v", c, got)
	}
	for _, m := range []string{"2005-01", month} {
		l := map[string]any{"type": "hr", "label": "test line", "currency": "EUR", "period": m, "person_id": pid,
			"component": "monthly_salary", "amount": 3000, "source": "payslip"}
		if c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/cost-entries", acc, l); c != http.StatusCreated {
			t.Fatalf("line %s: %d %v", m, c, got)
		}
	}

	bands := func(as, kind string, pct float64) (int, map[string]any) {
		return call(t, r.e, r.op, http.MethodPut, "/v1/operator/hr-worker-rates/"+year+"/"+kind, as,
			map[string]any{"bands": []map[string]any{{"age_from": 17, "age_to": 64, "rate_pct": pct}}, "source": "made-up"})
	}
	if c, got := bands(po, "tyel_employee", 7); c != http.StatusForbidden || got["permission"] != "operator.workspaces" {
		t.Errorf("product owner sets bands: %d %v, want 403 operator.workspaces", c, got)
	}
	if c, got := bands(acc, "tax", 7); c != http.StatusBadRequest {
		t.Errorf("bands of no share: %d %v, want 400", c, got)
	}
	if c, got := bands(acc, "tyel_employee", 7); c != http.StatusOK || len(got["rates"].([]any)) != 1 {
		t.Fatalf("accountant sets tyel bands: %d %v", c, got)
	}
	if c, got := bands(acc, "unemployment_employee", 1); c != http.StatusOK {
		t.Fatalf("accountant sets unemployment bands: %d %v", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-worker-rates?year="+year, po, nil); c != http.StatusOK || len(got["rates"].([]any)) != 2 {
		t.Errorf("product owner reads the bands: %d %v", c, got)
	}

	card := map[string]any{"base_pct": 20, "extra_pct": 40, "income_limit": 5000, "source": "made-up"}
	if c, got := call(t, r.e, r.op, http.MethodPut, "/v1/operator/hr-tax-cards/"+pid+"/"+year, acc, card); c != http.StatusOK || got["income_limit"] != 5000.0 {
		t.Fatalf("accountant sets the tax card: %d %v", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPut, "/v1/operator/hr-tax-cards/00000000-0000-4000-8000-000000000000/"+year, acc, card); c != http.StatusNotFound {
		t.Errorf("tax card of no person: %d %v, want 404", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-tax-cards?year="+year, po, nil); c != http.StatusForbidden || got["permission"] != "costs.write" {
		t.Errorf("product owner reads tax cards: %d %v, want 403 costs.write", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPut, "/v1/operator/hr-payslips/"+month+"/"+pid, acc,
		map[string]any{"currency": "EUR", "tax_withheld": 999}); c != http.StatusOK || got["tax_withheld"] != 999.0 {
		t.Fatalf("accountant types the payslip: %d %v", c, got)
	}

	worker := func(p map[string]any) map[string]any {
		for _, x := range p["worker"].([]any) {
			if w := x.(map[string]any); w["person_id"] == pid {
				return w
			}
		}
		t.Fatalf("person %s has no worker side: %v", pid, p["worker"])
		return nil
	}
	c, got = call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-payroll/"+month, acc, nil)
	if c != http.StatusOK {
		t.Fatalf("payroll: %d %v", c, got)
	}
	w := worker(got)
	shares := w["shares"].([]any)
	tax, net := w["tax"].(map[string]any), w["net"].(map[string]any)
	// age 35; tyel 7% = 210, unemployment 1% = 30; tax 2000 x 20% + 1000 x 40% = 800, payslip 999 wins; net 3000 - 240 - 999
	if w["age"] != 35.0 || w["ytd_before"] != 3000.0 || w["ytd"] != 6000.0 || len(shares) != 2 ||
		shares[0].(map[string]any)["computed"] != 210.0 || shares[1].(map[string]any)["computed"] != 30.0 {
		t.Errorf("worker side: %v", w)
	}
	if tax["computed"] != 800.0 || tax["typed"] != 999.0 || tax["flag"] != "diff" || net["computed"] != 1761.0 || w["flags"] != 1.0 {
		t.Errorf("tax and net: %v %v", tax, net)
	}
	for _, x := range got["people"].([]any) {
		if row := x.(map[string]any); row["person_id"] == pid && row["cost"] != 3000.0 {
			t.Errorf("the worker side changed the cost: %v", row)
		}
	}
	if c, got := call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-payroll/"+month, po, nil); c != http.StatusOK || got["worker"] != nil {
		t.Errorf("product owner's payroll: %d, worker %v, want 200 and none", c, got["worker"])
	}

	if c, got := call(t, r.e, r.op, http.MethodDelete, "/v1/operator/hr-payslips/"+month+"/"+pid+"?currency=EUR", acc, nil); c != http.StatusNoContent {
		t.Errorf("delete payslip: %d %v", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/cost-periods/"+month+"/close", r.admin, nil); c != http.StatusOK {
		t.Fatalf("close: %d %v", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPut, "/v1/operator/hr-payslips/"+month+"/"+pid, acc,
		map[string]any{"net_pay": 1}); c != http.StatusConflict || got["error"] != "month_closed" {
		t.Errorf("payslip in a closed month: %d %v, want 409 month_closed", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodDelete, "/v1/operator/hr-tax-cards/"+pid+"/"+year, acc, nil); c != http.StatusNoContent {
		t.Errorf("delete tax card: %d %v", c, got)
	}
}

// SPL-5433 step d: every new route refuses each wrong caller with the exact
// 403 operator.workspaces (a developer of the operator workspace, another
// workspace's admin and its internal_accountant, an anonymous caller, a live
// act-as clone of the operator admin on Postgres). The product owner reads the
// bands, is refused the tax cards with 403 costs.write (personal) and every
// write with 403 operator.workspaces. CONTROL: the accountant's tax card read
// is 200, so each refusal is the caller's.
func TestHRWorkerRefusesWrongRoles(t *testing.T) {
	r := newFleetTokensRig(t)
	const month, year = "2005-06", "2005"
	pid := "00000000-0000-4000-8000-000000000000"
	acc := seat(t, r.e, r.op, rbac.InternalAccountant)
	if c, got := call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-tax-cards?year="+year, acc, nil); c != http.StatusOK {
		t.Fatalf("CONTROL accountant reads tax cards: %d %v", c, got)
	}
	bodies := map[string]any{
		"/v1/operator/hr-worker-rates/" + year + "/tyel_employee": map[string]any{"bands": []any{}, "source": "x"},
		"/v1/operator/hr-tax-cards/" + pid + "/" + year:           map[string]any{"base_pct": 1, "extra_pct": 2, "income_limit": 3},
		"/v1/operator/hr-payslips/" + month + "/" + pid:           map[string]any{"net_pay": 1},
	}
	reads := [][2]string{{http.MethodGet, "/v1/operator/hr-worker-rates?year=" + year}, {http.MethodGet, "/v1/operator/hr-tax-cards?year=" + year}}
	writes := [][2]string{{http.MethodPut, "/v1/operator/hr-worker-rates/" + year + "/tyel_employee"},
		{http.MethodPut, "/v1/operator/hr-tax-cards/" + pid + "/" + year}, {http.MethodDelete, "/v1/operator/hr-tax-cards/" + pid + "/" + year},
		{http.MethodPut, "/v1/operator/hr-payslips/" + month + "/" + pid}, {http.MethodDelete, "/v1/operator/hr-payslips/" + month + "/" + pid}}
	refuse := func(name, tid, as, perm string, routes [][2]string) {
		t.Helper()
		for _, rt := range routes {
			var body any
			if rt[0] == http.MethodPut {
				body = bodies[rt[1]]
			}
			if c, got := call(t, r.e, tid, rt[0], rt[1], as, body); c != http.StatusForbidden || got["permission"] != perm {
				t.Errorf("%s %s %s: %d %v, want 403 %s", name, rt[0], rt[1], c, got, perm)
			}
		}
	}
	all := append(append([][2]string{}, reads...), writes...)
	refuse("operator developer", r.op, r.dev, "operator.workspaces", all)
	refuse("other workspace admin", r.other, r.otherA, "operator.workspaces", all)
	refuse("other workspace accountant", r.other, seat(t, r.e, r.other, rbac.InternalAccountant), "operator.workspaces", all)
	refuse("anonymous", r.op, "", "operator.workspaces", all)
	po := seat(t, r.e, r.op, rbac.ProductOwner)
	refuse("product owner", r.op, po, "operator.workspaces", writes)
	refuse("product owner", r.op, po, "costs.write", reads[1:])
	if c, got := call(t, r.e, r.op, reads[0][0], reads[0][1], po, nil); c != http.StatusOK {
		t.Errorf("product owner reads the bands: %d %v, want 200", c, got)
	}
	if cs, ok := r.e.st.(dmCloneStore); ok {
		now := time.Now().UTC().Truncate(time.Microsecond)
		cl, err := cs.StartClone(context.Background(), store.CloneStart{TenantID: r.op, TargetHum: r.admin, AdminName: "Admin",
			CreatedBy: r.admin, ExpiresAt: now.Add(time.Hour)}, now)
		if err != nil {
			t.Fatal(err)
		}
		refuse("act-as clone of the admin", r.op, cl.CloneHum, "operator.workspaces", all)
	} else {
		t.Log("act-as clone half skipped: needs Postgres (SPOOL_TEST_PG_DSN)")
	}
}
