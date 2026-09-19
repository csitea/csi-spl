package payments

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

const pattern = "{tenant}.dev.example.test"

func mustLoad(t *testing.T, env string, vars map[string]string) *Config {
	t.Helper()
	c, err := LoadFrom(env, vars)
	if err != nil {
		t.Fatalf("load %s %v: %v", env, vars, err)
	}
	return c
}

// T018: the boot guard refuses what it cannot run; unusable card keys 503.
func TestConfigFailClosed(t *testing.T) {
	paypal := map[string]string{"SPOOL_HUB_ENABLE_PAYPAL": "true", "SPOOL_HUB_PAYPAL_CLIENT_ID": "cid-1",
		"SPOOL_HUB_PAYPAL_CLIENT_SECRET": "csec-1", "SPOOL_HUB_PAYPAL_WEBHOOK_ID": "wh-1", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"}
	with := func(base map[string]string, k, v string) map[string]string {
		m := map[string]string{}
		for a, b := range base {
			m[a] = b
		}
		m[k] = v
		return m
	}
	refuse := []struct {
		name, env string
		vars      map[string]string
	}{
		{"unknown provider", "dev", map[string]string{"SPOOL_HUB_PAYMENT_PROVIDER": "cardz"}},
		{"fake-pay flag on prd", "prd", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"}},
		{"fake-pay flag in an unnamed env", "", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"}},
		{"fake rail without the flag", "dev", map[string]string{"SPOOL_HUB_PAYMENT_PROVIDER": "fake"}},
		{"fake rail on prd", "prd", map[string]string{"SPOOL_HUB_PAYMENT_PROVIDER": "fake", "SPOOL_HUB_ENABLE_FAKE_PAY": "true"}},
		{"stripe free plan", "prd", map[string]string{"SPOOL_HUB_PAYMENT_PROVIDER": "stripe"}},
		{"stripe http api base outside lde", "dev", map[string]string{"SPOOL_HUB_STRIPE_API_BASE": "http://mock.example.test"}},
		{"paypal on prd", "prd", paypal},
		{"paypal live mode", "dev", with(paypal, "SPOOL_HUB_PAYPAL_MODE", "live")},
		{"paypal without webhook id", "dev", with(paypal, "SPOOL_HUB_PAYPAL_WEBHOOK_ID", "")},
		{"paypal placeholder secret", "dev", with(paypal, "SPOOL_HUB_PAYPAL_CLIENT_SECRET", "PLACEHOLDER-x")},
		{"bad currency", "dev", map[string]string{"SPOOL_HUB_PAYMENT_CURRENCY": "euro"}},
	}
	for _, c := range refuse {
		if _, err := LoadFrom(c.env, c.vars); err == nil {
			t.Errorf("%s: loaded, want a boot refusal", c.name)
		}
	}
	// no rail: boots everywhere, checkout is 503 (prd until keys exist)
	if c := mustLoad(t, "prd", nil); c.Rail() != RailNone || c.FakePayMounted() || len(c.Methods()) != 0 {
		t.Fatalf("prd default rail %q fake=%v", c.Rail(), c.FakePayMounted())
	}
	if c := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"}); c.Rail() != RailFake || !c.FakePayMounted() {
		t.Fatalf("dev fake flag: rail %q", c.Rail())
	}
	// stripe with unusable keys BOOTS (the hub carries the boxes) and guards
	stripe := map[string]string{"SPOOL_HUB_PAYMENT_PROVIDER": "stripe", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"}
	for name, vars := range map[string]map[string]string{
		"unset key":         stripe,
		"placeholder key":   with(stripe, "SPOOL_HUB_STRIPE_SECRET_KEY", "PLACEHOLDER-stripe"),
		"publishable as sk": with(stripe, "SPOOL_HUB_STRIPE_SECRET_KEY", "pk_test_abc"),
	} {
		if c := mustLoad(t, "prd", vars); c.Guard() == "" || c.Rail() != RailCard {
			t.Errorf("%s: want a checkout guard, got %q", name, c.Guard())
		}
	}
	good := with(with(with(stripe, "SPOOL_HUB_STRIPE_SECRET_KEY", "sk_test_abc"), "SPOOL_HUB_STRIPE_WEBHOOK_SECRET", "whsec_abc"),
		"SPOOL_HUB_STRIPE_PUBLISHABLE_KEY", "pk_test_abc")
	if c := mustLoad(t, "prd", good); c.Guard() != "" || StripeKeyMode(c.StripeSecretKey) != "test" {
		t.Fatalf("good stripe keys guarded: %q", c.Guard())
	}
	if c := mustLoad(t, "prd", with(good, "SPOOL_HUB_STRIPE_WEBHOOK_SECRET", "")); c.Guard() == "" {
		t.Fatal("stripe without a webhook secret must guard (the paid event could never verify)")
	}
}

func TestSealOpen(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(nil)
	tok := NewClaimToken()
	sealed, err := Seal(tok, "co_a", priv)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealed, priv) || bytes.Contains(sealed, priv.Seed()) {
		t.Fatal("seal carries the key in clear")
	}
	got, err := Open(tok, "co_a", sealed)
	if err != nil || !got.Equal(priv) {
		t.Fatalf("open: %v", err)
	}
	if _, err := Open(NewClaimToken(), "co_a", sealed); err == nil {
		t.Fatal("a different claim token opened the seal")
	}
	if _, err := Open(tok, "co_b", sealed); err == nil {
		t.Fatal("the seal opened for another checkout id")
	}
	if bytes.Equal(ClaimHash(tok), sealKey(tok)) {
		t.Fatal("the stored claim hash must not be the seal key")
	}
}

type rig struct {
	h    http.Handler
	st   *store.Memory
	mail *mail.Recorder
	logs *bytes.Buffer
}

func newRig(t *testing.T, cfg *Config) *rig {
	t.Helper()
	card, pp, ppv := Wire(cfg)
	return newRigWith(t, cfg, Deps{Card: card, PayPal: pp, PayPalVerifier: ppv})
}

func newRigWith(t *testing.T, cfg *Config, d Deps) *rig {
	t.Helper()
	r := &rig{st: store.NewMemory(), mail: &mail.Recorder{}, logs: &bytes.Buffer{}}
	d.Store, d.Log, d.Mail, d.MailDelivers, d.TenantHostPattern = r.st, zerolog.New(r.logs), r.mail, true, pattern
	h, err := New(cfg, d)
	if err != nil {
		t.Fatal(err)
	}
	r.h = h
	return r
}

func (r *rig) do(t *testing.T, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	w := httptest.NewRecorder()
	r.h.ServeHTTP(w, httptest.NewRequest(method, path, rd))
	out := map[string]any{}
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

// T020 + T021: the whole buy on the fake rail, key shown and mailed once.
func TestFakeBuyEndToEnd(t *testing.T) {
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"})
	r := newRig(t, cfg)

	if code, p := r.do(t, "GET", "/api/v1/checkout/plan", nil); code != 200 || p["rail"] != RailFake || p["amount_cents"] != float64(2000) {
		t.Fatalf("plan %d %v", code, p)
	}
	for _, bad := range []map[string]string{
		{"tenant_id": "dev", "email": "a@example.com"},       // reserved slug
		{"tenant_id": "Bad Slug!", "email": "a@example.com"}, // invalid
	} {
		if code, _ := r.do(t, "POST", "/api/v1/checkout", bad); code != 400 {
			t.Fatalf("bad slug %v: %d", bad, code)
		}
	}
	if code, _ := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "not-an-address"}); code != 400 {
		t.Fatalf("bad email: %d", code)
	}
	code, co := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "buyer@example.com"})
	if code != 201 || co["rail"] != RailFake || co["tenant_url"] != "https://acme.dev.example.test" || co["client_secret"] != nil || co["method"] != MethodCard {
		t.Fatalf("checkout %d %v", code, co)
	}
	id, tok := co["checkout_id"].(string), co["claim_token"].(string)
	if _, err := r.st.GetTenant(t.Context(), "acme"); err == nil {
		t.Fatal("checkout created the tenant before payment")
	}
	if code, _ := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "other@example.com"}); code != 409 {
		t.Fatalf("second buyer on a held slug: %d", code)
	}
	if code, s := r.do(t, "GET", "/api/v1/checkout/"+id, nil); code != 200 || s["status"] != "pending" || s["claimed"] != false {
		t.Fatalf("status %d %v", code, s)
	}
	if code, e := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": tok}); code != 409 || e["error"] != "not_paid" {
		t.Fatalf("claim before paid %d %v", code, e)
	}
	if code, f := r.do(t, "POST", "/api/v1/checkout/fake-pay", map[string]string{"checkout_id": id}); code != 200 || f["applied"] != true {
		t.Fatalf("fake-pay %d %v", code, f)
	}
	if code, f := r.do(t, "POST", "/api/v1/checkout/fake-pay", map[string]string{"checkout_id": id}); code != 200 || f["applied"] != false {
		t.Fatalf("fake-pay twice %d %v", code, f)
	}
	ten, err := r.st.GetTenant(t.Context(), "acme")
	if err != nil || ten.BillingStatus != billing.StatusActive {
		t.Fatalf("tenant after fake-pay: %+v %v", ten, err)
	}
	if code, _ := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": NewClaimToken()}); code != 404 {
		t.Fatalf("wrong claim token: %d", code)
	}
	code, cl := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": tok})
	if code != 200 || cl["emailed"] != true || cl["tenant_url"] != "https://acme.dev.example.test" {
		t.Fatalf("claim %d %v", code, cl)
	}
	raw, _ := base64.StdEncoding.DecodeString(cl["root_private_key"].(string))
	if len(raw) != ed25519.PrivateKeySize || !ed25519.PrivateKey(raw).Public().(ed25519.PublicKey).Equal(ten.RootPubKey) {
		t.Fatal("claimed key is not the tenant's root key")
	}
	if code, e := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": tok}); code != 410 || e["error"] != "claimed" {
		t.Fatalf("second claim %d %v", code, e)
	}
	msgs := r.mail.Messages()
	if len(msgs) != 1 || msgs[0].To != "buyer@example.com" || msgs[0].Template != TemplateTenantWelcome ||
		!strings.Contains(msgs[0].TextBody, cl["root_private_key"].(string)) || !strings.Contains(msgs[0].TextBody, "https://acme.dev.example.test") {
		t.Fatalf("want exactly one welcome mail with URL + key, got %+v", msgs)
	}
	// FR-015: neither the key nor the claim token reaches a log line.
	if l := r.logs.String(); strings.Contains(l, cl["root_private_key"].(string)) || strings.Contains(l, tok) {
		t.Fatal("root private key or claim token logged")
	}
	if code, _ := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "c@example.com"}); code != 409 {
		t.Fatalf("buy an existing tenant: %d", code)
	}
}

