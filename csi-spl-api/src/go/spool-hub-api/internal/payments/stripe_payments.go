package payments

// Copied from csi-rel csi-rel-api/src/internal/orders/stripe_payments.go
// (tree e4612828; owner direction 2026-09-19: "payment exactly the way csi-rel
// implements it with Stripe"). Names adapted; NOT copied (006 payment.md "Do
// not copy"): Stripe Connect (ConnectedAccountID, Stripe-Account header,
// application fees, fee reversal, processing fee) and CardCountry/CardBIN
// (sanctions guard). Everything else is csi-rel's code.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// defaultStripeAPI is the live Stripe REST base URL.
// Override via StripePayments.BaseURL (tests / httptest, or
// SPOOL_HUB_STRIPE_API_BASE for a stripe-mock in lde).
const defaultStripeAPI = "https://api.stripe.com"

// DefaultStripeAPIVersion is the Stripe REST version the copied driver was
// written against (csi-rel config.DefaultStripeAPIVersion).
const DefaultStripeAPIVersion = "2024-06-20"

// StripePayments implements PaymentProvider against Stripe's REST API
// (PaymentIntents, Refunds). No stripe-go dependency — plain net/http keeps
// the surface small and unit-testable via httptest.
type StripePayments struct {
	SecretKey string
	// HTTPClient is optional; nil → http.Client with a 15s timeout.
	HTTPClient *http.Client
	// BaseURL is optional; empty → https://api.stripe.com.
	BaseURL string
	// APIVersion is the Stripe-Version header. Empty -> DefaultStripeAPIVersion.
	APIVersion string
}

// apiVersion is the Stripe-Version header value actually sent.
func (s *StripePayments) apiVersion() string {
	if v := strings.TrimSpace(s.APIVersion); v != "" {
		return v
	}
	return DefaultStripeAPIVersion
}

// NewStripePayments returns a Stripe-backed PaymentProvider.
func NewStripePayments(secretKey string) *StripePayments {
	return &StripePayments{SecretKey: secretKey}
}

