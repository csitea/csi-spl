package payments

import (
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

func seatCfg(t *testing.T, base string, extra map[string]string) *Config {
	vars := map[string]string{"SPOOL_HUB_PAYMENT_PROVIDER": "stripe", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000",
		"SPOOL_HUB_STRIPE_SECRET_KEY": "sk_test_abc", "SPOOL_HUB_STRIPE_WEBHOOK_SECRET": whsec,
		"SPOOL_HUB_STRIPE_PUBLISHABLE_KEY": "pk_test_abc", "SPOOL_HUB_STRIPE_API_BASE": base,
		"SPOOL_HUB_PAYMENT_SEAT_USER_CENTS": "500", "SPOOL_HUB_PAYMENT_SEAT_BOT_CENTS": "100", "SPOOL_HUB_PAYMENT_SEATS_MAX": "50"}
	for k, v := range extra {
		vars[k] = v
	}
	return mustLoad(t, "lde", vars)
}

func newRigAt(t *testing.T, cfg *Config, now time.Time) *rig {
	card, pp, ppv := Wire(cfg)
	return newRigWith(t, cfg, Deps{Card: card, PayPal: pp, PayPalVerifier: ppv, Now: func() time.Time { return now }})
}

// 009 T004 + T002 on the card rail: the seats travel as line items on the
// intent (metadata + description), the total is plan + seats, and ONLY the
// verified paid webhook writes the caps and the month's seat period. CONTROLS:
// a forged webhook writes nothing; a replay changes nothing; a new bot seat
// over the paid cap is refused (402 quota at the hub, ErrSeatQuota here).
func TestM4SeatLineItemsOnTheCardRail(t *testing.T) {
	api := &stripeAPI{}
	now := time.Date(2026, 9, 19, 17, 43, 12, 0, time.UTC)
	r := newRigAt(t, seatCfg(t, api.server(t).URL, nil), now)
	ctx := t.Context()

	if code, p := r.do(t, "GET", "/api/v1/checkout/plan", nil); code != 200 || p["seat_user_cents"] != float64(500) ||
		p["seat_bot_cents"] != float64(100) || p["seats_max"] != float64(50) {
		t.Fatalf("plan %d %v", code, p)
	}
	code, co := r.do(t, "POST", "/api/v1/checkout", map[string]any{"tenant_id": "acme", "email": "buyer@example.com",
		"seats_users": 2, "seats_bots": 3})
	if code != 201 || co["amount_cents"] != float64(2000+2*500+3*100) || co["line_items"] == nil {
		t.Fatalf("checkout %d %v", code, co)
	}
	id := co["checkout_id"].(string)
	in := api.creates[0]
	if in.Get("amount") != "3300" || in.Get("metadata[user_seat_qty]") != "2" || in.Get("metadata[user_seat_unit_cents]") != "500" ||
		in.Get("metadata[bot_seat_qty]") != "3" || in.Get("metadata[tenant_qty]") != "1" || in.Get("description") == "" {
		t.Fatalf("intent carries no seat line items: %v", in)
	}
	c, err := r.st.GetCheckout(ctx, id)
	if err != nil || c.SeatsUsers != 2 || c.SeatsBots != 3 || c.AmountCents != 3300 {
		t.Fatalf("checkout row %+v %v", c, err)
	}

	intent := "pi_" + id
	// CONTROL forged: a wrong secret is 400 and writes nothing.
	if code, _ := r.stripeEvent(t, "whsec_forged", now, intentEvent("evt_s1", "payment_intent.succeeded", intent)); code != 400 {
		t.Fatalf("forged webhook %d", code)
	}
	if _, err := r.st.GetTenant(ctx, "acme"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("a forged webhook created the tenant: %v", err)
	}
	if ps, _ := r.st.SeatPeriods(ctx, "acme"); len(ps) != 0 {
		t.Fatalf("a forged webhook wrote a seat period: %v", ps)
	}
	if code, _ := r.stripeEvent(t, whsec, now, intentEvent("evt_s1", "payment_intent.succeeded", intent)); code != 200 {
		t.Fatal(code)
	}
	ten, err := r.st.GetTenant(ctx, "acme")
	if err != nil || ten.SeatsUsers != 2 || ten.SeatsBots != 3 || ten.ProjectID != "" {
		t.Fatalf("paid tenant %+v %v", ten, err)
	}
	ps, _ := r.st.SeatPeriods(ctx, "acme")
	if len(ps) != 1 || !ps[0].PeriodStart.Equal(time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)) || ps[0].SeatsUsers != 2 ||
		ps[0].SeatsBots != 3 || ps[0].CheckoutID != id || ps[0].AmountCents != 3300 {
		t.Fatalf("seat period %+v", ps)
	}
	// CONTROL replay: the same event is a no-op.
	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_s1", "payment_intent.succeeded", intent)); code != 200 || out["status"] != "duplicate" {
		t.Fatalf("replay %d %v", code, out)
	}
	if ps2, _ := r.st.SeatPeriods(ctx, "acme"); len(ps2) != 1 {
		t.Fatalf("replay wrote another period: %v", ps2)
	}
	// CONTROL over cap: 3 bots paid; a 4th new bot seat is refused.
	if err := r.st.SetRoster(ctx, "acme", "box-a", []string{"CLE-1", "CLE-2", "CLE-3"}, now); err != nil {
		t.Fatalf("3 of 3 bot seats: %v", err)
	}
	if err := r.st.SetRoster(ctx, "acme", "box-b", []string{"GRK-1"}, now); !errors.Is(err, store.ErrSeatQuota) {
		t.Fatalf("bot seat over the paid cap: %v", err)
	}
}

