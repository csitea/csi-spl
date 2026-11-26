package store

import (
	"context"
	"testing"
	"time"
)

// TestPaidCreateFleetSeating (spec 158 row P3, M24, OD1; SPL-5021): a paid
// checkout that creates its workspace creates it with fleet_seating true,
// like every other create (owner OD1 = yes). RED on master before the fix:
// the paid transition inserted the tenant with no fleet_seating, so it read
// the rdb 0230 default false. CONTROL: the switch turned off after the
// create reads false, so the read is not a constant true.
func TestPaidCreateFleetSeating(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fs := st.(FleetSeating)
			tenant := uid("t")
			c := testCheckout(t, tenant)
			if err := st.HoldCheckout(ctx, c, now, time.Hour); err != nil {
				t.Fatalf("hold: %v", err)
			}
			ev := PaymentEvent{Provider: "fake", EventID: "ev-" + c.ID, CheckoutID: c.ID, Kind: PayEventPaid}
			if out, err := st.ApplyPayment(ctx, ev, now); err != nil || out != PayOutcomePaid {
				t.Fatalf("paid: %q %v", out, err)
			}
			if on, err := fs.FleetSeating(ctx, tenant); err != nil || !on {
				t.Fatalf("a paid create: %s fleet_seating reads %v %v, want true (OD1)", tenant, on, err)
			}
			if err := fs.SetFleetSeating(ctx, tenant, false); err != nil {
				t.Fatal(err)
			}
			if on, err := fs.FleetSeating(ctx, tenant); err != nil || on {
				t.Fatalf("CONTROL: switched off after the paid create: reads %v %v, want false", on, err)
			}
		})
	}
}