func (s *StripePayments) client() *http.Client {
	if s.HTTPClient != nil {
		return s.HTTPClient
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (s *StripePayments) base() string {
	if s.BaseURL != "" {
		return strings.TrimRight(s.BaseURL, "/")
	}
	return defaultStripeAPI
}

// CreateIntent creates a Stripe PaymentIntent for the order total.
// currency is lower-cased for Stripe (e.g. "EUR" → "eur").
// Idempotency-Key is set to orderID so Stripe dedupes retries (008 defence-in-depth).
func (s *StripePayments) CreateIntent(ctx context.Context, orderID string, totalCents int, currency string) (intentID, clientSecret string, err error) {
	return s.CreateIntentWithMethods(ctx, orderID, totalCents, currency, nil)
}

// CreateIntentWithMethods is CreateIntent restricted to an explicit set of
// Stripe payment_method_types (csi-rel 050). Empty methodTypes keeps
// automatic_payment_methods (cards + the Apple Pay / Google Pay wallets).
func (s *StripePayments) CreateIntentWithMethods(ctx context.Context, orderID string, totalCents int, currency string, methodTypes []string) (intentID, clientSecret string, err error) {
	return s.createIntent(ctx, orderID, totalCents, currency, methodTypes, nil)
}

// CreateIntentWithItems is CreateIntent carrying the M4 line items (009
// T004): a PaymentIntent has no line items of its own, so each item goes into
// metadata[<name>_qty] / metadata[<name>_unit_cents] and one readable
// description, which the dashboard and the receipt show. No items = exactly
// CreateIntent (the M2 SKU, 009 T001).
func (s *StripePayments) CreateIntentWithItems(ctx context.Context, orderID string, totalCents int, currency string, items []LineItem) (intentID, clientSecret string, err error) {
	return s.createIntent(ctx, orderID, totalCents, currency, nil, items)
}

func (s *StripePayments) createIntent(ctx context.Context, orderID string, totalCents int, currency string, methodTypes []string, items []LineItem) (intentID, clientSecret string, err error) {
	form := url.Values{}
	form.Set("amount", fmt.Sprintf("%d", totalCents))
	form.Set("currency", strings.ToLower(strings.TrimSpace(currency)))
	form.Set("metadata[order_id]", orderID)
	if len(items) > 0 {
		desc := make([]string, 0, len(items))
		for _, it := range items {
			form.Set("metadata["+it.Name+"_qty]", fmt.Sprintf("%d", it.Quantity))
			form.Set("metadata["+it.Name+"_unit_cents]", fmt.Sprintf("%d", it.UnitCents))
			desc = append(desc, fmt.Sprintf("%d x %s", it.Quantity, it.Name))
		}
		form.Set("description", "spool hub: "+strings.Join(desc, ", ")+" (monthly)")
	}
	if len(methodTypes) == 0 {
		// automatic_payment_methods lets Elements / Payment Element confirm later.
		form.Set("automatic_payment_methods[enabled]", "true")
	} else {
		for i, m := range methodTypes {
			form.Set(fmt.Sprintf("payment_method_types[%d]", i), strings.ToLower(strings.TrimSpace(m)))
		}
	}

	body, status, err := s.doForm(ctx, http.MethodPost, "/v1/payment_intents", form, orderID)
	if err != nil {
		return "", "", err
	}
	if status < 200 || status >= 300 {
		return "", "", fmt.Errorf("stripe payment_intents create: status %d: %s", status, truncateStripeErr(body))
	}

	var resp struct {
		ID           string `json:"id"`
		ClientSecret string `json:"client_secret"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return "", "", fmt.Errorf("stripe payment_intents decode: %w", err)
	}
	if resp.ID == "" || resp.ClientSecret == "" {
		return "", "", fmt.Errorf("stripe payment_intents create: missing id/client_secret")
	}
	return resp.ID, resp.ClientSecret, nil
}

// CancelIntent cancels a Stripe PaymentIntent so a late payment can no longer
// be confirmed. Cancelling a PaymentIntent that is already succeeded or
// cancelled is benign: Stripe answers 400 with error.code
// "payment_intent_unexpected_state", which is swallowed.
func (s *StripePayments) CancelIntent(ctx context.Context, intentID string) error {
	id := strings.TrimSpace(intentID)
	if id == "" {
		return fmt.Errorf("stripe payment_intents cancel: empty id")
	}
	path := "/v1/payment_intents/" + url.PathEscape(id) + "/cancel"
	body, status, err := s.doForm(ctx, http.MethodPost, path, url.Values{}, "")
	if err != nil {
		return err
	}
	if status >= 200 && status < 300 {
		return nil
	}
	if stripeErrorCode(body) == "payment_intent_unexpected_state" {
		// Already succeeded / cancelled — nothing left to cancel. Benign.
		return nil
	}
	return fmt.Errorf("stripe payment_intents cancel: status %d: %s", status, truncateStripeErr(body))
}

// Refund creates a Stripe Refund against the given PaymentIntent without an
// Idempotency-Key. Kept for the PaymentProvider contract; an operator refund
// goes through RefundWithKey.
func (s *StripePayments) Refund(ctx context.Context, intentID string, amountCents int) error {
	_, err := s.RefundWithKey(ctx, intentID, amountCents, "")
	return err
}

// RefundWithKey creates a Stripe Refund and forwards idempotencyKey as
// Stripe's Idempotency-Key: a retry after a timeout that Stripe had already
// accepted returns the first refund instead of creating a second one.
func (s *StripePayments) RefundWithKey(ctx context.Context, intentID string, amountCents int, idempotencyKey string) (string, error) {
	form := url.Values{}
	form.Set("payment_intent", intentID)
	form.Set("amount", fmt.Sprintf("%d", amountCents))

	body, status, err := s.doForm(ctx, http.MethodPost, "/v1/refunds", form, strings.TrimSpace(idempotencyKey))
	if err != nil {
		return "", err
	}
	if status < 200 || status >= 300 {
		return "", fmt.Errorf("stripe refunds create: status %d: %s", status, truncateStripeErr(body))
	}
	var resp struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return "", fmt.Errorf("stripe refunds decode: %w", err)
	}
	return resp.ID, nil
}

// stripeIdempotencyKeyMax is Stripe's documented Idempotency-Key length cap.
const stripeIdempotencyKeyMax = 255

// doForm performs a Stripe API call with form body (or GET with no body).
// idempotencyKey, when non-empty, is sent as Idempotency-Key.
func (s *StripePayments) doForm(ctx context.Context, method, path string, form url.Values, idempotencyKey string) ([]byte, int, error) {
	if strings.TrimSpace(s.SecretKey) == "" {
		return nil, 0, fmt.Errorf("stripe: secret key is empty")
	}
	if len(idempotencyKey) > stripeIdempotencyKeyMax {
		return nil, 0, fmt.Errorf("stripe: idempotency key longer than %d", stripeIdempotencyKeyMax)
	}

	var bodyReader io.Reader
	if form != nil && method != http.MethodGet {
		bodyReader = strings.NewReader(form.Encode())
	}
	req, err := http.NewRequestWithContext(ctx, method, s.base()+path, bodyReader)
	if err != nil {
		return nil, 0, fmt.Errorf("stripe request build: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+s.SecretKey)
	req.Header.Set("Stripe-Version", s.apiVersion())
	if bodyReader != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}

	resp, err := s.client().Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("stripe http: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("stripe read body: %w", err)
	}
	return raw, resp.StatusCode, nil
}

// stripeErrorCode extracts error.code from a Stripe error envelope, or "".
func stripeErrorCode(body []byte) string {
	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &envelope) != nil {
		return ""
	}
	return envelope.Error.Code
}

func truncateStripeErr(body []byte) string {
	const max = 256
	// Prefer Stripe's error.message when present.
	var envelope struct {
		Error struct {
			Message string `json:"message"`
			Type    string `json:"type"`
			Code    string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &envelope) == nil && envelope.Error.Message != "" {
		msg := envelope.Error.Message
		if envelope.Error.Code != "" {
			msg = envelope.Error.Code + ": " + msg
		}
		if len(msg) > max {
			return msg[:max] + "…"
		}
		return msg
	}
	s := string(body)
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}

// stripeKeyPrefixes are the secret / restricted key shapes (csi-rel config).
var stripeKeyPrefixes = []string{"sk_test_", "sk_live_", "rk_test_", "rk_live_"}

// StripeKeyProblem returns "" when k has a Stripe secret/restricted-key shape,
// "unset", "placeholder" or "malformed" otherwise. Shape only: it never calls
// Stripe and never reveals the value (csi-rel F-17).
func StripeKeyProblem(k string) string {
	k = strings.TrimSpace(k)
	if k == "" {
		return "unset"
	}
	for _, p := range stripeKeyPrefixes {
		if strings.HasPrefix(k, p) && len(k) > len(p) {
			return ""
		}
	}
	if LooksLikePlaceholderSecret(k) {
		return "placeholder"
	}
	return "malformed"
}

// StripeKeyMode reports "test" / "live" for a well-shaped key, "" otherwise.
func StripeKeyMode(k string) string {
	k = strings.TrimSpace(k)
	switch {
	case strings.HasPrefix(k, "sk_test_"), strings.HasPrefix(k, "rk_test_"):
		return "test"
	case strings.HasPrefix(k, "sk_live_"), strings.HasPrefix(k, "rk_live_"):
		return "live"
	}
	return ""
}
