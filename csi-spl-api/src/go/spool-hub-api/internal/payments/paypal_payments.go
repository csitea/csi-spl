package payments

// Copied from csi-rel csi-rel-api/src/internal/payments/paypal_payments.go
// (tree e4612828; owner direction 2026-09-19). OFF by default
// (SPOOL_HUB_ENABLE_PAYPAL) and NOT live-tested: csi-rel's PayPal was never
// properly tested either. Names adapted; not copied: CardCountry / CardBIN /
// SupportedMethods (sanctions + method catalogue, 006 payment.md "Do not copy").

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// PayPal REST hosts. Selected by Mode; BaseURL overrides both (tests / mock).
const (
	paypalLiveAPI    = "https://api-m.paypal.com"
	paypalSandboxAPI = "https://api-m.sandbox.paypal.com"
)

// ModeLive is the only Mode value that selects the live PayPal host. Anything
// else (including the empty string) stays on sandbox — fail safe: a
// misconfigured env must never move real money.
const ModeLive = "live"

// PayPal implements the order-side payment contract against PayPal Orders v2.
//
// Lifecycle of a PayPal order in this codebase:
//
//	checkout            → CreateProviderOrder  (POST /v2/checkout/orders, intent=CAPTURE)
//	buyer approves      → PayPal JS SDK popup, no server call
//	WUI onApprove       → CaptureProviderOrder (POST /v2/checkout/orders/{id}/capture)
//	PayPal webhook      → PAYMENT.CAPTURE.COMPLETED flips the order to paid
//	admin refund        → Refund               (POST /v2/payments/captures/{id}/refund)
//
// The webhook — not the capture response — is what marks an order paid, exactly
// as on the Stripe path, so both providers share one authoritative transition.
type PayPal struct {
	ClientID     string
	ClientSecret string
	// Mode selects the host: ModeLive → live, anything else → sandbox.
	Mode string
	// BaseURL overrides the Mode-derived host (httptest / local mock).
	BaseURL string
	// HTTPClient is optional; nil → http.Client with a 15s timeout.
	HTTPClient *http.Client
	// Currency is the ISO-4217 code used for partial refunds, where PayPal
	// demands an explicit amount object. Empty → EUR (the store's only
	// currency; orders.currency is written as 'EUR' at checkout).
	Currency string
	// BrandName is shown on the PayPal approval page. Empty → PayPal shows the
	// account's own business name. Never bake a customer brand into source.
	BrandName string
	// Now is injectable for token-expiry tests; nil → time.Now.
	Now func() time.Time

	mu          sync.Mutex
	token       string
	tokenExpiry time.Time
}

// NewPayPal returns a PayPal driver (csi-rel payments.New). clientID/clientSecret must be non-empty —
// main only constructs one when both are configured.
func NewPayPal(clientID, clientSecret, mode string) *PayPal {
	return &PayPal{ClientID: clientID, ClientSecret: clientSecret, Mode: mode}
}

