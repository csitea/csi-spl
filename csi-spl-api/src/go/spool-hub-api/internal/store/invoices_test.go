package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Spec 181 row B12 (rdb 0315): the monthly invoice and its one reminder on
// both drivers. Done test: an invoice issued 14 days ago, unpaid -> no
// reminder; issued 15 days ago, unpaid -> one reminder, and a second claim
// -> still one. RED CONTROL: a claim that does not mark reminded_at claims
// the same invoice on every tick (TestInvoiceReminderOnce fails).

// invoiceNow is a fixed tick time, mid-day UTC.
var invoiceNow = time.Date(2026, 12, 20, 9, 30, 0, 0, time.UTC)

// issuedDaysAgo issues tenant's October invoice issued days before invoiceNow.
func issuedDaysAgo(t *testing.T, s Store, tenant string, days int) Invoice {
	t.Helper()
	ctx := context.Background()
	if err := s.(PricePlans).PutPricePlan(ctx, tenant, PrivateVMPlan()); err != nil {
		t.Fatal(err)
	}
	inv, created, err := s.(Invoices).IssueInvoice(ctx, tenant, time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC),
		3, 10_000_000, invoiceNow.AddDate(0, 0, -days))
	if err != nil || !created {
		t.Fatalf("issue: created %v, %v", created, err)
	}
	return inv
}

// seedInvoice writes one invoice of tenant (crosstenant_test.go seeds rdb
// 0315 with it); the plan is already seeded by seedPricePlan.
func seedInvoice(ctx context.Context, pg *Postgres, tenant string) error {
	_, _, err := pg.IssueInvoice(ctx, tenant, time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), 1, 0, invoiceNow)
	return err
}

// claimed runs one claim (it serves every workspace) and counts the claimed
// invoices per workspace (other tests' workspaces share the Postgres one).
func claimed(t *testing.T, s Store, now time.Time) map[string]int {
	t.Helper()
	got, err := s.(Invoices).ClaimInvoiceReminders(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	n := map[string]int{}
	for _, inv := range got {
		n[inv.Tenant]++
	}
	return n
}

func TestInvoiceIssueQuoteAndDueDate(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			tenant := newTenant(t, s)
			inv := issuedDaysAgo(t, s, tenant, 15)
			// 3 members x 900 cents + 10 EUR VM cost x 1.33 = 27 + 13.30 EUR.
			if inv.Currency != "EUR" || inv.SeatCents != 2700 || inv.VMPriceMicros != "13300000.000000" ||
				inv.TotalMicros != "40300000.000000" || inv.PaidAt != nil || inv.RemindedAt != nil {
				t.Errorf("invoice %+v: want EUR, 2700 seat cents, VM 13.30, total 40.30, unpaid, not reminded", inv)
			}
			if want := inv.IssuedOn.AddDate(0, 0, 14); !inv.DueOn.Equal(want) {
				t.Errorf("due %s, want issue date + 14 days %s (Q-19 A)", inv.DueOn, want)
			}
			again, created, err := s.(Invoices).IssueInvoice(ctx, tenant, inv.Month, 9, 1, invoiceNow)
			if err != nil || created || again.TotalMicros != inv.TotalMicros || !again.IssuedOn.Equal(inv.IssuedOn) {
				t.Errorf("a second issue of the month: created %v, %+v, %v; want the first row back", created, again, err)
			}
			read, err := s.(Invoices).Invoice(ctx, tenant, inv.Month)
			if err != nil || read.TotalMicros != inv.TotalMicros {
				t.Errorf("read back %+v, %v", read, err)
			}
			for _, bad := range []struct{ month, issued time.Time }{
				{time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC), invoiceNow},                                    // not a month's first day
				{time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 12, 20, 0, 0, 0, 0, time.UTC)}, // not in arrears
			} {
				if _, _, err := s.(Invoices).IssueInvoice(ctx, tenant, bad.month, 1, 0, bad.issued); !errors.Is(err, ErrInvoiceMonth) {
					t.Errorf("month %s issued %s: %v, want ErrInvoiceMonth", bad.month, bad.issued, err)
				}
			}
			if _, _, err := s.(Invoices).IssueInvoice(ctx, newTenant(t, s), inv.Month, 1, 0, invoiceNow); !errors.Is(err, ErrNoPricePlan) {
				t.Errorf("a workspace with no plan: %v, want ErrNoPricePlan", err)
			}
		})
	}
}

