package hub_test

import (
	"context"
	"crypto/ed25519"
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