func (p *PayPal) client() *http.Client {
	if p.HTTPClient != nil {
		return p.HTTPClient
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (p *PayPal) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}

func (p *PayPal) base() string {
	if p.BaseURL != "" {
		return strings.TrimRight(p.BaseURL, "/")
	}
	if strings.EqualFold(strings.TrimSpace(p.Mode), ModeLive) {
		return paypalLiveAPI
	}
	return paypalSandboxAPI
}

func (p *PayPal) currency() string {
	if c := strings.ToUpper(strings.TrimSpace(p.Currency)); c != "" {
		return c
	}
	return "EUR"
}

// ----------------------------------------------------------------------------
// OAuth2 client-credentials token (cached until shortly before expiry)
// ----------------------------------------------------------------------------

// tokenSkew renews the access token this long before PayPal's stated expiry so
// an in-flight call can never race the expiry boundary.
const tokenSkew = 60 * time.Second

// accessToken returns an OAuth2 client-credentials bearer token for the
// PayPal REST API. It refuses at once, without any network call, when
// ClientID or ClientSecret is empty. A token is cached and reused until
// tokenSkew before PayPal's stated expires_in, then fetched afresh from
// /v1/oauth2/token. The lock is not held across the fetch, so concurrent
// callers on an expired cache may each fetch; the last one to finish is cached.
func (p *PayPal) accessToken(ctx context.Context) (string, error) {
	if strings.TrimSpace(p.ClientID) == "" || strings.TrimSpace(p.ClientSecret) == "" {
		return "", fmt.Errorf("paypal: client credentials are empty")
	}

	if tok, ok := p.cachedToken(); ok {
		return tok, nil
	}

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		p.base()+"/v1/oauth2/token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", fmt.Errorf("paypal token request build: %w", err)
	}
	req.SetBasicAuth(p.ClientID, p.ClientSecret)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := p.client().Do(req)
	if err != nil {
		return "", fmt.Errorf("paypal token http: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("paypal token read: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("paypal token: status %d: %s", resp.StatusCode, truncatePayPalErr(raw))
	}

	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", fmt.Errorf("paypal token decode: %w", err)
	}
	if out.AccessToken == "" {
		return "", fmt.Errorf("paypal token: empty access_token")
	}

	ttl := time.Duration(out.ExpiresIn) * time.Second
	if ttl > tokenSkew {
		ttl -= tokenSkew
	} else {
		ttl = 0
	}
	p.mu.Lock()
	p.token = out.AccessToken
	p.tokenExpiry = p.now().Add(ttl)
	p.mu.Unlock()
	return out.AccessToken, nil
}

// cachedToken returns the cached access token while it is still before its
// (skew-adjusted) expiry; ok=false means the caller must fetch a new one.
func (p *PayPal) cachedToken() (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.token != "" && p.now().Before(p.tokenExpiry) {
		return p.token, true
	}
	return "", false
}

// ----------------------------------------------------------------------------
// Orders v2
// ----------------------------------------------------------------------------

