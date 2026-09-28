package store

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// Pins of ApplyPayment taken before it was split into named transaction
// steps (SPL-1029 round 2), on every driver: a paid event for a tenant row
// that already exists with the checkout's own root key re-activates it; an
// unknown event kind is an error that records nothing.
func TestApplyPaymentReactivatesAndRefusesUnknown(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tenant := uid("t")
			c := testCheckout(t, tenant)
			if err := st.HoldCheckout(ctx, c, now, time.Hour); err != nil {
				t.Fatalf("hold: %v", err)
			}
			if err := st.CreateTenant(ctx, Tenant{ID: tenant, RootPubKey: c.RootPubKey}); err != nil {
				t.Fatal(err)
			}
			if err := st.SetBillingStatus(ctx, tenant, billing.StatusUnpaid); err != nil {
				t.Fatal(err)
			}
			ev := PaymentEvent{Provider: "fake", EventID: "ev-" + c.ID, CheckoutID: c.ID, Kind: PayEventPaid}
			if out, err := st.ApplyPayment(ctx, ev, now); err != nil || out != PayOutcomePaid {
				t.Fatalf("paid on an existing row with the same root: %q %v", out, err)
			}
			if ten, err := st.GetTenant(ctx, tenant); err != nil || ten.BillingStatus != billing.StatusActive {
				t.Fatalf("tenant after paid: %+v %v", ten, err)
			}
			if got, err := st.GetCheckout(ctx, c.ID); err != nil || got.Status != CheckoutPaid {
				t.Fatalf("checkout after paid: %+v %v", got, err)
			}
			bad := PaymentEvent{Provider: "fake", EventID: "ev-odd-" + c.ID, CheckoutID: c.ID, Kind: "chargeback"}
			if out, err := st.ApplyPayment(ctx, bad, now); err == nil || out != "" {
				t.Fatalf("unknown kind: %q %v", out, err)
			}
			// the refused event was not recorded as seen: a retry is not a duplicate
			if out, _ := st.ApplyPayment(ctx, bad, now); out == PayOutcomeDuplicate {
				t.Fatal("an event that failed was recorded as seen")
			}
		})
	}
}
