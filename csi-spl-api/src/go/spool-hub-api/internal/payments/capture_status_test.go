package payments

import (
	"bytes"
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Table cases for the refusals of GET /checkout/{id} (status) and POST
// /checkout/paypal/capture (paypalCapture): each answer's status and error
// token, and whether the wallet capture was asked. No network, no real key:
// the store and the PayPal rail are wrapped like flakyStore / recordingCard.

// cannedStore answers GetCheckout with a fixed row or error.
type cannedStore struct {
	*store.Memory
	row store.Checkout
	err error
}

func (s *cannedStore) GetCheckout(context.Context, string) (store.Checkout, error) {
	return s.row, s.err
}

// recordingWallet records each capture and answers it with captureErr.
type recordingWallet struct {
	PayPalRail
	captureErr error
	captures   []string
}

func (p *recordingWallet) CaptureProviderOrder(_ context.Context, orderID, _ string) (string, string, error) {
	p.captures = append(p.captures, orderID)
	return "CAP-1", "PAYER-1", p.captureErr
}

func paypalCfg(t *testing.T) *Config {
	return mustLoad(t, "lde", map[string]string{"SPOOL_HUB_ENABLE_PAYPAL": "true", "SPOOL_HUB_PAYPAL_CLIENT_ID": "cid-1",
		"SPOOL_HUB_PAYPAL_CLIENT_SECRET": "csec-1", "SPOOL_HUB_PAYPAL_WEBHOOK_ID": "wh-1", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"})
}

func cannedHandler(t *testing.T, st *cannedStore, wallet *recordingWallet) *Handler {
	t.Helper()
	cfg := paypalCfg(t)
	card, pp, ppv := Wire(cfg)
	wallet.PayPalRail = pp
	st.Memory = store.NewMemory()
	h, err := New(cfg, Deps{Store: st, Log: zerolog.New(&bytes.Buffer{}), Mail: &mail.Recorder{}, MailDelivers: true,
		TenantHostPattern: pattern, Card: card, PayPal: wallet, PayPalVerifier: ppv})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func TestCheckoutStatusCases(t *testing.T) {
	cases := []struct {
		name     string
		st       cannedStore
		code     int
		token    string
		hostSeen bool
	}{
		{"not found", cannedStore{err: store.ErrNotFound}, 404, `"error":"not_found"`, false},
		{"lookup fails", cannedStore{err: errors.New("db down")}, 500, `"error":"internal"`, false},
		{"pending", cannedStore{row: store.Checkout{ID: "co-1", TenantID: "acme", Status: store.CheckoutPending}}, 200, `"status":"pending"`, false},
		{"paid", cannedStore{row: store.Checkout{ID: "co-1", TenantID: "acme", Status: store.CheckoutPaid}}, 200, `"status":"paid"`, true},
	}
	for _, c := range cases {
		st := c.st
		h := cannedHandler(t, &st, &recordingWallet{})
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/checkout/co-1", nil))
		body := w.Body.String()
		if w.Code != c.code || !strings.Contains(body, c.token) || strings.Contains(body, `"host_status"`) != c.hostSeen {
			t.Errorf("%s: %d %s, want %d %s host_status=%v", c.name, w.Code, body, c.code, c.token, c.hostSeen)
		}
	}
}

func TestPayPalCaptureCases(t *testing.T) {
	pending := store.Checkout{ID: "co-1", Provider: ProviderPayPal, ProviderRef: "ORDER-co-1", Status: store.CheckoutPending}
	with := func(c store.Checkout, f func(*store.Checkout)) store.Checkout { f(&c); return c }
	good := `{"checkout_id":" co-1 "}`
	cases := []struct {
		name       string
		body       string
		st         cannedStore
		captureErr error
		code       int
		token      string
		captured   bool
	}{
		{"not json", `{`, cannedStore{row: pending}, nil, 400, `"error":"bad_request"`, false},
		{"not found", good, cannedStore{err: store.ErrNotFound}, nil, 404, `"error":"not_found"`, false},
		{"card checkout", good, cannedStore{row: with(pending, func(c *store.Checkout) { c.Provider = ProviderStripe })}, nil, 404, `"error":"not_found"`, false},
		{"lookup fails", good, cannedStore{err: errors.New("db down")}, nil, 500, `"error":"internal"`, false},
		{"failed checkout", good, cannedStore{row: with(pending, func(c *store.Checkout) { c.Status = store.CheckoutFailed })}, nil, 409, `"error":"not_pending"`, false},
		{"already paid", good, cannedStore{row: with(pending, func(c *store.Checkout) { c.Status = store.CheckoutPaid })}, nil, 202, `"status":"capturing"`, false},
		{"capture fails", good, cannedStore{row: pending}, errors.New("paypal 500"), 502, `"error":"payment_failed"`, true},
		{"already captured", good, cannedStore{row: pending}, ErrAlreadyCaptured, 202, `"status":"capturing"`, true},
		{"captured", good, cannedStore{row: pending}, nil, 202, `"status":"capturing"`, true},
	}
	for _, c := range cases {
		st := c.st
		wallet := &recordingWallet{captureErr: c.captureErr}
		h := cannedHandler(t, &st, wallet)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("POST", "/api/v1/checkout/paypal/capture", strings.NewReader(c.body)))
		if w.Code != c.code || !strings.Contains(w.Body.String(), c.token) {
			t.Errorf("%s: %d %s, want %d %s", c.name, w.Code, w.Body.String(), c.code, c.token)
		}
		if (len(wallet.captures) == 1) != c.captured || (c.captured && wallet.captures[0] != "ORDER-co-1") {
			t.Errorf("%s: captures %q, want a capture: %v", c.name, wallet.captures, c.captured)
		}
	}
}
