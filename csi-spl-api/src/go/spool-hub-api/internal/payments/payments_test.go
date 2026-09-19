package payments

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
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

// T018: the boot guard refuses what it cannot run.
func TestConfigFailClosed(t *testing.T) {
	hosted := map[string]string{
		"SPOOL_HUB_PAYMENT_PROVIDER": "hosted-hmac", "SPOOL_HUB_PAYMENT_MERCHANT_ID": "375917",
		"SPOOL_HUB_PAYMENT_SECRET_KEY": "a-real-looking-secret", "SPOOL_HUB_PAYMENT_API_BASE": "https://pay.example.test",
		"SPOOL_HUB_PAYMENT_SUCCESS_URL":  "https://dev.example.test/checkout/success",
		"SPOOL_HUB_PAYMENT_CANCEL_URL":   "https://dev.example.test/checkout",
		"SPOOL_HUB_PAYMENT_CALLBACK_URL": "https://dev.example.test/api/v1/webhooks/payment",
		"SPOOL_HUB_PAYMENT_PLAN_CENTS":   "2000",
	}
	with := func(k, v string) map[string]string {
		m := map[string]string{}
		for a, b := range hosted {
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
		{"hosted placeholder secret", "prd", with("SPOOL_HUB_PAYMENT_SECRET_KEY", "PLACEHOLDER-secret")},
		{"hosted missing secret", "prd", with("SPOOL_HUB_PAYMENT_SECRET_KEY", "")},
		{"hosted missing merchant", "prd", with("SPOOL_HUB_PAYMENT_MERCHANT_ID", "")},
		{"hosted missing api base", "prd", with("SPOOL_HUB_PAYMENT_API_BASE", "")},
		{"hosted http api base outside lde", "dev", with("SPOOL_HUB_PAYMENT_API_BASE", "http://pay.example.test")},
		{"hosted missing callback", "prd", with("SPOOL_HUB_PAYMENT_CALLBACK_URL", "")},
		{"hosted free plan", "prd", with("SPOOL_HUB_PAYMENT_PLAN_CENTS", "0")},
		{"bad currency", "dev", map[string]string{"SPOOL_HUB_PAYMENT_CURRENCY": "euro"}},
	}
	for _, c := range refuse {
		if _, err := LoadFrom(c.env, c.vars); err == nil {
			t.Errorf("%s: loaded, want a boot refusal", c.name)
		}
	}
	// no rail: boots everywhere, checkout is 503 (prd until keys exist)
	if c := mustLoad(t, "prd", nil); c.Rail() != RailNone || c.FakePayMounted() {
		t.Fatalf("prd default rail %q fake=%v", c.Rail(), c.FakePayMounted())
	}
	if c := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"}); c.Rail() != RailFake || !c.FakePayMounted() {
		t.Fatalf("dev fake flag: rail %q", c.Rail())
	}
	if c := mustLoad(t, "prd", hosted); c.Rail() != RailHosted || c.FakePayMounted() {
		t.Fatalf("prd hosted: rail %q", c.Rail())
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

func newRig(t *testing.T, cfg *Config, prov PaymentProvider, ver WebhookVerifier) *rig {
	t.Helper()
	r := &rig{st: store.NewMemory(), mail: &mail.Recorder{}, logs: &bytes.Buffer{}}
	h, err := New(cfg, Deps{Store: r.st, Log: zerolog.New(r.logs), Mail: r.mail, MailDelivers: true,
		TenantHostPattern: pattern, Provider: prov, Verifier: ver})
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
	r := newRig(t, cfg, Fake{}, nil)

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
	if code != 201 || co["rail"] != RailFake || co["tenant_url"] != "https://acme.dev.example.test" || co["redirect_url"] != nil {
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
	off := newRig(t, mustLoad(t, "dev", nil), nil, nil)
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
	on := newRig(t, mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"}), Fake{}, nil)
	pub, _, _ := ed25519.GenerateKey(nil)
	real := store.Checkout{ID: "co_real", TenantID: "acme", Provider: ProviderHostedHMAC, Currency: "eur",
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
	// the webhook on a rail without a signed callback refuses everything
	if code, _ := on.do(t, "POST", "/api/v1/webhooks/payment", map[string]string{"x": "y"}); code != 400 {
		t.Fatalf("webhook without a verifier: %d", code)
	}
}

// hostedRig: a hosted-hmac hub plus a fake provider API that checks our
// request signature and hands back a hosted page URL.
func hostedRig(t *testing.T) (*rig, *HostedHMAC) {
	t.Helper()
	const secret, merchant = "a-real-looking-secret", "375917"
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if !ValidCheckoutHMAC(secret, "sha256", r.Header.Get("signature"), checkoutFields(r), string(body)) {
			http.Error(w, "bad sig", 401)
			return
		}
		var req hostedCreateReq
		_ = json.Unmarshal(body, &req)
		if r.URL.Path != "/payments" || req.Amount != 2000 || req.Stamp == "" || req.CallbackURLs.Success == "" {
			http.Error(w, "bad request", 400)
			return
		}
		_ = json.NewEncoder(w).Encode(hostedCreateResp{TransactionID: "txn-" + req.Stamp, Href: "https://pay.example.test/p/" + req.Stamp})
	}))
	t.Cleanup(api.Close)
	cfg := mustLoad(t, "lde", map[string]string{
		"SPOOL_HUB_PAYMENT_PROVIDER": "hosted-hmac", "SPOOL_HUB_PAYMENT_MERCHANT_ID": merchant,
		"SPOOL_HUB_PAYMENT_SECRET_KEY": secret, "SPOOL_HUB_PAYMENT_API_BASE": api.URL,
		"SPOOL_HUB_PAYMENT_SUCCESS_URL": "http://localhost:3000/checkout/success", "SPOOL_HUB_PAYMENT_CANCEL_URL": "http://localhost:3000/checkout",
		"SPOOL_HUB_PAYMENT_CALLBACK_URL": "http://localhost:58080/api/v1/webhooks/payment", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000",
	})
	prov, ver, err := Wire(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return newRig(t, cfg, prov, ver), prov.(*HostedHMAC)
}

func signedCallback(p *HostedHMAC, secret string, q map[string]string) string {
	v := url.Values{}
	for k, x := range q {
		v.Set(k, x)
	}
	v.Set("signature", SignCheckoutHMAC(secret, "sha256", q, ""))
	return "/api/v1/webhooks/payment?" + v.Encode()
}

// T019 controls: forged signature refused and writes nothing; replay no-op.
func TestHostedWebhookSignedPaidReplay(t *testing.T) {
	r, p := hostedRig(t)
	code, co := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "buyer@example.com"})
	if code != 201 || co["rail"] != RailHosted || !strings.HasPrefix(co["redirect_url"].(string), "https://pay.example.test/p/co_") {
		t.Fatalf("hosted checkout %d %v", code, co)
	}
	id := co["checkout_id"].(string)
	if c, _ := r.st.GetCheckout(t.Context(), id); c.ProviderRef != "txn-"+id || c.Provider != ProviderHostedHMAC {
		t.Fatalf("checkout row %+v", c)
	}
	fields := map[string]string{"checkout-account": p.MerchantID, "checkout-algorithm": "sha256",
		"checkout-amount": "2000", "checkout-stamp": id, "checkout-reference": id,
		"checkout-transaction-id": "txn-" + id, "checkout-status": "ok", "checkout-provider": "x"}
	good := signedCallback(p, p.Secret, fields)

	// forged: signed with the wrong secret
	if code, _ := r.do(t, "GET", signedCallback(p, "not-the-secret", fields), nil); code != 400 {
		t.Fatalf("forged signature: %d", code)
	}
	// tampered: good signature, status field changed after signing
	if code, _ := r.do(t, "GET", strings.Replace(good, "checkout-status=ok", "checkout-status=fail", 1), nil); code != 400 {
		t.Fatalf("tampered field: %d", code)
	}
	// someone else's account, correctly signed with our secret
	other := map[string]string{}
	for k, v := range fields {
		other[k] = v
	}
	other["checkout-account"] = "999"
	if code, _ := r.do(t, "GET", signedCallback(p, p.Secret, other), nil); code != 400 {
		t.Fatalf("foreign account: %d", code)
	}
	if _, err := r.st.GetTenant(t.Context(), "acme"); err == nil {
		t.Fatal("a refused webhook created the tenant")
	}
	// the genuine callback: the forged ones left no dedup row behind
	if code, out := r.do(t, "GET", good, nil); code != 200 || out["action"] != store.PayOutcomePaid {
		t.Fatalf("genuine callback %d %v", code, out)
	}
	if ten, err := r.st.GetTenant(t.Context(), "acme"); err != nil || ten.BillingStatus != billing.StatusActive {
		t.Fatalf("tenant after paid: %+v %v", ten, err)
	}
	// replay: the provider delivers the same event again
	if err := r.st.SetBillingStatus(t.Context(), "acme", billing.StatusGrace); err != nil {
		t.Fatal(err)
	}
	if code, out := r.do(t, "GET", good, nil); code != 200 || out["status"] != "duplicate" {
		t.Fatalf("replay %d %v", code, out)
	}
	if ten, _ := r.st.GetTenant(t.Context(), "acme"); ten.BillingStatus != billing.StatusGrace {
		t.Fatalf("replay changed the tenant: %q", ten.BillingStatus)
	}
	// POST with the fields as headers verifies the same way
	refund := map[string]string{}
	for k, v := range fields {
		refund[k] = v
	}
	refund["checkout-status"] = "refund"
	req := httptest.NewRequest("POST", "/api/v1/webhooks/payment", nil)
	for k, v := range refund {
		req.Header.Set(k, v)
	}
	req.Header.Set("signature", SignCheckoutHMAC(p.Secret, "sha256", refund, ""))
	w := httptest.NewRecorder()
	r.h.ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("header refund callback %d %s", w.Code, w.Body)
	}
	if ten, _ := r.st.GetTenant(t.Context(), "acme"); ten.BillingStatus != billing.StatusUnpaid {
		t.Fatalf("after refund: %q", ten.BillingStatus)
	}
}
