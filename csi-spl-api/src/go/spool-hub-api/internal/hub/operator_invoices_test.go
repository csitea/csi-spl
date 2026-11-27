package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 181 row B13 (gap G14): the owner's overdue list and the mark paid.
// Done test: two invoices past due, one paid -> the list shows one; mark it
// paid -> the list is empty. RED CONTROLS: a workspace's own member reads
// the list -> 403; a mark paid that writes no audit row fails the test.

const overduePath = "/v1/operator/invoices/overdue"

// invoiceRig is an operator workspace with its admin, and two private
// workspaces, each with an October invoice issued 2026-11-03 (due 11-17).
type invoiceRig struct {
	e                *env
	op, admin        string
	paid, open, memb string
}

var invoiceRigNow = time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)

func newInvoiceRig(t *testing.T) *invoiceRig {
	t.Helper()
	ctx := context.Background()
	g := &invoiceRig{op: newTenantID("op"), paid: newTenantID("ip"), open: newTenantID("io")}
	g.e = rbacEnv(t, func(o *hub.Options) { o.OperatorTenant, o.Now = g.op, func() time.Time { return invoiceRigNow } })
	for _, id := range []string{g.op, g.paid, g.open} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := g.e.st.CreateTenant(ctx, store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []string{g.paid, g.open} {
		if err := g.e.st.(store.PricePlans).PutPricePlan(ctx, id, store.PrivateVMPlan()); err != nil {
			t.Fatal(err)
		}
		if _, _, err := g.e.st.(store.Invoices).IssueInvoice(ctx, id, october, 2, 5_000_000, time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)); err != nil {
			t.Fatal(err)
		}
	}
	if err := g.e.st.(store.Invoices).MarkInvoicePaid(ctx, g.paid, october, invoiceRigNow); err != nil {
		t.Fatal(err)
	}
	g.admin = seat(t, g.e, g.op, rbac.Admin)
	g.memb = seat(t, g.e, g.open, rbac.BizOwner)
	return g
}

// overdue reads the list as the operator admin, kept to the rig's workspaces
// (other tests' workspaces share a Postgres database).
func (g *invoiceRig) overdue(t *testing.T) []map[string]any {
	t.Helper()
	code, body := call(t, g.e, g.op, http.MethodGet, overduePath, g.admin, nil)
	list, ok := body["invoices"].([]any)
	if code != http.StatusOK || !ok {
		t.Fatalf("overdue = %d %v", code, body)
	}
	var out []map[string]any
	for _, x := range list {
		inv := x.(map[string]any)
		if inv["workspace"] == g.paid || inv["workspace"] == g.open {
			out = append(out, inv)
		}
	}
	return out
}

// paidAudits counts the invoice_paid audit rows of workspace id for month.
func (g *invoiceRig) paidAudits(t *testing.T, id, month string) int {
	t.Helper()
	rows, err := g.e.st.(store.OperatorWorkspaces).OperatorAuditOf(context.Background(), id, 50)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, a := range rows {
		if a.Action == store.AuditUpdate && a.Detail["invoice_paid"] == month && a.ActorHum == g.admin && a.ActorTenant == g.op {
			n++
		}
	}
	return n
}

func TestOverdueInvoicesListAndMarkPaid(t *testing.T) {
	g := newInvoiceRig(t)
	list := g.overdue(t)
	if len(list) != 1 || list[0]["workspace"] != g.open || list[0]["month"] != "2026-10" ||
		list[0]["due_on"] != "2026-11-17" || list[0]["days_overdue"] != float64(3) || list[0]["currency"] != "EUR" {
		t.Fatalf("overdue = %v, want only %s's October invoice, 3 days over", list, g.open)
	}
	path := "/v1/operator/invoices/" + g.open + "/2026-10/paid"
	if code, body := call(t, g.e, g.op, http.MethodPost, path, g.admin, nil); code != http.StatusOK || body["paid_at"] != "2026-11-20T10:00:00Z" {
		t.Fatalf("mark paid = %d %v", code, body)
	}
	if n := g.paidAudits(t, g.open, "2026-10"); n != 1 {
		t.Fatalf("mark paid wrote %d invoice_paid audit rows in %s, want 1", n, g.open)
	}
	if list := g.overdue(t); len(list) != 0 {
		t.Fatalf("after mark paid: overdue = %v, want empty", list)
	}
	inv, err := g.e.st.(store.Invoices).Invoice(context.Background(), g.open, october)
	if err != nil || inv.PaidAt == nil || !inv.PaidAt.Equal(invoiceRigNow) {
		t.Fatalf("invoice after mark paid = %+v, %v", inv, err)
	}
	if code, _ := call(t, g.e, g.op, http.MethodPost, path, g.admin, nil); code != http.StatusConflict {
		t.Fatalf("second mark paid = %d, want 409", code)
	}
	if n := g.paidAudits(t, g.open, "2026-10"); n != 1 {
		t.Fatalf("a refused second mark paid left %d audit rows, want still 1", n)
	}
}

