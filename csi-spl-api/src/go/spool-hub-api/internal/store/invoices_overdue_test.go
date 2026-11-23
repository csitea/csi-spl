package store

import (
	"context"
	"testing"
)

// Spec 181 row B13 (gap G14): the owner's overdue list on both drivers. Two
// invoices past due, one paid -> the list shows one; mark it paid -> none.
// An invoice due today is not overdue yet (the reminder goes out on day 15).

// overdueOf counts the overdue invoices of the named workspaces only (other
// tests' workspaces share the Postgres database).
func overdueOf(t *testing.T, s Store, tenants ...string) []Invoice {
	t.Helper()
	got, err := s.(OverdueInvoices).OverdueInvoices(context.Background(), invoiceNow)
	if err != nil {
		t.Fatal(err)
	}
	var out []Invoice
	for _, inv := range got {
		for _, w := range tenants {
			if inv.Tenant == w {
				out = append(out, inv)
			}
		}
	}
	return out
}

func TestOverdueInvoicesUnpaidPastDue(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			paid, open, today := newTenant(t, s), newTenant(t, s), newTenant(t, s)
			inv := issuedDaysAgo(t, s, paid, 20)
			issuedDaysAgo(t, s, open, 20)
			issuedDaysAgo(t, s, today, 14) // due today: not overdue
			if err := s.(Invoices).MarkInvoicePaid(ctx, paid, inv.Month, invoiceNow); err != nil {
				t.Fatal(err)
			}
			got := overdueOf(t, s, paid, open, today)
			if len(got) != 1 || got[0].Tenant != open || got[0].PaidAt != nil || got[0].TotalMicros == "" {
				t.Fatalf("overdue = %+v, want only %s's unpaid invoice", got, open)
			}
			if err := s.(Invoices).MarkInvoicePaid(ctx, open, got[0].Month, invoiceNow); err != nil {
				t.Fatal(err)
			}
			if got := overdueOf(t, s, paid, open, today); len(got) != 0 {
				t.Fatalf("after mark paid: overdue = %+v, want none", got)
			}
		})
	}
}
