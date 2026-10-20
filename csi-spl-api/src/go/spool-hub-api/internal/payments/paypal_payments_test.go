package payments

// Unit tests for the PayPal driver's provider contract and error helpers
// (refactor round 14 row 06). Every call goes to an httptest server; the
// client id and secret are dummy strings, never a real credential.

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// ppCall is one request the fake PayPal API received after the token call.
type ppCall struct {
	method, path, requestID, auth string
	body                          map[string]any
}

// ppFake answers /v1/oauth2/token with a fixed token, and every other path
// with the status and body set for it (200 + "{}" when unset).
type ppFake struct {
	mu        sync.Mutex
	calls     []ppCall
	tokenCode int
	status    map[string]int
	reply     map[string]string
}

func newPPFake(t *testing.T) (*ppFake, *PayPal) {
	t.Helper()
	f := &ppFake{status: map[string]int{}, reply: map[string]string{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.URL.Path == "/v1/oauth2/token" {
			if f.tokenCode != 0 {
				w.WriteHeader(f.tokenCode)
				_, _ = w.Write([]byte(`{"name":"AUTHENTICATION_FAILURE","message":"bad client"}`))
				return
			}
			_, _ = w.Write([]byte(`{"access_token":"tok-1","expires_in":3600}`))
			return
		}
		raw, _ := io.ReadAll(r.Body)
		c := ppCall{method: r.Method, path: r.URL.Path, requestID: r.Header.Get("PayPal-Request-Id"), auth: r.Header.Get("Authorization")}
		if len(raw) > 0 {
			_ = json.Unmarshal(raw, &c.body)
		}
		f.calls = append(f.calls, c)
		if code := f.status[r.URL.Path]; code != 0 {
			w.WriteHeader(code)
		}
		if b, ok := f.reply[r.URL.Path]; ok {
			_, _ = w.Write([]byte(b))
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	t.Cleanup(srv.Close)
	p := NewPayPal("cid-test", "secret-test", "")
	p.BaseURL = srv.URL + "/"
	return f, p
}

func (f *ppFake) last(t *testing.T) ppCall {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.calls) == 0 {
		t.Fatal("no call reached the fake PayPal API")
	}
	return f.calls[len(f.calls)-1]
}

func (f *ppFake) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

const ppErr422 = `{"name":"UNPROCESSABLE_ENTITY","message":"The requested action could not be performed.","details":[{"issue":"CAPTURE_FULLY_REFUNDED","description":"already refunded"}]}`

func TestPayPalAlreadyCapturedError(t *testing.T) {
	if got := ErrAlreadyCaptured.Error(); got != "paypal: order already captured" {
		t.Fatalf("Error() = %q", got)
	}
	var ac interface{ AlreadyCaptured() bool }
	if !errors.As(ErrAlreadyCaptured, &ac) || !ac.AlreadyCaptured() {
		t.Fatal("ErrAlreadyCaptured is not recognisable through errors.As")
	}
}

func TestPayPalCaptureErrors(t *testing.T) {
	path := "/v2/checkout/orders/ORDER-1/capture"
	cases := []struct {
		name, reply, want string
		already           bool
	}{
		{"already captured is success", `{"name":"UNPROCESSABLE_ENTITY","message":"x","details":[{"issue":"ORDER_ALREADY_CAPTURED"}]}`, "", true},
		{"other issue is an error", ppErr422, "paypal capture: status 422: UNPROCESSABLE_ENTITY: The requested action could not be performed. (CAPTURE_FULLY_REFUNDED)", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, p := newPPFake(t)
			f.status[path], f.reply[path] = 422, tc.reply
			_, _, err := p.CaptureProviderOrder(context.Background(), "ORDER-1", "req-1")
			if tc.already {
				if !errors.Is(err, ErrAlreadyCaptured) {
					t.Fatalf("err = %v, want ErrAlreadyCaptured", err)
				}
				return
			}
			if err == nil || err.Error() != tc.want {
				t.Fatalf("err = %v, want %q", err, tc.want)
			}
		})
	}
}

func TestPayPalCreateIntent(t *testing.T) {
	cases := []struct {
		name, currency, driverCurrency, brand, wantCurrency, approveRel string
	}{
		{"defaults to EUR, approve link", "", "", "", "EUR", "approve"},
		{"driver currency, payer-action link", "", " usd ", "", "USD", "payer-action"},
		{"call currency wins, brand sent", "sek", "usd", "Example Shop", "SEK", "approve"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, p := newPPFake(t)
			p.Currency, p.BrandName = tc.driverCurrency, tc.brand
			f.reply["/v2/checkout/orders"] = `{"id":"ORDER-9","links":[{"rel":"self","href":"https://pp.example.test/self"},{"rel":"` + tc.approveRel + `","href":"https://pp.example.test/approve"}]}`
			id, approve, err := p.CreateIntent(context.Background(), "co-1", 1234, tc.currency)
			if err != nil || id != "ORDER-9" || approve != "https://pp.example.test/approve" {
				t.Fatalf("CreateIntent = %q %q %v", id, approve, err)
			}
			c := f.last(t)
			if c.method != http.MethodPost || c.requestID != "co-1" || c.auth != "Bearer tok-1" {
				t.Fatalf("request %+v", c)
			}
			pu := c.body["purchase_units"].([]any)[0].(map[string]any)
			amount := pu["amount"].(map[string]any)
			if amount["currency_code"] != tc.wantCurrency || amount["value"] != "12.34" || pu["custom_id"] != "co-1" {
				t.Fatalf("purchase unit %v", pu)
			}
			_, hasBrand := c.body["payment_source"]
			if hasBrand != (tc.brand != "") {
				t.Fatalf("payment_source present=%v for brand %q", hasBrand, tc.brand)
			}
		})
	}
}