// TestInvoiceReminderOnce is the row's done test on the store: day 14 is
// still in term, day 15 claims the reminder once, a paid invoice never.
func TestInvoiceReminderOnce(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inTerm, late, paid := newTenant(t, s), newTenant(t, s), newTenant(t, s)
			issuedDaysAgo(t, s, inTerm, 14)
			issuedDaysAgo(t, s, late, 15)
			p := issuedDaysAgo(t, s, paid, 15)
			if err := s.(Invoices).MarkInvoicePaid(ctx, paid, p.Month, invoiceNow.Add(-time.Hour)); err != nil {
				t.Fatal(err)
			}
			first := claimed(t, s, invoiceNow)
			if first[inTerm] != 0 {
				t.Errorf("issued 14 days ago, unpaid: %d reminders, want 0 (due today, Q-19 A)", first[inTerm])
			}
			if first[paid] != 0 {
				t.Errorf("issued 15 days ago, paid: %d reminders, want 0", first[paid])
			}
			if first[late] != 1 {
				t.Fatalf("issued 15 days ago, unpaid: %d reminders, want 1", first[late])
			}
			next := claimed(t, s, invoiceNow.AddDate(0, 0, 1))
			if next[late] != 0 {
				t.Errorf("a second tick: %d more reminders, want 0 (one reminder only)", next[late])
			}
			if next[inTerm] != 1 {
				t.Errorf("the 14-day invoice on its day 15: %d reminders, want 1", next[inTerm])
			}
			inv, err := s.(Invoices).Invoice(ctx, late, time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC))
			if err != nil || inv.RemindedAt == nil || inv.PaidAt != nil {
				t.Errorf("the reminded invoice %+v, %v: want reminded_at set, still unpaid", inv, err)
			}
		})
	}
}

// TestInvoiceReminderRelease: a reminder that reached nobody is released and
// claimed again on the next tick; a release with another claim time is a
// no-op, so it never undoes a claim it did not make.
func TestInvoiceReminderRelease(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			tenant := newTenant(t, s)
			inv := issuedDaysAgo(t, s, tenant, 20)
			got, err := s.(Invoices).ClaimInvoiceReminders(ctx, invoiceNow)
			if err != nil {
				t.Fatal(err)
			}
			var at time.Time
			for _, g := range got {
				if g.Tenant == tenant {
					at = *g.RemindedAt
				}
			}
			if err := s.(Invoices).ReleaseInvoiceReminder(ctx, tenant, inv.Month, at.Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			if n := claimed(t, s, invoiceNow)[tenant]; n != 0 {
				t.Errorf("after a release with another claim time: %d claims, want 0", n)
			}
			if err := s.(Invoices).ReleaseInvoiceReminder(ctx, tenant, inv.Month, at); err != nil {
				t.Fatal(err)
			}
			if n := claimed(t, s, invoiceNow)[tenant]; n != 1 {
				t.Errorf("after the release: %d claims, want 1", n)
			}
			if err := s.(Invoices).MarkInvoicePaid(ctx, tenant, time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC), invoiceNow); !errors.Is(err, ErrNotFound) {
				t.Errorf("mark paid with no invoice: %v, want ErrNotFound", err)
			}
		})
	}
}

// TestInvoiceRdbChecks: rdb 0315 refuses a due date other than issue + 14
// and an invoice issued before its month ends, written past the store.
func TestInvoiceRdbChecks(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	for _, q := range []string{
		`INSERT INTO private_workspace_invoices (tenant_id, month, humans, seat_cents, vm_cost_micros, vm_price_micros, total_micros, issued_on, due_on)
			VALUES ($1, '2026-10-01', 1, 900, 0, 0, 9000000, '2026-11-01', '2026-11-30')`,
		`INSERT INTO private_workspace_invoices (tenant_id, month, humans, seat_cents, vm_cost_micros, vm_price_micros, total_micros, issued_on, due_on)
			VALUES ($1, '2026-10-01', 1, 900, 0, 0, 9000000, '2026-10-20', '2026-11-03')`,
		`INSERT INTO private_workspace_invoices (tenant_id, month, humans, seat_cents, vm_cost_micros, vm_price_micros, total_micros, issued_on, due_on)
			VALUES ($1, '2026-10-05', 1, 900, 0, 0, 9000000, '2026-11-05', '2026-11-19')`,
	} {
		if _, err := pg.execTenant(ctx, tenant, q, tenant); pgCode(err) != "23514" {
			t.Errorf("%s: %v, want a CHECK refusal (23514)", q, err)
		}
	}
}
