package store

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

func testCheckout(t *testing.T, tenant string) Checkout {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256([]byte("claim-" + tenant))
	id := uid("co_")
	return Checkout{ID: id, ProviderRef: "pi_" + id, TenantID: tenant, Provider: "fake", AmountCents: 2000, Currency: "eur",
		Email: "buyer@example.com", RootPubKey: pub, SealedRootKey: []byte("sealed"), ClaimHash: h[:]}
}

// 006 T018a/T019: a hold is not a tenant; paid creates it active; the
// event id dedups; the claim is once.
func TestCheckoutHoldPayClaim(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tenant := uid("t")
			c := testCheckout(t, tenant)
			if err := st.HoldCheckout(ctx, c, now, time.Hour); err != nil {
				t.Fatalf("hold: %v", err)
			}
			if _, err := st.GetTenant(ctx, tenant); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a hold must not create the tenant: %v", err)
			}
			// a second buyer on the same slug within the hold
			c2 := testCheckout(t, tenant)
			if err := st.HoldCheckout(ctx, c2, now.Add(time.Minute), time.Hour); !errors.Is(err, ErrConflict) {
				t.Fatalf("live hold: want ErrConflict, got %v", err)
			}
			if got, err := st.CheckoutByProviderRef(ctx, "fake", "pi_"+c.ID); err != nil || got.ID != c.ID {
				t.Fatalf("by provider ref: %+v %v", got, err)
			}
			if _, err := st.CheckoutByProviderRef(ctx, "other", "pi_"+c.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("by ref under another provider: %v", err)
			}
			if _, err := st.ClaimCheckout(ctx, c.ID, c.ClaimHash, now); !errors.Is(err, ErrNotPaid) {
				t.Fatalf("claim before paid: want ErrNotPaid, got %v", err)
			}
			ev := PaymentEvent{Provider: "fake", EventID: "ev-" + c.ID, CheckoutID: c.ID, Kind: PayEventPaid}
			if out, err := st.ApplyPayment(ctx, ev, now); err != nil || out != PayOutcomePaid {
				t.Fatalf("paid: %q %v", out, err)
			}
			ten, err := st.GetTenant(ctx, tenant)
			if err != nil || ten.BillingStatus != billing.StatusActive || !ten.RootPubKey.Equal(c.RootPubKey) {
				t.Fatalf("tenant after paid: %+v %v", ten, err)
			}
			// replay: the same event id is a no-op
			if out, err := st.ApplyPayment(ctx, ev, now); err != nil || out != PayOutcomeDuplicate {
				t.Fatalf("replay: %q %v", out, err)
			}
			// a different event id for an already-paid checkout
			ev2 := ev
			ev2.EventID += "-b"
			if out, _ := st.ApplyPayment(ctx, ev2, now); out != PayOutcomeAlreadyPaid {
				t.Fatalf("second paid: %q", out)
			}
			// the tenant now exists: a new hold is refused
			if err := st.HoldCheckout(ctx, testCheckout(t, tenant), now.Add(2*time.Hour), time.Hour); !errors.Is(err, ErrConflict) {
				t.Fatalf("hold on an existing tenant: %v", err)
			}
			wrong := sha256.Sum256([]byte("nope"))
			if _, err := st.ClaimCheckout(ctx, c.ID, wrong[:], now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("wrong claim hash: want ErrNotFound, got %v", err)
			}
			got, err := st.ClaimCheckout(ctx, c.ID, c.ClaimHash, now)
			if err != nil || string(got.SealedRootKey) != "sealed" || got.Email != "buyer@example.com" {
				t.Fatalf("claim: %+v %v", got, err)
			}
			if _, err := st.ClaimCheckout(ctx, c.ID, c.ClaimHash, now); !errors.Is(err, ErrClaimed) {
				t.Fatalf("second claim: want ErrClaimed, got %v", err)
			}
			after, _ := st.GetCheckout(ctx, c.ID)
			if len(after.SealedRootKey) != 0 || after.ClaimedAt.IsZero() || after.Status != CheckoutPaid {
				t.Fatalf("seal must be wiped after claim: %+v", after)
			}
			// refund → billing.MapEvent("refund") = unpaid
			ev3 := PaymentEvent{Provider: "fake", EventID: "ev-refund-" + c.ID, CheckoutID: c.ID, Kind: PayEventRefund}
			if out, err := st.ApplyPayment(ctx, ev3, now); err != nil || out != PayOutcomeRefund {
				t.Fatalf("refund: %q %v", out, err)
			}
			if ten, _ := st.GetTenant(ctx, tenant); ten.BillingStatus != billing.StatusUnpaid {
				t.Fatalf("after refund: %q", ten.BillingStatus)
			}
		})
	}
}

func TestCheckoutExpiredHoldAndConflict(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tenant := uid("t")
			old := testCheckout(t, tenant)
			if err := st.HoldCheckout(ctx, old, now, time.Hour); err != nil {
				t.Fatal(err)
			}
			// after the hold, a new buyer takes the slug; the old hold is cancelled
			fresh := testCheckout(t, tenant)
			if err := st.HoldCheckout(ctx, fresh, now.Add(2*time.Hour), time.Hour); err != nil {
				t.Fatalf("expired hold must be superseded: %v", err)
			}
			if c, _ := st.GetCheckout(ctx, old.ID); c.Status != CheckoutCancelled {
				t.Fatalf("old hold status %q", c.Status)
			}
			// the fresh buyer pays first
			if out, _ := st.ApplyPayment(ctx, PaymentEvent{Provider: "fake", EventID: uid("e"), CheckoutID: fresh.ID, Kind: PayEventPaid}, now); out != PayOutcomePaid {
				t.Fatalf("fresh paid: %q", out)
			}
			// the late payment of the superseded hold must not take the tenant over
			if out, _ := st.ApplyPayment(ctx, PaymentEvent{Provider: "fake", EventID: uid("e"), CheckoutID: old.ID, Kind: PayEventPaid}, now); out != PayOutcomeConflict {
				t.Fatalf("late paid on a taken slug: %q", out)
			}
			if ten, _ := st.GetTenant(ctx, tenant); !ten.RootPubKey.Equal(fresh.RootPubKey) {
				t.Fatal("tenant root key changed by a late payment")
			}
			// failed only moves a pending checkout; no match is acknowledged
			f := testCheckout(t, uid("t"))
			if err := st.HoldCheckout(ctx, f, now, time.Hour); err != nil {
				t.Fatal(err)
			}
			if out, _ := st.ApplyPayment(ctx, PaymentEvent{Provider: "fake", EventID: uid("e"), CheckoutID: f.ID, Kind: PayEventFailed}, now); out != PayOutcomeFailed {
				t.Fatalf("failed: %q", out)
			}
			if c, _ := st.GetCheckout(ctx, f.ID); c.Status != CheckoutFailed {
				t.Fatalf("failed status %q", c.Status)
			}
			if _, err := st.GetTenant(ctx, f.TenantID); !errors.Is(err, ErrNotFound) {
				t.Fatal("a failed payment must not create a tenant")
			}
			if out, _ := st.ApplyPayment(ctx, PaymentEvent{Provider: "fake", EventID: uid("e"), CheckoutID: "co_none", Kind: PayEventPaid}, now); out != PayOutcomeNoMatch {
				t.Fatalf("no match: %q", out)
			}
			if out, _ := st.ApplyPayment(ctx, PaymentEvent{Provider: "fake", EventID: uid("e"), Kind: PayEventIgnore}, now); out != PayOutcomeIgnored {
				t.Fatalf("ignore: %q", out)
			}
		})
	}
}
