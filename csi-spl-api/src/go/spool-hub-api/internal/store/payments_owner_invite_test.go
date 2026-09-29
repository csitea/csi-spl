package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// 047 W1 (D1): the paid transition seats the buyer. The checkout email signs
// in as biz_owner with no operator invite and no bootstrap policy; any other
// address is refused, and so is the buyer once the invite expired.
func TestPaidCheckoutSeatsBuyerAsOwner(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		h := st.(Humans)
		t.Run(name, func(t *testing.T) {
			tenant := uid("t")
			c := testCheckout(t, tenant)
			c.Email = "Buyer-" + tenant + "@Example.com"
			if err := st.HoldCheckout(ctx, c, now, time.Hour); err != nil {
				t.Fatalf("hold: %v", err)
			}
			ev := PaymentEvent{Provider: "fake", EventID: "ev-" + c.ID, CheckoutID: c.ID, Kind: PayEventPaid}
			if out, err := st.ApplyPayment(ctx, ev, now); err != nil || out != PayOutcomePaid {
				t.Fatalf("paid: %q %v", out, err)
			}
			other := Identity{Provider: "google", Subject: uid("s-"), Email: "someone-else@example.com"}
			if _, err := h.Admit(ctx, other, tenant, AdmitPolicy{}, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("a different email: want ErrNotAdmitted, got %v", err)
			}
			late := Identity{Provider: "google", Subject: uid("s-"), Email: c.Email}
			if _, err := h.Admit(ctx, late, tenant, AdmitPolicy{}, now.Add(PaidOwnerInviteTTL)); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("after the invite TTL: want ErrNotAdmitted, got %v", err)
			}
			buyer := Identity{Provider: "google", Subject: uid("s-"), Email: c.Email}
			hum, err := h.Admit(ctx, buyer, tenant, AdmitPolicy{}, now.Add(time.Minute))
			if err != nil {
				t.Fatalf("buyer admit: %v", err)
			}
			if r, err := h.MemberRole(ctx, hum, tenant); err != nil || r != RoleTenantOwner {
				t.Fatalf("buyer role = %q %v, want %q", r, err, RoleTenantOwner)
			}
			// a second provider on the same verified address is the same human
			// (identity linking), not a second owner
			again := Identity{Provider: "password", Subject: uid("s-"), Email: c.Email}
			if h2, err := h.Admit(ctx, again, tenant, AdmitPolicy{}, now.Add(2*time.Minute)); err != nil || h2 != hum {
				t.Fatalf("second provider on the buyer email: %q %v, want %q", h2, err, hum)
			}
		})
	}
}