// The M2 plan sells no seats; an M4 plan refuses shapes it does not price.
func TestM4SeatRequestRefusals(t *testing.T) {
	api := &stripeAPI{}
	m2 := newRig(t, stripeCfg(t, api.server(t).URL))
	if code, out := m2.do(t, "POST", "/api/v1/checkout", map[string]any{"tenant_id": "acme", "email": "b@example.com", "seats_users": 1}); code != 400 || out["error"] != "seats_not_sold" {
		t.Fatalf("seats on the M2 plan: %d %v", code, out)
	}
	if code, out := m2.do(t, "POST", "/api/v1/checkout", map[string]any{"tenant_id": "acme", "email": "b@example.com", "org": "abc", "app": "xyz"}); code != 400 || out["error"] != "bad_org_app" {
		t.Fatalf("org/app on a hosted plan: %d %v", code, out)
	}
	usersOnly := newRig(t, seatCfg(t, api.server(t).URL, map[string]string{"SPOOL_HUB_PAYMENT_SEAT_BOT_CENTS": "0"}))
	for _, bad := range []map[string]any{
		{"seats_users": 0},                  // a priced kind needs >= 1 (0 would mean unlimited)
		{"seats_users": 51},                 // over SEATS_MAX
		{"seats_users": -1},                 // negative
		{"seats_users": 1, "seats_bots": 2}, // bots are not priced here
	} {
		bad["tenant_id"], bad["email"] = "acme", "b@example.com"
		if code, out := usersOnly.do(t, "POST", "/api/v1/checkout", bad); code != 400 || out["error"] != "bad_seats" {
			t.Fatalf("%v: %d %v", bad, code, out)
		}
	}
	if n := len(api.creates); n != 0 {
		t.Fatalf("a refused checkout reached the rail %d times", n)
	}
}

// 009 T005 + T007 through the paid webhook: a dedicated SKU's project_id is
// {org}-{app}-{env}-{YYYYMMDDHHmm} at the paid event's UTC minute; CONTROL: a
// project_id another tenant holds in that minute retries the next minute.
func TestM4DedicatedProjectIDStampAtPaidMinute(t *testing.T) {
	api := &stripeAPI{}
	paid := time.Date(2026, 9, 17, 17, 43, 59, 0, time.UTC)
	cfg := seatCfg(t, api.server(t).URL, map[string]string{"SPOOL_HUB_PAYMENT_DEDICATED": "true"})
	r := newRigAt(t, cfg, paid)
	ctx := t.Context()
	if code, out := r.do(t, "POST", "/api/v1/checkout", map[string]any{"tenant_id": "acme", "email": "b@example.com", "seats_users": 1, "seats_bots": 1}); code != 400 || out["error"] != "bad_org_app" {
		t.Fatalf("dedicated without org/app: %d %v", code, out)
	}
	pub, _, _ := ed25519.GenerateKey(nil)
	held := "abc-xyz-lde-202609171743"
	if err := r.st.CreateTenant(ctx, store.Tenant{ID: "other", RootPubKey: pub, Org: "abc", App: "xyz", ProjectID: held, BoughtAt: paid}); err != nil {
		t.Fatal(err)
	}
	code, co := r.do(t, "POST", "/api/v1/checkout", map[string]any{"tenant_id": "acme", "email": "b@example.com",
		"seats_users": 1, "seats_bots": 1, "org": "ABC", "app": "xyz"})
	if code != 201 {
		t.Fatalf("dedicated checkout %d %v", code, co)
	}
	id := co["checkout_id"].(string)
	if code, _ := r.stripeEvent(t, whsec, paid, intentEvent("evt_d1", "payment_intent.succeeded", "pi_"+id)); code != 200 {
		t.Fatal(code)
	}
	ten, err := r.st.GetTenant(ctx, "acme")
	if err != nil || ten.ProjectID != "abc-xyz-lde-202609171744" || ten.Org != "abc" || ten.App != "xyz" || !ten.BoughtAt.Equal(paid) {
		t.Fatalf("stamp %+v %v (want the next minute after the clash)", ten, err)
	}
	if o, _ := r.st.GetTenant(ctx, "other"); o.ProjectID != held {
		t.Fatalf("the other tenant's project id moved: %+v", o)
	}
}
