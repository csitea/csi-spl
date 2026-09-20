package payments

import (
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// disputeEvent is a charge.dispute.* envelope: the dispute object carries the
// payment_intent like a charge does (csi-rel handlers.go, "charge.dispute.closed").
func disputeEvent(id, typ, intent string) map[string]any {
	return map[string]any{"id": id, "type": typ,
		"data": map[string]any{"object": map[string]any{"id": "dp_1", "payment_intent": intent}}}
}

// buyOn runs a checkout to paid on the card rail and returns its intent id.
func buyOn(t *testing.T, r *rig, tenant string, now time.Time) string {
	t.Helper()
	code, co := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": tenant, "email": "buyer@example.com"})
	if code != 201 {
		t.Fatalf("checkout %s: %d %v", tenant, code, co)
	}
	intent := "pi_" + co["checkout_id"].(string)
	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_paid_"+tenant, "payment_intent.succeeded", intent)); code != 200 || out["action"] != store.PayOutcomePaid {
		t.Fatalf("paid %s: %d %v", tenant, code, out)
	}
	return intent
}

// TestStripeSharedAccountIsAcked — the Stripe account is SHARED with the other
// app on it (006 T022: one account, one secret key, an endpoint each), so this
// endpoint receives that app's events too. They verify against OUR signing
// secret, they name an intent that is not ours, and no retry will ever change
// that: a 4xx makes Stripe retry them for days and then disable the endpoint,
// which would silently drop OUR paid events. So a verified delivery this hub
// cannot match is ACKed 200, logged at info, and touches nothing.
func TestStripeSharedAccountIsAcked(t *testing.T) {
	api := &stripeAPI{}
	r := newRig(t, stripeCfg(t, api.server(t).URL))
	now := time.Now()
	intent := buyOn(t, r, "acme", now)

	// the other app's paid event: acked, no tenant, no mail
	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_foreign_paid", "payment_intent.succeeded", "pi_theirs")); code != 200 ||
		out["action"] != store.PayOutcomeNoMatch {
		t.Fatalf("foreign paid event must be acked: %d %v", code, out)
	}
	if len(r.mail.Messages()) != 1 {
		t.Fatalf("a foreign event sent mail: %+v", r.mail.Messages())
	}

	// the other app's chargeback: their money, not ours -> never CRITICAL
	r.logs.Reset()
	if code, out := r.stripeEvent(t, whsec, now, disputeEvent("evt_foreign_dispute", "charge.dispute.created", "pi_theirs")); code != 200 ||
		out["action"] != store.PayOutcomeIgnored {
		t.Fatalf("foreign dispute must be acked: %d %v", code, out)
	}
	if strings.Contains(r.logs.String(), "CRITICAL") {
		t.Fatalf("a chargeback on a payment this hub does not own logged CRITICAL: %s", r.logs.String())
	}

	// CONTROL: a chargeback on OUR payment is still CRITICAL
	r.logs.Reset()
	if code, _ := r.stripeEvent(t, whsec, now, disputeEvent("evt_our_dispute", "charge.dispute.created", intent)); code != 200 {
		t.Fatalf("our dispute: %d", code)
	}
	if !strings.Contains(r.logs.String(), "CRITICAL") {
		t.Fatalf("a chargeback on OUR payment must stay CRITICAL: %s", r.logs.String())
	}

	// CONTROL: a forged signature on a foreign event is still refused, and
	// leaves no dedup row (the same id verifies afterwards).
	if code, _ := r.stripeEvent(t, "whsec_wrong", now, intentEvent("evt_forged", "payment_intent.succeeded", "pi_theirs")); code != 400 {
		t.Fatalf("forged foreign event must be refused: %d", code)
	}
	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_forged", "payment_intent.succeeded", "pi_theirs")); code != 200 || out["status"] == "duplicate" {
		t.Fatalf("the forged attempt left a dedup row: %d %v", code, out)
	}

	// CONTROL: malformed input keeps its 400 (nothing to retry, but nothing
	// to trust either).
	if code, _ := r.stripeEvent(t, whsec, now, map[string]any{"type": "payment_intent.succeeded"}); code != 400 {
		t.Fatal("an event without an id must stay 400")
	}

	// CONTROL: a replay of OUR OWN paid event is a 200 no-op
	_ = r.st.SetBillingStatus(t.Context(), "acme", billing.StatusGrace)
	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_paid_acme", "payment_intent.succeeded", intent)); code != 200 || out["status"] != "duplicate" {
		t.Fatalf("replay %d %v", code, out)
	}
	if ten, _ := r.st.GetTenant(t.Context(), "acme"); ten.BillingStatus != billing.StatusGrace {
		t.Fatalf("the replay changed the tenant to %q", ten.BillingStatus)
	}
}

// TestStripeWebhookAckedWithoutCardRail — the rail flag must not turn a
// verified delivery into a retry storm. A hub whose card rail is off (the
// provider held at "" between the endpoint being provisioned and the owner's
// go) still holds the endpoint's signing secret, so the delivery is genuine:
// answer 200 and do nothing, instead of the 400 that had Stripe retrying every
// event on the shared account for days.
func TestStripeWebhookAckedWithoutCardRail(t *testing.T) {
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true",
		"SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000", "SPOOL_HUB_STRIPE_WEBHOOK_SECRET": whsec})
	if cfg.Rail() == RailCard {
		t.Fatal("this rig needs a hub with no card rail")
	}
	r := newRig(t, cfg)
	now := time.Now()

	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_no_rail", "payment_intent.succeeded", "pi_theirs")); code != 200 ||
		out["action"] != store.PayOutcomeNoMatch {
		t.Fatalf("verified delivery with no card rail must be acked: %d %v", code, out)
	}
	// CONTROL: the signature is still the only door
	if code, _ := r.stripeEvent(t, "whsec_wrong", now, intentEvent("evt_no_rail_forged", "payment_intent.succeeded", "pi_theirs")); code != 400 {
		t.Fatal("a forged event must be refused whatever the rail")
	}
}
