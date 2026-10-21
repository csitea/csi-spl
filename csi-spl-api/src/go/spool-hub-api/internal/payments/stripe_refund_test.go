package payments

import (
	"context"
	"strings"
	"testing"
)

// The refund path moves money: RefundWithKey must send payment_intent and
// amount, forward the Idempotency-Key (a retried refund without it pays out
// twice), refuse an over-long key before any request, and name its failures.
func TestStripeRefundWithKey(t *testing.T) {
	longKey := strings.Repeat("k", stripeIdempotencyKeyMax+1)
	cases := []struct {
		name     string
		key      string
		status   int
		body     string
		wantID   string
		wantErr  string
		wantHits int
		wantIdem string
	}{
		{name: "success forwards the key", key: "refund-ord-1", wantID: "re_pi_1", wantHits: 1, wantIdem: "refund-ord-1"},
		{name: "key is trimmed", key: "  refund-ord-1 ", wantID: "re_pi_1", wantHits: 1, wantIdem: "refund-ord-1"},
		{name: "empty key sends no header", key: "", wantID: "re_pi_1", wantHits: 1, wantIdem: ""},
		{name: "key over 255 refused before any request", key: longKey, wantErr: "idempotency key longer than 255", wantHits: 0},
		{name: "non-2xx names the status", key: "k1", status: 402, body: `{"error":{"message":"charge already refunded"}}`,
			wantErr: "stripe refunds create: status 402: charge already refunded", wantHits: 1, wantIdem: "k1"},
		{name: "undecodable body", key: "k2", body: "not json", wantErr: "stripe refunds decode", wantHits: 1, wantIdem: "k2"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			api := &stripeAPI{refundStatus: tc.status, refundBody: tc.body}
			sp := &StripePayments{SecretKey: "sk_test_abc", BaseURL: api.server(t).URL}
			id, err := sp.RefundWithKey(context.Background(), "pi_1", 1500, tc.key)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("err = %v, want %q", err, tc.wantErr)
				}
			} else if err != nil || id != tc.wantID {
				t.Fatalf("id %q err %v, want %q", id, err, tc.wantID)
			}
			if len(api.refunds) != tc.wantHits {
				t.Fatalf("refund requests = %d, want %d", len(api.refunds), tc.wantHits)
			}
			if tc.wantHits == 0 {
				return
			}
			if f := api.refunds[0]; f.Get("payment_intent") != "pi_1" || f.Get("amount") != "1500" {
				t.Fatalf("refund form %v", f)
			}
			if api.refundIdem[0] != tc.wantIdem {
				t.Fatalf("Idempotency-Key = %q, want %q", api.refundIdem[0], tc.wantIdem)
			}
		})
	}
}

// Refund is the PaymentProvider form: no key, same request, error only.
func TestStripeRefundDelegates(t *testing.T) {
	api := &stripeAPI{}
	sp := &StripePayments{SecretKey: "sk_test_abc", BaseURL: api.server(t).URL}
	if err := sp.Refund(context.Background(), "pi_9", 700); err != nil {
		t.Fatalf("refund: %v", err)
	}
	if len(api.refunds) != 1 || api.refunds[0].Get("payment_intent") != "pi_9" || api.refunds[0].Get("amount") != "700" || api.refundIdem[0] != "" {
		t.Fatalf("refunds %v idem %q", api.refunds, api.refundIdem)
	}

	api.refundStatus, api.refundBody = 400, `{"error":{"message":"amount too large"}}`
	if err := sp.Refund(context.Background(), "pi_9", 99999); err == nil || !strings.Contains(err.Error(), "status 400") {
		t.Fatalf("refund err = %v, want status 400", err)
	}
}

func TestStubRefund(t *testing.T) {
	if err := (StubPayments{}).Refund(context.Background(), "pi_stub_x", 100); err != nil {
		t.Fatalf("stub refund: %v", err)
	}
}
