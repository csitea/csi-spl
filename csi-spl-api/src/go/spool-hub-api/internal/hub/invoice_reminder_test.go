package hub_test

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 181 row B12: the day-15 reminder of an unpaid monthly invoice, through
// the hub's tick. Done test: an invoice issued 14 days ago, unpaid -> no
// reminder; issued 15 days ago, unpaid -> one reminder, and a second tick ->
// still one. RED CONTROL (Q-17 B, nothing stops): after the reminder the
// workspace's box still gets its key lease and no member is suspended; the
// reminder sent twice fails the test.

// invMail records every invoice reminder the hub sent.
type invMail struct {
	mu   sync.Mutex
	sent []string // "<to> <tenant> <month>"
	fail atomic.Bool
}

func (m *invMail) send(_ context.Context, to, _ string, inv store.Invoice) error {
	if m.fail.Load() {
		return errors.New("relay down")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sent = append(m.sent, to+" "+inv.Tenant+" "+inv.Month.Format("2006-01"))
	return nil
}

func (m *invMail) all() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]string(nil), m.sent...)
}

var october = time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)

func TestInvoiceReminderDay15Once(t *testing.T) {
	var now atomic.Value
	now.Store(time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC))
	clock := func() time.Time { return now.Load().(time.Time) }
	mail := &invMail{}
	e, _ := vkEnv(t, func(o *hub.Options) { o.Now = clock; o.InvoiceReminderMail = mail.send })
	ctx := context.Background()
	tid, _ := e.tenant()
	biz, bizMail := seatBy(t, e, tid, rbac.BizOwner, store.AdmittedOperator)
	seatBy(t, e, tid, rbac.Admin, biz) // an admin is not mailed: the reminder is the biz owner's
	a := keyBox(t, e, tid, "box-a", store.BoxModeDedicated)
	ha := hubclient.VendorKeyHub{C: a.c}
	if err := e.st.(store.VendorKeyLeases).ApproveVendorKeyBox(ctx, tid, "box-a", biz, time.Now()); err != nil {
		t.Fatal(err)
	}
	enrolDesk(t, e, tid, "box-a")
	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusNoContent {
		t.Fatalf("PUT = %d %v", code, body)
	}
	if err := e.st.(store.PricePlans).PutPricePlan(ctx, tid, store.PrivateVMPlan()); err != nil {
		t.Fatal(err)
	}
	// Issued 2026-11-03: due 2026-11-17, day 15 is 2026-11-18.
	if _, _, err := e.st.(store.Invoices).IssueInvoice(ctx, tid, october, 2, 5_000_000, time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	// Another workspace's invoice of the same day, paid: never reminded.
	paid, _ := e.tenant()
	seatBy(t, e, paid, rbac.BizOwner, store.AdmittedOperator)
	if err := e.st.(store.PricePlans).PutPricePlan(ctx, paid, store.PrivateVMPlan()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.st.(store.Invoices).IssueInvoice(ctx, paid, october, 1, 0, time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	if err := e.st.(store.Invoices).MarkInvoicePaid(ctx, paid, october, clock()); err != nil {
		t.Fatal(err)
	}

	if n := e.srv.InvoiceRemindersOnce(ctx); n != 0 || len(mail.all()) != 0 {
		t.Fatalf("issued 14 days ago, unpaid: %d reminded, mail %v; want none (due today, Q-19 A)", n, mail.all())
	}
	now.Store(clock().Add(24 * time.Hour))
	if n := e.srv.InvoiceRemindersOnce(ctx); n != 1 {
		t.Fatalf("issued 15 days ago, unpaid: %d reminded, want 1", n)
	}
	want := bizMail + " " + tid + " 2026-10"
	if got := mail.all(); len(got) != 1 || got[0] != want {
		t.Fatalf("mail = %v, want once to the biz owner: %q", got, want)
	}
	now.Store(clock().Add(time.Hour))
	e.srv.InvoiceRemindersOnce(ctx)
	if got := mail.all(); len(got) != 1 {
		t.Fatalf("after a second tick the mail = %v, want still one reminder (one only, Q-17 B)", got)
	}
	// Nothing stops (Q-17 B): the box's lease is served, no member is
	// suspended. The box signs its hello with the real time, so the hub's
	// clock goes back to it; the reminder is already recorded.
	now.Store(time.Now())
	if _, err := ha.Lease(ctx, "claude"); err != nil {
		t.Fatalf("lease after the reminder: %v (%s), want served: an unpaid invoice stops nothing", err, refusal(err))
	}
	members, err := e.st.(store.MemberDirectory).ListMembers(ctx, tid)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range members {
		if m.Suspended || m.Disabled {
			t.Errorf("member %s suspended or disabled after the reminder", m.HumanID)
		}
	}
}

// TestInvoiceReminderRelayDown: a reminder that reached nobody is not spent;
// the next tick with the relay back sends it, once. No relay at all claims
// nothing.
func TestInvoiceReminderRelayDown(t *testing.T) {
	now := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	mail := &invMail{}
	mail.fail.Store(true)
	e, _ := vkEnv(t, func(o *hub.Options) { o.Now = func() time.Time { return now }; o.InvoiceReminderMail = mail.send })
	ctx := context.Background()
	tid, _ := e.tenant()
	_, bizMail := seatBy(t, e, tid, rbac.BizOwner, store.AdmittedOperator)
	if err := e.st.(store.PricePlans).PutPricePlan(ctx, tid, store.PrivateVMPlan()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.st.(store.Invoices).IssueInvoice(ctx, tid, october, 1, 0, time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	if n := e.srv.InvoiceRemindersOnce(ctx); n != 0 {
		t.Fatalf("relay down: %d reminded, want 0", n)
	}
	mail.fail.Store(false)
	if n := e.srv.InvoiceRemindersOnce(ctx); n != 1 {
		t.Fatalf("relay back: %d reminded, want 1", n)
	}
	e.srv.InvoiceRemindersOnce(ctx)
	if got := mail.all(); len(got) != 1 || got[0] != bizMail+" "+tid+" 2026-10" {
		t.Fatalf("mail = %v, want one reminder to the biz owner", got)
	}

	off, _ := vkEnv(t, func(o *hub.Options) { o.Now = func() time.Time { return now } })
	tid2, _ := off.tenant()
	if err := off.st.(store.PricePlans).PutPricePlan(ctx, tid2, store.PrivateVMPlan()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := off.st.(store.Invoices).IssueInvoice(ctx, tid2, october, 1, 0, time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	off.srv.InvoiceRemindersOnce(ctx)
	if inv, err := off.st.(store.Invoices).Invoice(ctx, tid2, october); err != nil || inv.RemindedAt != nil {
		t.Fatalf("no relay: %+v %v, want the reminder not claimed", inv, err)
	}
}