func TestOverdueInvoicesOperatorAdminOnly(t *testing.T) {
	g := newInvoiceRig(t)
	opMember := seat(t, g.e, g.op, rbac.Developer)
	cases := []struct{ who, tid, as string }{
		{"the workspace's own biz owner", g.open, g.memb},
		{"a developer of the operator workspace", g.op, opMember},
	}
	for _, c := range cases {
		if code, body := call(t, g.e, c.tid, http.MethodGet, overduePath, c.as, nil); code != http.StatusForbidden {
			t.Fatalf("%s reads the list: %d %v, want 403", c.who, code, body)
		}
		if code, _ := call(t, g.e, c.tid, http.MethodPost, "/v1/operator/invoices/"+g.open+"/2026-10/paid", c.as, nil); code != http.StatusForbidden {
			t.Fatalf("%s marks paid: %d, want 403", c.who, code)
		}
	}
	if list := g.overdue(t); len(list) != 1 {
		t.Fatalf("after the refused calls: overdue = %v, want still one", list)
	}
}

func TestInvoicePaidBadInput(t *testing.T) {
	g := newInvoiceRig(t)
	for path, want := range map[string]int{
		"/v1/operator/invoices/" + g.open + "/2026-13/paid":            http.StatusBadRequest,
		"/v1/operator/invoices/" + g.open + "/oct/paid":                http.StatusBadRequest,
		"/v1/operator/invoices/" + g.open + "/2026-09/paid":            http.StatusNotFound,
		"/v1/operator/invoices/" + newTenantID("no") + "/2026-10/paid": http.StatusNotFound,
		"/v1/operator/invoices/" + g.paid + "/2026-10/paid":            http.StatusConflict,
	} {
		if code, body := call(t, g.e, g.op, http.MethodPost, path, g.admin, nil); code != want {
			t.Fatalf("POST %s = %d %v, want %d", path, code, body, want)
		}
	}
}

// Spec 181 row B14 (gap G15): the month-end invoice issuer's operator
// routes. Done test: two private workspaces and one that is not; the list
// holds the two with their human counts; an issue for each private one
// writes its invoice with the posted VM cost and the hub's count, none for
// the other; a replay returns the same invoice and writes no new row or
// audit. RED CONTROLS: a verified identity that is not an operator -> 403,
// a member session -> 401, both writing nothing; an open month -> 409, no
// invoice.

const (
	privateWSPath = "/v1/operator/invoices/private-workspaces"
	issuePath     = "/v1/operator/invoices/issue"
)

// issueRig: a and b on the private_vm plan (2 and 1 human members), plain
// not; the operator token "good" is the env SA, "stranger" is not.
type issueRig struct {
	e           *env
	a, b, plain string
	member      string
}

func newIssueRig(t *testing.T) *issueRig {
	t.Helper()
	ctx := context.Background()
	g := &issueRig{a: newTenantID("ia"), b: newTenantID("ib"), plain: newTenantID("in")}
	g.e = rbacEnv(t, func(o *hub.Options) {
		o.Now = func() time.Time { return invoiceRigNow }
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			switch token {
			case "good":
				return operatorSA, nil
			case "stranger":
				return "someone@example.com", nil
			}
			return "", errors.New("token rejected")
		}
	})
	for _, id := range []string{g.a, g.b, g.plain} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := g.e.st.CreateTenant(ctx, store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []string{g.a, g.b} {
		if err := g.e.st.(store.PricePlans).PutPricePlan(ctx, id, store.PrivateVMPlan()); err != nil {
			t.Fatal(err)
		}
	}
	g.member = seat(t, g.e, g.a, rbac.BizOwner)
	seat(t, g.e, g.a, rbac.Developer)
	seat(t, g.e, g.b, rbac.BizOwner)
	seat(t, g.e, g.plain, rbac.BizOwner)
	return g
}

// listed reads the private workspaces as the env SA, kept to the rig's.
func (g *issueRig) listed(t *testing.T, query string) map[string]float64 {
	t.Helper()
	code, body := opCall(t, g.e, g.a, http.MethodGet, privateWSPath+query, "good", nil)
	list, ok := body["workspaces"].([]any)
	if code != http.StatusOK || !ok {
		t.Fatalf("private workspaces = %d %v", code, body)
	}
	out := map[string]float64{}
	for _, x := range list {
		ws := x.(map[string]any)
		if id := ws["workspace"].(string); id == g.a || id == g.b || id == g.plain {
			out[id] = ws["humans"].(float64)
		}
	}
	return out
}

func (g *issueRig) issue(t *testing.T, token, id, month string, cost any) (int, map[string]any) {
	t.Helper()
	return opCall(t, g.e, g.a, http.MethodPost, issuePath, token, map[string]any{"workspace": id, "month": month, "vm_cost_micros": cost})
}

// issuedAudits counts the invoice_issued audit rows of workspace id.
func (g *issueRig) issuedAudits(t *testing.T, id string) int {
	t.Helper()
	rows, err := g.e.st.(store.OperatorWorkspaces).OperatorAuditOf(context.Background(), id, 50)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, a := range rows {
		if a.Action == store.AuditCreate && a.Detail["invoice_issued"] != nil && a.ActorHum == operatorSA {
			n++
		}
	}
	return n
}

