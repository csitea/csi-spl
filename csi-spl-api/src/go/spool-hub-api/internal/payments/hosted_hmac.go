package payments

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// HostedHMAC is the hosted-payment-page rail of csi-rel spec 069, named by its
// protocol: requests and callbacks are authenticated by an HMAC over the
// lower-cased `checkout-*` fields (alphabetical, "name:value\n") followed by
// the raw body. BaseURL is cnf; there is no default host.
type HostedHMAC struct {
	MerchantID  string
	Secret      string
	BaseURL     string
	SuccessURL  string // browser return (WUI success page)
	CancelURL   string // browser return on cancel
	CallbackURL string // server-to-server: /api/v1/webhooks/payment
	HTTPClient  *http.Client
	Now         func() time.Time
	Nonce       func() string
}

// Name is webhook_events_seen.provider and payment_checkouts.provider.
func (p *HostedHMAC) Name() string { return ProviderHostedHMAC }

func (p *HostedHMAC) client() *http.Client {
	if p.HTTPClient != nil {
		return p.HTTPClient
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (p *HostedHMAC) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now().UTC()
}

func (p *HostedHMAC) nonce() string {
	if p.Nonce != nil {
		return p.Nonce()
	}
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func (p *HostedHMAC) wired() error {
	if strings.TrimSpace(p.MerchantID) == "" || strings.TrimSpace(p.Secret) == "" || strings.TrimSpace(p.BaseURL) == "" {
		return fmt.Errorf("hosted-hmac: merchant id, secret or API base missing")
	}
	return nil
}

type hostedCreateReq struct {
	Stamp        string         `json:"stamp"`
	Reference    string         `json:"reference"`
	Amount       int            `json:"amount"`
	Currency     string         `json:"currency"`
	Language     string         `json:"language"`
	Items        []hostedItem   `json:"items"`
	Customer     hostedCustomer `json:"customer"`
	RedirectURLs hostedURLPair  `json:"redirectUrls"`
	CallbackURLs hostedURLPair  `json:"callbackUrls"`
}

type hostedItem struct {
	UnitPrice     int    `json:"unitPrice"`
	Units         int    `json:"units"`
	VATPercentage int    `json:"vatPercentage"`
	ProductCode   string `json:"productCode"`
	Description   string `json:"description"`
}

type hostedCustomer struct {
	Email string `json:"email"`
}

type hostedURLPair struct {
	Success string `json:"success"`
	Cancel  string `json:"cancel"`
}

type hostedCreateResp struct {
	TransactionID string `json:"transactionId"`
	Href          string `json:"href"`
}

// CreateRedirectOrder POSTs /payments with the checkout id as stamp and
// reference; returns (transactionId, hosted href).
func (p *HostedHMAC) CreateRedirectOrder(ctx context.Context, checkoutID, email, currency string, totalCents int) (string, string, error) {
	if err := p.wired(); err != nil {
		return "", "", err
	}
	if totalCents <= 0 {
		return "", "", fmt.Errorf("hosted-hmac: invalid amount")
	}
	body := hostedCreateReq{
		Stamp: checkoutID, Reference: checkoutID, Amount: totalCents,
		Currency: strings.ToUpper(strings.TrimSpace(currency)), Language: "EN",
		// VAT is 0 here: the plan price in cnf is what the buyer pays; tax
		// handling is a pricing decision for the owner (payment.md).
		Items: []hostedItem{{UnitPrice: totalCents, Units: 1, ProductCode: "tenant",
			Description: "spool hub tenant"}},
		Customer:     hostedCustomer{Email: strings.TrimSpace(email)},
		RedirectURLs: hostedURLPair{Success: p.SuccessURL, Cancel: p.CancelURL},
		CallbackURLs: hostedURLPair{Success: p.CallbackURL, Cancel: p.CallbackURL},
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return "", "", err
	}
	var out hostedCreateResp
	if err := p.do(ctx, http.MethodPost, "/payments", "", raw, &out); err != nil {
		return "", "", err
	}
	if strings.TrimSpace(out.TransactionID) == "" || strings.TrimSpace(out.Href) == "" {
		return "", "", fmt.Errorf("hosted-hmac: create payment missing transactionId/href")
	}
	return out.TransactionID, out.Href, nil
}

func (p *HostedHMAC) Refund(ctx context.Context, ref string, amountCents int) error {
	if err := p.wired(); err != nil {
		return err
	}
	if strings.TrimSpace(ref) == "" {
		return fmt.Errorf("hosted-hmac: empty transaction id")
	}
	raw := []byte("{}")
	if amountCents > 0 {
		raw, _ = json.Marshal(map[string]int{"amount": amountCents})
	}
	return p.do(ctx, http.MethodPost, "/payments/"+ref+"/refunds", ref, raw, nil)
}

func (p *HostedHMAC) CancelIntent(ctx context.Context, ref string) error {
	if p.wired() != nil || strings.TrimSpace(ref) == "" {
		return nil // unconfigured / nothing to cancel: benign
	}
	if err := p.do(ctx, http.MethodPost, "/payments/"+ref+"/cancel", ref, nil, nil); err != nil &&
		!strings.Contains(err.Error(), "hosted-hmac: http ") {
		return err
	}
	return nil // already terminal / unknown: benign
}

func (p *HostedHMAC) do(ctx context.Context, method, path, txnID string, body []byte, dest any) error {
	if body == nil {
		body = []byte{}
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(p.BaseURL, "/")+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	fields := map[string]string{
		"checkout-account":   strings.TrimSpace(p.MerchantID),
		"checkout-algorithm": "sha256",
		"checkout-method":    method,
		"checkout-nonce":     p.nonce(),
		"checkout-timestamp": p.now().UTC().Format(time.RFC3339Nano),
	}
	if txnID != "" {
		fields["checkout-transaction-id"] = txnID
	}
	for k, v := range fields {
		req.Header.Set(k, v)
	}
	req.Header.Set("signature", SignCheckoutHMAC(p.Secret, "sha256", fields, string(body)))
	if len(body) > 0 {
		req.Header.Set("Content-Type", "application/json; charset=utf-8")
	}
	resp, err := p.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg := strings.TrimSpace(string(raw))
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return fmt.Errorf("hosted-hmac: http %d %s", resp.StatusCode, msg)
	}
	if dest == nil || len(raw) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, dest); err != nil {
		return fmt.Errorf("hosted-hmac: decode: %w", err)
	}
	return nil
}

// VerifyWebhook authenticates a callback: `checkout-*` fields from headers
// (POST) or the query (GET redirect callback), signature from the
// `signature` header or query. The account must be ours.
func (p *HostedHMAC) VerifyWebhook(r *http.Request, body []byte) (Event, error) {
	if p.wired() != nil {
		return Event{}, ErrSigBad
	}
	fields := checkoutFields(r)
	sig := r.Header.Get("signature")
	if sig == "" {
		sig = r.URL.Query().Get("signature")
	}
	if !ValidCheckoutHMAC(p.Secret, fields["checkout-algorithm"], sig, fields, string(body)) {
		return Event{}, ErrSigBad
	}
	if !hmac.Equal([]byte(fields["checkout-account"]), []byte(strings.TrimSpace(p.MerchantID))) {
		return Event{}, ErrSigBad
	}
	txn := strings.TrimSpace(fields["checkout-transaction-id"])
	status := strings.ToLower(strings.TrimSpace(fields["checkout-status"]))
	stamp := strings.TrimSpace(fields["checkout-stamp"])
	if txn == "" || status == "" || stamp == "" {
		return Event{}, ErrSigBad
	}
	kind := store.PayEventIgnore
	switch status {
	case "ok":
		kind = store.PayEventPaid
	case "fail":
		kind = store.PayEventFailed
	case "refund", "refunded":
		kind = store.PayEventRefund
	}
	return Event{ID: txn + ":" + status + ":" + stamp, CheckoutID: stamp, Kind: kind}, nil
}

func checkoutFields(r *http.Request) map[string]string {
	out := map[string]string{}
	for k, v := range r.Header {
		if lk := strings.ToLower(k); strings.HasPrefix(lk, "checkout-") && len(v) > 0 {
			out[lk] = v[0]
		}
	}
	for k, v := range r.URL.Query() {
		lk := strings.ToLower(k)
		if _, ok := out[lk]; !ok && strings.HasPrefix(lk, "checkout-") && len(v) > 0 {
			out[lk] = v[0]
		}
	}
	return out
}

// checkoutPayload: lower-cased checkout-* fields, alphabetical, "k:v\n",
// then the raw body (csi-rel spec 069's HMAC payload).
func checkoutPayload(fields map[string]string, body string) string {
	keys := make([]string, 0, len(fields))
	lower := map[string]string{}
	for k, v := range fields {
		lk := strings.ToLower(strings.TrimSpace(k))
		if strings.HasPrefix(lk, "checkout-") {
			keys = append(keys, lk)
			lower[lk] = v
		}
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k + ":" + lower[k] + "\n")
	}
	b.WriteString(body)
	return b.String()
}

func macFor(algorithm, secret string) hash.Hash {
	if strings.EqualFold(strings.TrimSpace(algorithm), "sha512") {
		return hmac.New(sha512.New, []byte(secret))
	}
	return hmac.New(sha256.New, []byte(secret))
}

// SignCheckoutHMAC is the hex HMAC of checkoutPayload ("sha256" default, or "sha512").
func SignCheckoutHMAC(secret, algorithm string, fields map[string]string, body string) string {
	m := macFor(algorithm, secret)
	m.Write([]byte(checkoutPayload(fields, body)))
	return hex.EncodeToString(m.Sum(nil))
}

// ValidCheckoutHMAC fail-closes on an empty secret or signature.
func ValidCheckoutHMAC(secret, algorithm, signature string, fields map[string]string, body string) bool {
	if strings.TrimSpace(secret) == "" || strings.TrimSpace(signature) == "" {
		return false
	}
	want := SignCheckoutHMAC(secret, algorithm, fields, body)
	return hmac.Equal([]byte(strings.ToLower(strings.TrimSpace(signature))), []byte(want))
}