func TestPayPalCreateIntentErrors(t *testing.T) {
	cases := []struct{ name, reply, want string }{
		{"missing id", `{"links":[]}`, "paypal orders create: missing id"},
		{"bad json", `not json`, "paypal orders decode:"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, p := newPPFake(t)
			f.reply["/v2/checkout/orders"] = tc.reply
			if _, _, err := p.CreateIntent(context.Background(), "co-1", 100, ""); err == nil || !strings.HasPrefix(err.Error(), tc.want) {
				t.Fatalf("err = %v, want prefix %q", err, tc.want)
			}
		})
	}
	f, p := newPPFake(t)
	f.status["/v2/checkout/orders"], f.reply["/v2/checkout/orders"] = 400, `{"name":"INVALID_REQUEST","message":"bad amount"}`
	if _, _, err := p.CreateIntent(context.Background(), "co-1", 100, ""); err == nil || err.Error() != "paypal orders create: status 400: INVALID_REQUEST: bad amount" {
		t.Fatalf("status error = %v", err)
	}
}

func TestPayPalRefund(t *testing.T) {
	cases := []struct {
		name, capture, currency string
		cents                   int
		wantPath                string
		wantAmount              map[string]any
	}{
		{"full refund sends no amount", "CAP-1", "", 0, "/v2/payments/captures/CAP-1/refund", nil},
		{"negative is a full refund", " CAP-2 ", "", -5, "/v2/payments/captures/CAP-2/refund", nil},
		{"partial refund in EUR", "CAP-3", "", 250, "/v2/payments/captures/CAP-3/refund", map[string]any{"currency_code": "EUR", "value": "2.50"}},
		{"partial refund in driver currency", "CAP-4", "usd", 1999, "/v2/payments/captures/CAP-4/refund", map[string]any{"currency_code": "USD", "value": "19.99"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f, p := newPPFake(t)
			p.Currency = tc.currency
			if err := p.Refund(context.Background(), tc.capture, tc.cents); err != nil {
				t.Fatalf("Refund: %v", err)
			}
			c := f.last(t)
			if c.method != http.MethodPost || c.path != tc.wantPath || c.requestID != "" || c.auth != "Bearer tok-1" {
				t.Fatalf("request %+v, want POST %s", c, tc.wantPath)
			}
			amount, has := c.body["amount"]
			if (tc.wantAmount == nil) == has {
				t.Fatalf("amount present=%v, want %v", has, tc.wantAmount)
			}
			if tc.wantAmount != nil {
				got := amount.(map[string]any)
				for k, v := range tc.wantAmount {
					if got[k] != v {
						t.Fatalf("amount %v, want %v", got, tc.wantAmount)
					}
				}
			}
		})
	}
}