// CreateProviderOrder creates a CAPTURE-intent PayPal order for the given store
// order and returns (providerOrderID, approveURL). approveURL is the buyer's
// approval link (rel="approve"); the WUI's PayPal JS SDK usually opens its own
// popup from the order id, so the link is persisted/returned as the redirect
// fallback for browsers where the SDK cannot open a popup.
//
// storeOrderID is sent as both reference_id and custom_id so a PayPal-side
// dashboard row can be traced back to our order without a lookup table, and is
// used as PayPal-Request-Id so a retried checkout does not create a second
// PayPal order.
func (p *PayPal) CreateProviderOrder(ctx context.Context, storeOrderID string, totalCents int, currency string) (string, string, error) {
	cur := strings.ToUpper(strings.TrimSpace(currency))
	if cur == "" {
		cur = p.currency()
	}
	body := map[string]interface{}{
		"intent": "CAPTURE",
		"purchase_units": []map[string]interface{}{{
			"reference_id": storeOrderID,
			"custom_id":    storeOrderID,
			"amount": map[string]string{
				"currency_code": cur,
				"value":         FormatAmount(totalCents),
			},
		}},
	}
	if bn := strings.TrimSpace(p.BrandName); bn != "" {
		body["payment_source"] = map[string]interface{}{
			"paypal": map[string]interface{}{
				"experience_context": map[string]string{
					"brand_name":          bn,
					"user_action":         "PAY_NOW",
					"shipping_preference": "SET_PROVIDED_ADDRESS",
				},
			},
		}
	}

	raw, status, err := p.do(ctx, http.MethodPost, "/v2/checkout/orders", body, storeOrderID)
	if err != nil {
		return "", "", err
	}
	if status < 200 || status >= 300 {
		return "", "", fmt.Errorf("paypal orders create: status %d: %s", status, truncatePayPalErr(raw))
	}

	var out struct {
		ID     string `json:"id"`
		Status string `json:"status"`
		Links  []struct {
			Href string `json:"href"`
			Rel  string `json:"rel"`
		} `json:"links"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", "", fmt.Errorf("paypal orders decode: %w", err)
	}
	if out.ID == "" {
		return "", "", fmt.Errorf("paypal orders create: missing id")
	}
	var approve string
	for _, l := range out.Links {
		if strings.EqualFold(l.Rel, "approve") || strings.EqualFold(l.Rel, "payer-action") {
			approve = l.Href
			break
		}
	}
	return out.ID, approve, nil
}

// CaptureProviderOrder captures an approved PayPal order and returns
// (captureID, payerID).
//
// requestID is sent as PayPal-Request-Id: PayPal replays the original result
// for a repeated id instead of double-charging, which is what makes a retried
// WUI onApprove safe. Pass the store order id.
//
// A capture PayPal has already completed answers 422
// ORDER_ALREADY_CAPTURED; that is reported as ErrAlreadyCaptured so the caller
// can treat the retry as success rather than a payment failure.
func (p *PayPal) CaptureProviderOrder(ctx context.Context, providerOrderID, requestID string) (string, string, error) {
	id := strings.TrimSpace(providerOrderID)
	if id == "" {
		return "", "", fmt.Errorf("paypal capture: empty order id")
	}
	path := "/v2/checkout/orders/" + url.PathEscape(id) + "/capture"
	raw, status, err := p.do(ctx, http.MethodPost, path, map[string]interface{}{}, requestID)
	if err != nil {
		return "", "", err
	}
	if status < 200 || status >= 300 {
		if payPalIssue(raw) == issueAlreadyCaptured {
			return "", "", ErrAlreadyCaptured
		}
		return "", "", fmt.Errorf("paypal capture: status %d: %s", status, truncatePayPalErr(raw))
	}

	var out struct {
		ID    string `json:"id"`
		Payer struct {
			PayerID string `json:"payer_id"`
		} `json:"payer"`
		PurchaseUnits []struct {
			Payments struct {
				Captures []struct {
					ID     string `json:"id"`
					Status string `json:"status"`
				} `json:"captures"`
			} `json:"payments"`
		} `json:"purchase_units"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", "", fmt.Errorf("paypal capture decode: %w", err)
	}
	captureID := ""
	for _, pu := range out.PurchaseUnits {
		for _, cap := range pu.Payments.Captures {
			if cap.ID != "" {
				captureID = cap.ID
				break
			}
		}
		if captureID != "" {
			break
		}
	}
	if captureID == "" {
		return "", "", fmt.Errorf("paypal capture: no capture id in response")
	}
	return captureID, out.Payer.PayerID, nil
}

// ErrAlreadyCaptured means PayPal reports the order as captured already — the
// money moved on an earlier attempt. Callers treat it as success (idempotent
// capture), never as a decline.
//
// It carries an AlreadyCaptured() method so a caller can recognise it through
// errors.As without importing this package — the orders package stays free of
// a dependency on any concrete provider driver.
var ErrAlreadyCaptured error = alreadyCapturedError{}

type alreadyCapturedError struct{}

func (alreadyCapturedError) Error() string         { return "paypal: order already captured" }
func (alreadyCapturedError) AlreadyCaptured() bool { return true }

const issueAlreadyCaptured = "ORDER_ALREADY_CAPTURED"

// ----------------------------------------------------------------------------
// PaymentProvider contract
// ----------------------------------------------------------------------------

// CreateIntent satisfies orders.PaymentProvider. For PayPal the "intent id" is
// the Orders v2 order id and the "client secret" slot carries the buyer approve
// URL — PayPal has no client secret. Checkout stores the id in
// orders.provider_order_id (not payment_intent_id, which holds the capture id
// once the money actually moves).
func (p *PayPal) CreateIntent(ctx context.Context, orderID string, totalCents int, currency string) (string, string, error) {
	return p.CreateProviderOrder(ctx, orderID, totalCents, currency)
}

