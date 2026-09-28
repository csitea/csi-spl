package payments

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

const pattern = "{tenant}.dev.example.test"

const claimURL = "https://dev.example.test/checkout/claim"

// withClaimURL adds the WUI claim page every rail needs (017 T008).
func withClaimURL(vars map[string]string) map[string]string {
	m := map[string]string{"SPOOL_HUB_PAYMENT_CLAIM_URL": claimURL}
	for k, v := range vars {
		m[k] = v
	}
	return m
}

func mustLoad(t *testing.T, env string, vars map[string]string) *Config {
	t.Helper()
	c, err := LoadFrom(env, withClaimURL(vars))
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
	refuse = append(refuse, struct {
		name, env string
		vars      map[string]string
	}{"claim page over http outside lde", "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_CLAIM_URL": "http://dev.example.test/c"}},
		struct {
			name, env string
			vars      map[string]string
		}{"claim page with a fragment", "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_CLAIM_URL": claimURL + "#x"}})
	for _, c := range refuse {
		vars := withClaimURL(c.vars)
		if v, ok := c.vars["SPOOL_HUB_PAYMENT_CLAIM_URL"]; ok {
			vars["SPOOL_HUB_PAYMENT_CLAIM_URL"] = v
		}
		if _, err := LoadFrom(c.env, vars); err == nil {
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
	if code != 201 || co["rail"] != RailFake || co["tenant_url"] != "https://dev.example.test/login?tenant=acme" || co["client_secret"] != nil || co["method"] != MethodCard {
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
	// fake-pay sent the one email: tenant URL + claim link, NO key (SEC-03)
	msgs := r.mail.Messages()
	if len(msgs) != 1 || msgs[0].To != "buyer@example.com" || msgs[0].Template != TemplateTenantPaid ||
		!strings.Contains(msgs[0].TextBody, "https://dev.example.test/login?tenant=acme") || !strings.Contains(msgs[0].TextBody, claimURL+"#checkout="+id+"&token=") {
		t.Fatalf("want exactly one tenant_paid mail with the URL + claim link, got %+v", msgs)
	}
	// no buyer locale is kept, so the claim mail is in
	// the default locale (en) and its link carries no locale prefix.
	if msgs[0].Locale != "en" || !strings.Contains(msgs[0].TextBody, "\n"+claimURL+"#checkout=") {
		t.Fatalf("claim mail locale %q / link:\n%s", msgs[0].Locale, msgs[0].TextBody)
	}
	link := msgs[0].TextBody[strings.Index(msgs[0].TextBody, "&token=")+len("&token="):]
	link = strings.TrimSpace(strings.SplitN(link, "\n", 2)[0])
	ten, _ = r.st.GetTenant(t.Context(), "acme")
	placeholder := ten.RootPubKey
	// the emailed link claims (first claim wins) and mints the key now
	code, cl := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": link})
	if code != 200 || cl["tenant_url"] != "https://dev.example.test/login?tenant=acme" {
		t.Fatalf("claim via link %d %v", code, cl)
	}
	raw, _ := base64.StdEncoding.DecodeString(cl["root_private_key"].(string))
	ten, _ = r.st.GetTenant(t.Context(), "acme")
	if len(raw) != ed25519.PrivateKeySize || !ed25519.PrivateKey(raw).Public().(ed25519.PublicKey).Equal(ten.RootPubKey) || ten.RootPubKey.Equal(placeholder) {
		t.Fatal("the claim must mint a new root key and rotate the tenant to it")
	}
	// CONTROL (SEC-03): no key material in the mail, before or after the claim
	key := cl["root_private_key"].(string)
	for _, m := range r.mail.Messages() {
		if strings.Contains(m.TextBody, key) || regexp.MustCompile(`[A-Za-z0-9+/]{86}==`).MatchString(m.TextBody) {
			t.Fatalf("key material in the mail body: %q", m.TextBody)
		}
	}
	// the link and the browser token are both burnt: 410
	for name, tk := range map[string]string{"link": link, "browser": tok} {
		if code, e := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": tk}); code != 410 || e["error"] != "claimed" {
			t.Fatalf("second claim via %s %d %v", name, code, e)
		}
	}
	if len(r.mail.Messages()) != 1 {
		t.Fatal("the claim must not send a second mail")
	}
	// FR-015: neither the key nor a claim token reaches a log line.
	if l := r.logs.String(); strings.Contains(l, key) || strings.Contains(l, tok) || strings.Contains(l, link) {
		t.Fatal("root private key or a claim token logged")
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
		RootPubKey: pub0, ClaimHash: ClaimHash("t")}
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
		RootPubKey: pub, ClaimHash: ClaimHash("t")}
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

// 017 T008: the claim window is short; after it both tokens are dead.
func TestClaimLinkExpires(t *testing.T) {
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_CLAIM_TTL": "1h"})
	now := time.Now()
	card, pp, ppv := Wire(cfg)
	r := newRigWith(t, cfg, Deps{Card: card, PayPal: pp, PayPalVerifier: ppv, Now: func() time.Time { return now }})
	_, co := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "buyer@example.com"})
	id := co["checkout_id"].(string)
	if code, _ := r.do(t, "POST", "/api/v1/checkout/fake-pay", map[string]string{"checkout_id": id}); code != 200 {
		t.Fatal(code)
	}
	now = now.Add(61 * time.Minute)
	if code, e := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": co["claim_token"].(string)}); code != 410 || e["error"] != "claim_expired" {
		t.Fatalf("claim after the TTL: %d %v", code, e)
	}
}

// An unset claim page must not crash-loop the hub on an image roll: it boots,
// and checkout fail-closes with 503 until the env catches up.
func TestNoClaimPageGuards503(t *testing.T) {
	cfg, err := LoadFrom("dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"})
	if err != nil {
		t.Fatalf("an unset claim page must not refuse boot: %v", err)
	}
	if cfg.Guard() == "" {
		t.Fatal("an unset claim page must guard checkout")
	}
	r := newRig(t, cfg)
	if code, e := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "a@example.com"}); code != 503 || e["detail"] != GuardReasonMisconfigured {
		t.Fatalf("checkout without a claim page: %d %v", code, e)
	}
}