func TestPayPalRefundErrors(t *testing.T) {
	f, p := newPPFake(t)
	if err := p.Refund(context.Background(), "  ", 100); err == nil || err.Error() != "paypal refund: empty capture id" {
		t.Fatalf("empty id: %v", err)
	}
	if f.count() != 0 {
		t.Fatal("an empty capture id still called PayPal")
	}
	path := "/v2/payments/captures/CAP-1/refund"
	f.status[path], f.reply[path] = 422, ppErr422
	want := "paypal refund: status 422: UNPROCESSABLE_ENTITY: The requested action could not be performed. (CAPTURE_FULLY_REFUNDED)"
	if err := p.Refund(context.Background(), "CAP-1", 0); err == nil || err.Error() != want {
		t.Fatalf("422: %v, want %q", err, want)
	}

	f2, p2 := newPPFake(t)
	f2.tokenCode = http.StatusUnauthorized
	if err := p2.Refund(context.Background(), "CAP-1", 0); err == nil || err.Error() != "paypal token: status 401: AUTHENTICATION_FAILURE: bad client" {
		t.Fatalf("token failure: %v", err)
	}
	if f2.count() != 0 {
		t.Fatal("a failed token still called the refund endpoint")
	}
}

func TestPayPalCancelIntentIsBenign(t *testing.T) {
	f, p := newPPFake(t)
	if err := p.CancelIntent(context.Background(), "ORDER-1"); err != nil {
		t.Fatalf("CancelIntent = %v", err)
	}
	if f.count() != 0 {
		t.Fatal("CancelIntent called PayPal; Orders v2 has no cancel endpoint")
	}
}

func TestPayPalBaseAndCurrency(t *testing.T) {
	cases := []struct{ mode, base, want string }{
		{"", "", paypalSandboxAPI},
		{"sandbox", "", paypalSandboxAPI},
		{" LIVE ", "", paypalLiveAPI},
		{"live", "http://mock.example.test//", "http://mock.example.test"},
	}
	for _, tc := range cases {
		if got := (&PayPal{Mode: tc.mode, BaseURL: tc.base}).base(); got != tc.want {
			t.Errorf("base(mode=%q, BaseURL=%q) = %q, want %q", tc.mode, tc.base, got, tc.want)
		}
	}
	if got := (&PayPal{}).currency(); got != "EUR" {
		t.Errorf("empty currency = %q, want EUR", got)
	}
	if got := FormatAmount(-1205); got != "-12.05" {
		t.Errorf("FormatAmount(-1205) = %q", got)
	}
}

func TestPayPalIssue(t *testing.T) {
	cases := []struct{ name, raw, want string }{
		{"first non-empty issue", `{"details":[{"issue":""},{"issue":"ORDER_ALREADY_CAPTURED"},{"issue":"LATER"}]}`, "ORDER_ALREADY_CAPTURED"},
		{"no details", `{"name":"INTERNAL_SERVER_ERROR"}`, ""},
		{"not json", `<html>502</html>`, ""},
		{"empty body", ``, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := payPalIssue([]byte(tc.raw)); got != tc.want {
				t.Fatalf("payPalIssue(%q) = %q, want %q", tc.raw, got, tc.want)
			}
		})
	}
}

func TestTruncatePayPalErr(t *testing.T) {
	long := strings.Repeat("a", 300)
	cases := []struct{ name, raw, want string }{
		{"envelope with issue", ppErr422, "UNPROCESSABLE_ENTITY: The requested action could not be performed. (CAPTURE_FULLY_REFUNDED)"},
		{"name only", `{"name":"INTERNAL_SERVER_ERROR"}`, "INTERNAL_SERVER_ERROR:"},
		{"message only", `{"message":"try later"}`, ": try later"},
		{"long envelope cut at 256 bytes", `{"name":"E","message":"` + long + `"}`, ("E: " + long)[:256] + "…"},
		{"short raw body kept", `upstream timeout`, "upstream timeout"},
		{"json without name or message kept raw", `{"details":[]}`, `{"details":[]}`},
		{"256-byte raw body kept whole", long[:256], long[:256]},
		{"300-byte raw body cut at 256 bytes", long, long[:256] + "…"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := truncatePayPalErr([]byte(tc.raw)); got != tc.want {
				t.Fatalf("truncatePayPalErr = %q (%d bytes), want %q (%d bytes)", got, len(got), tc.want, len(tc.want))
			}
		})
	}
}
