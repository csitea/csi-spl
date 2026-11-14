package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-5433 step c (rdb 0284, spec 123 16.4; owner HUM-10, t1 2d974709, poll
// 2ff12c21 answer 4 B), made-up figures in 2007-04 (no other test books that
// year). An internal_accountant sets the year's rates (the product owner may
// not; a pay component takes none), reads the employer side computed from
// gross (a typed payslip value wins and its difference is flagged), books the
// computed amounts as lines (which the cost entries list then carries), and a
// second book changes nothing; after a rate change the booked line is stale
// and the next book replaces it. A closed month is 409 month_closed. RED
// CONTROL: without the HRStaleBooked removal in handleHRPayrollBook the
// rebook leaves two tyel lines and the person's employer total doubles.
func TestHRPayrollEmployerSide(t *testing.T) {
	r := newFleetTokensRig(t)
	acc, po := seat(t, r.e, r.op, rbac.InternalAccountant), seat(t, r.e, r.op, rbac.ProductOwner)
	const month, year = "2007-04", "2007"
	for _, c := range []string{"tyel_employer", "unemployment_employer"} {
		call(t, r.e, r.op, http.MethodDelete, "/v1/operator/hr-rates/"+year+"/"+c, r.admin, nil)
	}
	reopenMonth(t, r, month)
	code := "R-" + digits4(newTenantID(""))
	c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/hr-people", acc,
		map[string]any{"code": code, "name": "FirstName LastName", "employment_type": "employee"})
	pid, _ := got["id"].(string)
	if c != http.StatusCreated || pid == "" {
		t.Fatalf("person: %d %v", c, got)
	}
	for _, l := range []map[string]any{
		{"component": "monthly_salary", "amount": 4000, "source": "payslip"},
		{"component": "overtime", "amount": 200, "source": "payslip"},
		{"component": "lunch_benefit", "amount": 100},
		{"component": "unemployment_employer", "amount": 9, "source": "payslip"},
	} {
		l["type"], l["label"], l["currency"], l["period"], l["person_id"] = "hr", "test line", "EUR", month, pid
		if c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/cost-entries", acc, l); c != http.StatusCreated {
			t.Fatalf("line %v: %d %v", l["component"], c, got)
		}
	}

	rate := func(as, comp string, pct float64) (int, map[string]any) {
		return call(t, r.e, r.op, http.MethodPut, "/v1/operator/hr-rates/"+year+"/"+comp, as,
			map[string]any{"rate_pct": pct, "applies_to": []string{"employee"}, "source": "made-up"})
	}
	if c, got := rate(po, "tyel_employer", 10); c == http.StatusOK {
		t.Errorf("product owner sets a rate: %d %v", c, got)
	}
	if c, got := rate(acc, "monthly_salary", 10); c != http.StatusBadRequest {
		t.Errorf("rate on a pay component: %d %v, want 400", c, got)
	}
	if c, got := rate(acc, "tyel_employer", 10); c != http.StatusOK || got["rate_pct"] != 10.0 || got["set_by"] != acc {
		t.Fatalf("accountant sets tyel: %d %v", c, got)
	}
	if c, got := rate(acc, "unemployment_employer", 0.2); c != http.StatusOK {
		t.Fatalf("accountant sets unemployment: %d %v", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-rates?year="+year, po, nil); c != http.StatusOK || len(got["rates"].([]any)) != 2 {
		t.Fatalf("product owner reads the rates: %d %v", c, got)
	}

	// mine is the person's payroll row and its employer lines by component.
	mine := func(p map[string]any) (map[string]any, map[string]map[string]any) {
		for _, x := range p["people"].([]any) {
			if row := x.(map[string]any); row["person_id"] == pid {
				by := map[string]map[string]any{}
				for _, l := range row["employer"].([]any) {
					by[l.(map[string]any)["component"].(string)] = l.(map[string]any)
				}
				return row, by
			}
		}
		t.Fatalf("person %s not in the payroll: %v", pid, p)
		return nil, nil
	}
	c, got = call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-payroll/"+month, acc, nil)
	if c != http.StatusOK {
		t.Fatalf("payroll: %d %v", c, got)
	}
	row, by := mine(got)
	if row["gross"] != 4200.0 || row["other"] != 100.0 {
		t.Errorf("gross/other: %v", row)
	}
	if l := by["tyel_employer"]; l["computed"] != 420.0 || l["amount"] != 420.0 || l["typed"] != nil {
		t.Errorf("tyel computed: %v", l)
	}
	if l := by["unemployment_employer"]; l["computed"] != 8.4 || l["typed"] != 9.0 || l["amount"] != 9.0 || l["flag"] != "diff" {
		t.Errorf("unemployment typed wins, flagged: %v", l)
	}
	if row["employer_total"] != 429.0 || row["cost"] != 4729.0 || row["flags"] != 1.0 {
		t.Errorf("totals: %v", row)
	}

	book := func() map[string]any {
		c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/hr-payroll/"+month+"/book", acc, nil)
		if c != http.StatusOK {
			t.Fatalf("book: %d %v", c, got)
		}
		return got
	}
	tyelLines := func() []map[string]any {
		_, got := call(t, r.e, r.op, http.MethodGet, "/v1/operator/cost-entries?type=hr&month="+month, acc, nil)
		var out []map[string]any
		for _, x := range got["entries"].([]any) {
			if e := x.(map[string]any); e["person_id"] == pid && e["component"] == "tyel_employer" {
				out = append(out, e)
			}
		}
		return out
	}
	got = book()
	if ls := tyelLines(); len(ls) != 1 || ls[0]["amount"] != 420.0 || ls[0]["source"] != "computed: 2007 rates" {
		t.Fatalf("booked tyel: %v", ls)
	}
	if row, by := mine(got["payroll"].(map[string]any)); by["tyel_employer"]["booked"] != 420.0 || row["cost"] != 4729.0 {
		t.Errorf("after book: %v %v", row, by["tyel_employer"])
	}
	book()
	if ls := tyelLines(); len(ls) != 1 {
		t.Fatalf("second book duplicated: %v", ls)
	}

	if c, got := rate(acc, "tyel_employer", 12); c != http.StatusOK {
		t.Fatalf("rate change: %d %v", c, got)
	}
	_, got = call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-payroll/"+month, acc, nil)
	if _, by := mine(got); by["tyel_employer"]["flag"] != "stale" || by["tyel_employer"]["computed"] != 504.0 {
		t.Errorf("after the rate change: %v", by["tyel_employer"])
	}
	got = book()
	if ls := tyelLines(); len(ls) != 1 || ls[0]["amount"] != 504.0 {
		t.Fatalf("rebook: %v", ls)
	}
	if row, _ := mine(got["payroll"].(map[string]any)); row["employer_total"] != 513.0 || row["flags"] != 1.0 {
		t.Errorf("after rebook: %v", row)
	}

	if c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/cost-periods/"+month+"/close", r.admin, nil); c != http.StatusOK {
		t.Fatalf("close: %d %v", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/hr-payroll/"+month+"/book", acc, nil); c != http.StatusConflict || got["error"] != "month_closed" {
		t.Errorf("book a closed month: %d %v, want 409 month_closed", c, got)
	}
	for _, c := range []string{"tyel_employer", "unemployment_employer"} {
		if code, got := call(t, r.e, r.op, http.MethodDelete, "/v1/operator/hr-rates/"+year+"/"+c, acc, nil); code != http.StatusNoContent {
			t.Errorf("delete %s: %d %v", c, code, got)
		}
	}
}
