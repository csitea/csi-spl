package store

import (
	"context"
	"crypto/ed25519"
	"errors"
	"math/rand/v2"
	"testing"
	"time"
)

// 009 T002/T004/T005 in the paid transition (rdb 0016), on every driver: a
// checkout's line items become the caps, the UTC month's seat period and, for
// a dedicated SKU, the project_id stamp at the paid minute, in the SAME
// transaction as the tenant. CONTROLS: a project_id another tenant holds in
// that minute retries the next minute; a replayed event changes nothing; an
// M2 checkout (no line items) writes no seats, no period and no stamp.
func TestCheckoutPaidAppliesSeatLineItems(t *testing.T) {
	ctx := context.Background()
	// a random minute far from any other test's stamps (unique on a shared DB)
	paid := time.Date(2031, 1, 1, 0, 0, 0, 0, time.UTC).Add(time.Duration(rand.IntN(500000)) * time.Minute).Add(17 * time.Second)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			pub, _, _ := ed25519.GenerateKey(nil)
			held, err := MintProjectID("abc", "xyz", "dev", paid)
			if err != nil {
				t.Fatal(err)
			}
			other := uid("t")
			if err := st.CreateTenant(ctx, Tenant{ID: other, RootPubKey: pub, Org: "abc", App: "xyz", ProjectID: held, BoughtAt: paid}); err != nil {
				t.Fatal(err)
			}

			tenant := uid("t")
			c := testCheckout(t, tenant)
			c.SeatsUsers, c.SeatsBots, c.Org, c.App, c.AmountCents = 2, 1, "abc", "xyz", 3100
			if err := st.HoldCheckout(ctx, c, paid.Add(-time.Minute), time.Hour); err != nil {
				t.Fatalf("hold: %v", err)
			}
			if got, err := st.GetCheckout(ctx, c.ID); err != nil || got.SeatsUsers != 2 || got.SeatsBots != 1 || got.Org != "abc" || got.App != "xyz" {
				t.Fatalf("line items not stored: %+v %v", got, err)
			}
			ev := PaymentEvent{Provider: "fake", EventID: "ev-" + c.ID, CheckoutID: c.ID, Kind: PayEventPaid, Env: "dev"}
			if out, err := st.ApplyPayment(ctx, ev, paid); err != nil || out != PayOutcomePaid {
				t.Fatalf("paid: %q %v", out, err)
			}
			next, _ := MintProjectID("abc", "xyz", "dev", paid.Add(time.Minute))
			ten, err := st.GetTenant(ctx, tenant)
			if err != nil || ten.SeatsUsers != 2 || ten.SeatsBots != 1 || ten.ProjectID != next || !ten.BoughtAt.Equal(paid) {
				t.Fatalf("paid tenant %+v %v (want caps 2/1 and project %s)", ten, err, next)
			}
			ps, err := st.SeatPeriods(ctx, tenant)
			if err != nil || len(ps) != 1 || !ps[0].PeriodStart.Equal(PeriodStart(paid)) || ps[0].SeatsUsers != 2 ||
				ps[0].SeatsBots != 1 || ps[0].CheckoutID != c.ID || ps[0].AmountCents != 3100 {
				t.Fatalf("seat period %+v %v", ps, err)
			}
			if out, _ := st.ApplyPayment(ctx, ev, paid.Add(time.Hour)); out != PayOutcomeDuplicate {
				t.Fatalf("replay: %q", out)
			}
			if ps, _ := st.SeatPeriods(ctx, tenant); len(ps) != 1 || !ps[0].PaidAt.Equal(paid) {
				t.Fatalf("replay changed the period: %+v", ps)
			}

			// the M2 SKU: no line items, nothing M4 written
			m2 := uid("t")
			c2 := testCheckout(t, m2)
			if err := st.HoldCheckout(ctx, c2, paid, time.Hour); err != nil {
				t.Fatal(err)
			}
			if out, err := st.ApplyPayment(ctx, PaymentEvent{Provider: "fake", EventID: "ev-" + c2.ID, CheckoutID: c2.ID,
				Kind: PayEventPaid, Env: "dev"}, paid); err != nil || out != PayOutcomePaid {
				t.Fatalf("m2 paid: %q %v", out, err)
			}
			if ten, _ := st.GetTenant(ctx, m2); ten.SeatsUsers != 0 || ten.SeatsBots != 0 || ten.ProjectID != "" || !ten.BoughtAt.IsZero() {
				t.Fatalf("an M2 tenant got M4 state: %+v", ten)
			}
			if ps, _ := st.SeatPeriods(ctx, m2); len(ps) != 0 {
				t.Fatalf("an M2 tenant got a seat period: %+v", ps)
			}
		})
	}
}

// A checkout's line items are validated like caps and buy stamps.
func TestCheckoutLineItemShape(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			for _, mut := range []func(*Checkout){
				func(c *Checkout) { c.SeatsUsers = -1 },
				func(c *Checkout) { c.Org = "abc" },
				func(c *Checkout) { c.Org, c.App = "ABCD", "xyz" },
			} {
				c := testCheckout(t, uid("t"))
				mut(&c)
				if err := st.HoldCheckout(context.Background(), c, time.Now(), time.Hour); err == nil || errors.Is(err, ErrConflict) {
					t.Fatalf("bad line items held: %+v %v", c, err)
				}
			}
		})
	}
}