// T020 control: the fake rail is absent when the flag is off, and refuses a
// checkout that belongs to a real rail.
func TestFakePayRefused(t *testing.T) {
	off := newRig(t, mustLoad(t, "dev", nil))
	if code, _ := off.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "a@example.com"}); code != 503 {
		t.Fatalf("checkout with no rail: %d", code)
	}
	// a pending fake-rail checkout exists (e.g. held before the flag went off):
	// with the flag off the route is not there, so it cannot be paid
	pub0, _, _ := ed25519.GenerateKey(nil)
	held := store.Checkout{ID: "co_held", TenantID: "acme", Provider: ProviderFake, Currency: "eur",
		RootPubKey: pub0, SealedRootKey: []byte("x"), ClaimHash: ClaimHash("t")}
	if err := off.st.HoldCheckout(t.Context(), held, time.Now(), time.Hour); err != nil {
		t.Fatal(err)
	}
	if code, _ := off.do(t, "POST", "/api/v1/checkout/fake-pay", map[string]string{"checkout_id": "co_held"}); code != 405 && code != 404 {
		t.Fatalf("fake-pay answered with the flag off: %d", code)
	}
	if c, _ := off.st.GetCheckout(t.Context(), "co_held"); c.Status != store.CheckoutPending {
		t.Fatalf("flag off, checkout became %q", c.Status)
	}
	if _, err := off.st.GetTenant(t.Context(), "acme"); err == nil {
		t.Fatal("flag off, fake-pay created a tenant")
	}
	if _, err := LoadFrom("prd", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"}); err == nil {
		t.Fatal("prd booted with fake-pay on")
	}
	// a real-rail checkout in a dev hub that also has the fake rail
	on := newRig(t, mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"}))
	pub, _, _ := ed25519.GenerateKey(nil)
	real := store.Checkout{ID: "co_real", TenantID: "acme", Provider: ProviderStripe, Currency: "eur",
		RootPubKey: pub, SealedRootKey: []byte("x"), ClaimHash: ClaimHash("t")}
	if err := on.st.HoldCheckout(t.Context(), real, time.Now(), time.Hour); err != nil {
		t.Fatal(err)
	}
	if code, e := on.do(t, "POST", "/api/v1/checkout/fake-pay", map[string]string{"checkout_id": "co_real"}); code != 422 || e["error"] != "not_fake_checkout" {
		t.Fatalf("fake-pay on a real checkout: %d %v", code, e)
	}
	if _, err := on.st.GetTenant(t.Context(), "acme"); err == nil {
		t.Fatal("fake-pay created a tenant for a real-rail checkout")
	}
	// the card webhook on a hub whose rail is not stripe refuses everything
	if code, _ := on.do(t, "POST", RouteStripeWebhook, map[string]string{"id": "evt_1", "type": "payment_intent.succeeded"}); code != 400 {
		t.Fatalf("stripe webhook on the fake rail: %d", code)
	}
	if code, _ := on.do(t, "POST", RoutePayPalWebhook, map[string]string{"id": "WH-1", "event_type": "PAYMENT.CAPTURE.COMPLETED"}); code != 400 {
		t.Fatalf("paypal webhook with paypal off: %d", code)
	}
}
