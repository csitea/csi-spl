package payments

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

const whsec = "whsec_test_secret"

// stripeAPI stands in for Stripe (the role csi-rel's stripe-mock plays): it
// checks the bearer key, the Stripe-Version and the Idempotency-Key, and
// answers a PaymentIntent.
type stripeAPI struct {
	mu       sync.Mutex
	creates  []url.Values
	idem     []string
	cancels  []string
	cancelIs string // error.code the cancel answers with ("" = 200)
}

func (a *stripeAPI) server(t *testing.T) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer sk_test_abc" || r.Header.Get("Stripe-Version") != DefaultStripeAPIVersion {
			http.Error(w, `{"error":{"message":"bad auth"}}`, 401)
			return
		}
		_ = r.ParseForm()
		a.mu.Lock()
		defer a.mu.Unlock()
		switch {
		case r.URL.Path == "/v1/payment_intents":
			a.creates, a.idem = append(a.creates, r.PostForm), append(a.idem, r.Header.Get("Idempotency-Key"))
			id := "pi_" + r.PostForm.Get("metadata[order_id]")
			_ = json.NewEncoder(w).Encode(map[string]string{"id": id, "client_secret": id + "_secret_x"})
		case strings.HasSuffix(r.URL.Path, "/cancel"):
			a.cancels = append(a.cancels, r.URL.Path)
			if a.cancelIs != "" {
				w.WriteHeader(400)
				_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": a.cancelIs}})
				return
			}
			_, _ = w.Write([]byte(`{}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func stripeCfg(t *testing.T, base string) *Config {
	return mustLoad(t, "lde", map[string]string{"SPOOL_HUB_PAYMENT_PROVIDER": "stripe", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000",
		"SPOOL_HUB_STRIPE_SECRET_KEY": "sk_test_abc", "SPOOL_HUB_STRIPE_WEBHOOK_SECRET": whsec,
		"SPOOL_HUB_STRIPE_PUBLISHABLE_KEY": "pk_test_abc", "SPOOL_HUB_STRIPE_API_BASE": base})
}

func (r *rig) stripeEvent(t *testing.T, secret string, ts time.Time, ev map[string]any) (int, map[string]any) {
	t.Helper()
	raw, _ := json.Marshal(ev)
	req := httptest.NewRequest("POST", RouteStripeWebhook, bytes.NewReader(raw))
	req.Header.Set("Stripe-Signature", SignStripe(string(raw), secret, ts))
	w := httptest.NewRecorder()
	r.h.ServeHTTP(w, req)
	out := map[string]any{}
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func intentEvent(id, typ, intent string) map[string]any {
	obj := map[string]any{"id": intent}
	if strings.HasPrefix(typ, "charge.") {
		obj = map[string]any{"id": "ch_1", "payment_intent": intent}
	}
	return map[string]any{"id": id, "type": typ, "data": map[string]any{"object": obj}}
}

// T018/T019 on the Stripe card rail (csi-rel canon): intent created with the
// checkout id as metadata + Idempotency-Key; forged, stale and replayed
// webhooks change nothing; succeeded creates the tenant; refund → unpaid.
func TestStripeCardRail(t *testing.T) {
	api := &stripeAPI{}
	r := newRig(t, stripeCfg(t, api.server(t).URL))

	if code, p := r.do(t, "GET", "/api/v1/checkout/plan", nil); code != 200 || p["rail"] != RailCard || p["publishable_key"] != "pk_test_abc" || p["available"] != true {
		t.Fatalf("plan %d %v", code, p)
	}
	code, co := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "buyer@example.com"})
	id := co["checkout_id"].(string)
	if code != 201 || co["rail"] != RailCard || co["client_secret"] != "pi_"+id+"_secret_x" || co["publishable_key"] != "pk_test_abc" {
		t.Fatalf("checkout %d %v", code, co)
	}
	if len(api.creates) != 1 || api.creates[0].Get("amount") != "2000" || api.creates[0].Get("currency") != "eur" ||
		api.creates[0].Get("metadata[order_id]") != id || api.idem[0] != id || api.creates[0].Get("automatic_payment_methods[enabled]") != "true" {
		t.Fatalf("intent create %v idem %v", api.creates, api.idem)
	}
	intent := "pi_" + id
	now := time.Now()
	for name, c := range map[string]struct {
		secret string
		ts     time.Time
	}{"forged secret": {"whsec_wrong", now}, "stale timestamp": {whsec, now.Add(-10 * time.Minute)}} {
		if code, _ := r.stripeEvent(t, c.secret, c.ts, intentEvent("evt_ok", "payment_intent.succeeded", intent)); code != 400 {
			t.Fatalf("%s: %d", name, code)
		}
	}
	if _, err := r.st.GetTenant(t.Context(), "acme"); err == nil {
		t.Fatal("a refused webhook created the tenant")
	}
	// failed payment: audit only (csi-rel), the buyer may retry the intent
	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_fail", "payment_intent.payment_failed", intent)); code != 200 || out["action"] != store.PayOutcomeIgnored {
		t.Fatalf("payment_failed %d %v", code, out)
	}
	if c, _ := r.st.GetCheckout(t.Context(), id); c.Status != store.CheckoutPending {
		t.Fatalf("payment_failed moved the checkout to %q", c.Status)
	}
	// the genuine event (same id the forged ones used: they left no dedup row)
	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_ok", "payment_intent.succeeded", intent)); code != 200 || out["action"] != store.PayOutcomePaid {
		t.Fatalf("succeeded %d %v", code, out)
	}
	if ten, err := r.st.GetTenant(t.Context(), "acme"); err != nil || ten.BillingStatus != billing.StatusActive {
		t.Fatalf("tenant after paid: %+v %v", ten, err)
	}
	_ = r.st.SetBillingStatus(t.Context(), "acme", billing.StatusGrace)
	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_ok", "payment_intent.succeeded", intent)); code != 200 || out["status"] != "duplicate" {
		t.Fatalf("replay %d %v", code, out)
	}
	if ten, _ := r.st.GetTenant(t.Context(), "acme"); ten.BillingStatus != billing.StatusGrace {
		t.Fatalf("replay changed the tenant to %q", ten.BillingStatus)
	}
	if code, out := r.stripeEvent(t, whsec, now, intentEvent("evt_unknown_intent", "payment_intent.succeeded", "pi_other")); code != 200 || out["action"] != store.PayOutcomeNoMatch {
		t.Fatalf("unknown intent %d %v", code, out)
	}
	if code, _ := r.stripeEvent(t, whsec, now, intentEvent("evt_ref", "charge.refunded", intent)); code != 200 {
		t.Fatalf("refund %d", code)
	}
	if ten, _ := r.st.GetTenant(t.Context(), "acme"); ten.BillingStatus != billing.StatusUnpaid {
		t.Fatalf("after refund: %q", ten.BillingStatus)
	}
	// claim works the same on the card rail
	if code, cl := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": co["claim_token"].(string)}); code != 200 || cl["root_private_key"] == nil {
		t.Fatalf("claim %d %v", code, cl)
	}
	if m := r.mail.Messages(); len(m) != 1 || m[0].Template != TemplateTenantPaid {
		t.Fatalf("the signed paid event sends exactly one claim-link mail: %+v", m)
	}
	// a held slug cancels the second intent at the provider (csi-rel CancelIntent)
	code, co2 := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "beta", "email": "b@example.com"})
	if code != 201 {
		t.Fatal(code)
	}
	_ = co2
	if code, _ := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "beta", "email": "c@example.com"}); code != 409 || len(api.cancels) != 1 {
		t.Fatalf("held slug: %d, cancels %v", code, api.cancels)
	}
}

// csi-rel F-17: unusable keys keep the hub up and fail-close checkout.
func TestStripeGuard503(t *testing.T) {
	cfg := mustLoad(t, "prd", map[string]string{"SPOOL_HUB_PAYMENT_PROVIDER": "stripe", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000",
		"SPOOL_HUB_STRIPE_SECRET_KEY": "PLACEHOLDER-stripe-secret"})
	r := newRig(t, cfg)
	if code, e := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "a@example.com"}); code != 503 || e["detail"] != GuardReasonMisconfigured {
		t.Fatalf("guarded checkout %d %v", code, e)
	}
	if _, p := r.do(t, "GET", "/api/v1/checkout/plan", nil); p["available"] != false {
		t.Fatalf("plan must say unavailable: %v", p)
	}
}

func TestStripeCancelBenign(t *testing.T) {
	api := &stripeAPI{cancelIs: "payment_intent_unexpected_state"}
	s := &StripePayments{SecretKey: "sk_test_abc", BaseURL: api.server(t).URL}
	if err := s.CancelIntent(context.Background(), "pi_1"); err != nil {
		t.Fatalf("terminal intent cancel must be benign: %v", err)
	}
	api.cancelIs = "resource_missing"
	if err := s.CancelIntent(context.Background(), "pi_1"); err == nil {
		t.Fatal("a real cancel error was swallowed")
	}
}

// --- PayPal (off by default, not live-tested) -------------------------------

type paypalAPI struct {
	mu       sync.Mutex
	captures []string
}

func (a *paypalAPI) server(t *testing.T) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		switch {
		case r.URL.Path == "/v1/oauth2/token":
			if u, p, ok := r.BasicAuth(); !ok || u != "cid-1" || p != "csec-1" {
				http.Error(w, "{}", 401)
				return
			}
			_, _ = w.Write([]byte(`{"access_token":"tok","expires_in":3600}`))
		case r.URL.Path == "/v2/checkout/orders":
			var body struct {
				PurchaseUnits []struct {
					ReferenceID string `json:"reference_id"`
					Amount      struct {
						Value string `json:"value"`
					} `json:"amount"`
				} `json:"purchase_units"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			if r.Header.Get("Authorization") != "Bearer tok" || len(body.PurchaseUnits) != 1 || body.PurchaseUnits[0].Amount.Value != "20.00" {
				http.Error(w, "{}", 400)
				return
			}
			id := "ORDER-" + body.PurchaseUnits[0].ReferenceID
			_ = json.NewEncoder(w).Encode(map[string]any{"id": id, "links": []map[string]string{{"rel": "approve", "href": "https://pp.example.test/approve/" + id}}})
		case strings.HasSuffix(r.URL.Path, "/capture"):
			a.captures = append(a.captures, r.URL.Path)
			_, _ = w.Write([]byte(`{"id":"x","payer":{"payer_id":"P1"},"purchase_units":[{"payments":{"captures":[{"id":"CAP-1","status":"COMPLETED"}]}}]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func selfSignedCert(t *testing.T) (*rsa.PrivateKey, []byte) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return key, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func TestPayPalRail(t *testing.T) {
	api := &paypalAPI{}
	cfg := mustLoad(t, "lde", map[string]string{"SPOOL_HUB_ENABLE_PAYPAL": "true", "SPOOL_HUB_PAYPAL_CLIENT_ID": "cid-1",
		"SPOOL_HUB_PAYPAL_CLIENT_SECRET": "csec-1", "SPOOL_HUB_PAYPAL_WEBHOOK_ID": "wh-1", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000",
		"SPOOL_HUB_PAYPAL_API_BASE": api.server(t).URL})
	key, certPEM := selfSignedCert(t)
	card, pp, ppv := Wire(cfg)
	ppv.Fetch = func(context.Context, string) ([]byte, error) { return certPEM, nil }
	r := newRigWith(t, cfg, Deps{Card: card, PayPal: pp, PayPalVerifier: ppv})

	if _, p := r.do(t, "GET", "/api/v1/checkout/plan", nil); p["paypal_client_id"] != "cid-1" {
		t.Fatalf("plan %v", p)
	}
	if code, _ := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "a@example.com"}); code != 503 {
		t.Fatalf("card with no card rail: %d", code)
	}
	code, co := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "a@example.com", "method": "paypal"})
	id := co["checkout_id"].(string)
	if code != 201 || co["provider_order_id"] != "ORDER-"+id || co["approve_url"] == nil {
		t.Fatalf("paypal checkout %d %v", code, co)
	}
	if code, _ := r.do(t, "POST", "/api/v1/checkout/paypal/capture", map[string]string{"checkout_id": id}); code != 202 || len(api.captures) != 1 {
		t.Fatalf("capture %d %v", code, api.captures)
	}
	if _, err := r.st.GetTenant(t.Context(), "acme"); err == nil {
		t.Fatal("the capture response must not mark paid (the webhook does)")
	}
	send := func(signer *rsa.PrivateKey, webhookID string) int {
		body := `{"id":"WH-1","event_type":"PAYMENT.CAPTURE.COMPLETED","resource":{"id":"CAP-1","supplementary_data":{"related_ids":{"order_id":"ORDER-` + id + `"}}}}`
		tid, tt := "tx-1", time.Now().UTC().Format(time.RFC3339)
		d := sha256.Sum256([]byte(PayPalSignedMessage(tid, tt, webhookID, body)))
		sig, _ := rsa.SignPKCS1v15(rand.Reader, signer, crypto.SHA256, d[:])
		req := httptest.NewRequest("POST", RoutePayPalWebhook, strings.NewReader(body))
		for k, v := range map[string]string{"paypal-transmission-id": tid, "paypal-transmission-time": tt,
			"paypal-transmission-sig": base64.StdEncoding.EncodeToString(sig), "paypal-cert-url": "https://api.paypal.com/cert.pem",
			"paypal-auth-algo": "SHA256withRSA"} {
			req.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		r.h.ServeHTTP(w, req)
		_, _ = io.Copy(io.Discard, w.Body)
		return w.Code
	}
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	if code := send(other, "wh-1"); code != 400 {
		t.Fatalf("forged paypal signature: %d", code)
	}
	if code := send(key, "wh-someone-else"); code != 400 {
		t.Fatalf("another webhook id: %d", code)
	}
	if _, err := r.st.GetTenant(t.Context(), "acme"); err == nil {
		t.Fatal("a refused paypal webhook created the tenant")
	}
	if code := send(key, "wh-1"); code != 200 {
		t.Fatalf("genuine paypal webhook: %d", code)
	}
	if ten, err := r.st.GetTenant(t.Context(), "acme"); err != nil || ten.BillingStatus != billing.StatusActive {
		t.Fatalf("tenant after capture completed: %+v %v", ten, err)
	}
}

// 009 T001 / FR-001: the M2 checkout SKU is ONE tenant, never seats. The
// provider is asked for the plan amount only (no quantity / line items /
// seat fields), and the paid tenant carries no seats and no project id
// (a hosted tenant; the dedicated SKU's StampBuy is M4's).
func TestM2SkuIsOneTenantNoSeats(t *testing.T) {
	api := &stripeAPI{}
	r := newRig(t, stripeCfg(t, api.server(t).URL))
	_, co := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "buyer@example.com"})
	id := co["checkout_id"].(string)
	allowed := map[string]bool{"amount": true, "currency": true, "metadata[order_id]": true, "automatic_payment_methods[enabled]": true}
	for k := range api.creates[0] {
		if !allowed[k] {
			t.Fatalf("M2 intent carries %q: the SKU must stay one tenant (no seat line items)", k)
		}
	}
	if api.creates[0].Get("amount") != "2000" {
		t.Fatalf("M2 intent amount %q, want the plan price", api.creates[0].Get("amount"))
	}
	if code, _ := r.stripeEvent(t, whsec, time.Now(), intentEvent("evt_m2", "payment_intent.succeeded", "pi_"+id)); code != 200 {
		t.Fatal(code)
	}
	ten, err := r.st.GetTenant(t.Context(), "acme")
	if err != nil || ten.SeatsUsers != 0 || ten.SeatsBots != 0 || ten.ProjectID != "" || !ten.BoughtAt.IsZero() {
		t.Fatalf("an M2 tenant must carry no seats and no dedicated-project stamp: %+v %v", ten, err)
	}
	for _, k := range []string{"seat", "quantity", "line_item"} {
		if strings.Contains(strings.ToLower(fmt.Sprint(co)), k) {
			t.Fatalf("the M2 checkout answer mentions %q", k)
		}
	}
}