// noInvoice fails when id has an invoice for month.
func (g *issueRig) noInvoice(t *testing.T, id string, month time.Time) {
	t.Helper()
	if inv, err := g.e.st.(store.Invoices).Invoice(context.Background(), id, month); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("%s has an invoice for %s: %+v %v", id, month.Format("2006-01"), inv, err)
	}
}

func TestInvoiceIssueTwoPrivateOnePlain(t *testing.T) {
	g := newIssueRig(t)
	if got := g.listed(t, ""); len(got) != 2 || got[g.a] != 2 || got[g.b] != 1 {
		t.Fatalf("private workspaces = %v, want %s:2 %s:1, not %s", got, g.a, g.b, g.plain)
	}
	if got := g.listed(t, "?workspace="+g.b); len(got) != 1 || got[g.b] != 1 {
		t.Fatalf("one named = %v, want only %s:1", got, g.b)
	}
	if got := g.listed(t, "?workspace="+g.plain); len(got) != 0 {
		t.Fatalf("the plain workspace named = %v, want none", got)
	}
	want := map[string][2]float64{g.a: {2, 1_234_567}, g.b: {1, 9_000_000}}
	first := map[string]map[string]any{}
	for id, w := range want {
		code, body := g.issue(t, "good", id, "2026-10", int64(w[1]))
		inv, _ := body["invoice"].(map[string]any)
		if code != http.StatusCreated || body["created"] != true || inv["humans"] != w[0] || inv["vm_cost_micros"] != w[1] ||
			inv["issued_on"] != "2026-11-20" || inv["due_on"] != "2026-12-04" || inv["month"] != "2026-10" {
			t.Fatalf("issue %s = %d %v, want 201 with humans %v cost %v", id, code, body, w[0], w[1])
		}
		first[id] = inv
	}
	if code, body := g.issue(t, "good", g.plain, "2026-10", 5); code != http.StatusConflict || body["error"] != "not_private_workspace" {
		t.Fatalf("issue for the plain workspace = %d %v, want 409", code, body)
	}
	g.noInvoice(t, g.plain, october)
	for id, w := range want {
		code, body := g.issue(t, "good", id, "2026-10", int64(w[1])+1)
		inv, _ := body["invoice"].(map[string]any)
		if code != http.StatusOK || body["created"] != false || inv["total_micros"] != first[id]["total_micros"] || inv["vm_cost_micros"] != w[1] {
			t.Fatalf("replay %s = %d %v, want 200 with the first invoice %v", id, code, body, first[id])
		}
		if n := g.issuedAudits(t, id); n != 1 {
			t.Fatalf("%s: %d invoice_issued audit rows after a replay, want 1", id, n)
		}
	}
}

func TestInvoiceIssueRefusals(t *testing.T) {
	g := newIssueRig(t)
	for _, c := range []struct {
		who, token string
		want       int
	}{
		{"a verified identity that is not an operator", "stranger", http.StatusForbidden},
		{"no token", "", http.StatusUnauthorized},
		{"a rejected token", "forged", http.StatusUnauthorized},
	} {
		if code, _ := opCall(t, g.e, g.a, http.MethodGet, privateWSPath, c.token, nil); code != c.want {
			t.Fatalf("%s lists: %d, want %d", c.who, code, c.want)
		}
		if code, _ := g.issue(t, c.token, g.a, "2026-10", 1); code != c.want {
			t.Fatalf("%s issues: %d, want %d", c.who, code, c.want)
		}
	}
	if code, _ := call(t, g.e, g.a, http.MethodPost, issuePath, g.member, map[string]any{"workspace": g.a, "month": "2026-10", "vm_cost_micros": 1}); code != http.StatusUnauthorized {
		t.Fatalf("the workspace's own biz owner issues: %d, want 401", code)
	}
	g.noInvoice(t, g.a, october)
	november := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	if code, body := g.issue(t, "good", g.a, "2026-11", 1); code != http.StatusConflict || body["error"] != "month_not_closed" {
		t.Fatalf("issue for the open month = %d %v, want 409 month_not_closed", code, body)
	}
	g.noInvoice(t, g.a, november)
	for name, b := range map[string]map[string]any{
		"bad month":     {"workspace": g.a, "month": "2026-13", "vm_cost_micros": 1},
		"negative cost": {"workspace": g.a, "month": "2026-10", "vm_cost_micros": -1},
		"no cost":       {"workspace": g.a, "month": "2026-10"},
		"bad workspace": {"workspace": "Bad Id", "month": "2026-10", "vm_cost_micros": 1},
		"unknown field": {"workspace": g.a, "month": "2026-10", "vm_cost_micros": 1, "humans": 9},
	} {
		if code, body := opCall(t, g.e, g.a, http.MethodPost, issuePath, "good", b); code != http.StatusBadRequest {
			t.Fatalf("%s: %d %v, want 400", name, code, body)
		}
	}
	g.noInvoice(t, g.a, october)
	if n := g.issuedAudits(t, g.a); n != 0 {
		t.Fatalf("the refused calls wrote %d audit rows, want 0", n)
	}
}