// Refund refunds a PayPal capture. captureID is orders.payment_intent_id for a
// PayPal-paid order (written by the capture handler). amountCents <= 0 asks for
// a full refund (PayPal's empty-body form).
func (p *PayPal) Refund(ctx context.Context, captureID string, amountCents int) error {
	id := strings.TrimSpace(captureID)
	if id == "" {
		return fmt.Errorf("paypal refund: empty capture id")
	}
	body := map[string]interface{}{}
	if amountCents > 0 {
		body["amount"] = map[string]string{
			"currency_code": p.currency(),
			"value":         FormatAmount(amountCents),
		}
	}
	path := "/v2/payments/captures/" + url.PathEscape(id) + "/refund"
	raw, status, err := p.do(ctx, http.MethodPost, path, body, "")
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("paypal refund: status %d: %s", status, truncatePayPalErr(raw))
	}
	return nil
}

// CancelIntent satisfies the janitor's PaymentCanceller contract. PayPal
// Orders v2 has NO cancel endpoint — an unapproved order simply expires on
// PayPal's side. The "no late payment" guarantee for PayPal is therefore
// enforced where it can be: the capture handler refuses to capture once the
// store order is no longer pending or its stock reservations have expired.
// Always benign so the 60s janitor sweep never spins on a PayPal order.
func (p *PayPal) CancelIntent(_ context.Context, _ string) error { return nil }

// ----------------------------------------------------------------------------
// helpers
// ----------------------------------------------------------------------------

// FormatAmount renders integer cents as PayPal's decimal string ("1234" →
// "12.34"). PayPal rejects amounts that do not carry exactly the currency's
// decimal places for EUR/USD-shaped currencies.
func FormatAmount(cents int) string {
	neg := cents < 0
	if neg {
		cents = -cents
	}
	s := fmt.Sprintf("%d.%02d", cents/100, cents%100)
	if neg {
		return "-" + s
	}
	return s
}

// do performs an authenticated Orders v2 call with a JSON body.
// requestID, when non-empty, is sent as PayPal-Request-Id (PayPal's
// idempotency header).
func (p *PayPal) do(ctx context.Context, method, path string, body interface{}, requestID string) ([]byte, int, error) {
	tok, err := p.accessToken(ctx)
	if err != nil {
		return nil, 0, err
	}
	var buf io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, 0, fmt.Errorf("paypal body encode: %w", err)
		}
		buf = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, p.base()+path, buf)
	if err != nil {
		return nil, 0, fmt.Errorf("paypal request build: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/json")
	if buf != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if strings.TrimSpace(requestID) != "" {
		req.Header.Set("PayPal-Request-Id", requestID)
	}

	resp, err := p.client().Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("paypal http: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("paypal read body: %w", err)
	}
	return raw, resp.StatusCode, nil
}

// paypalErr is the shape of a PayPal REST error envelope.
type paypalErr struct {
	Name    string `json:"name"`
	Message string `json:"message"`
	Details []struct {
		Issue       string `json:"issue"`
		Description string `json:"description"`
	} `json:"details"`
}

// payPalIssue returns the first details[].issue code, or "".
func payPalIssue(raw []byte) string {
	var e paypalErr
	if json.Unmarshal(raw, &e) != nil {
		return ""
	}
	for _, d := range e.Details {
		if d.Issue != "" {
			return d.Issue
		}
	}
	return ""
}

// truncatePayPalErr renders a PayPal error envelope as a short, log-safe line.
func truncatePayPalErr(raw []byte) string {
	const max = 256
	var e paypalErr
	if json.Unmarshal(raw, &e) == nil && (e.Name != "" || e.Message != "") {
		msg := strings.TrimSpace(e.Name + ": " + e.Message)
		if iss := payPalIssue(raw); iss != "" {
			msg += " (" + iss + ")"
		}
		if len(msg) > max {
			return msg[:max] + "…"
		}
		return msg
	}
	s := string(raw)
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}
