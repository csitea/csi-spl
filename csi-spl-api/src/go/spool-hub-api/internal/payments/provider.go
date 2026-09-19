package payments

import (
	"context"
	"errors"
)

// PaymentProvider is csi-rel's provider seam (orders/payment_provider.go),
// without CardCountry / CardBIN (sanctions guard, not copied). The card rail
// (StripePayments) and the wallet rail (PayPal) implement it; StubPayments is
// the credential-free fake-pay rail.
type PaymentProvider interface {
	CreateIntent(ctx context.Context, orderID string, totalCents int, currency string) (intentID, clientSecret string, err error)
	Refund(ctx context.Context, intentID string, amountCents int) error
	// CancelIntent cancels the provider-side payment so a late payment can no
	// longer be confirmed. Cancelling a terminal intent MUST be benign.
	CancelIntent(ctx context.Context, intentID string) error
}

// ProviderOrderProvider is csi-rel's approve-then-capture extension (PayPal
// Orders v2, 050): the buyer approves in the provider's popup, then the WUI
// asks us to capture.
type ProviderOrderProvider interface {
	CreateProviderOrder(ctx context.Context, storeOrderID string, totalCents int, currency string) (providerOrderID, approveURL string, err error)
	CaptureProviderOrder(ctx context.Context, providerOrderID, requestID string) (captureID, payerID string, err error)
}

// ErrSigBad covers every webhook-verification failure; the handler answers
// 400 with no detail so nobody can iterate on the reason (csi-rel webhooks).
var ErrSigBad = errors.New("webhook: signature verification failed")

// StubPayments is csi-rel's credential-free provider: always succeeds, ids
// derived from the order id. Here it is the fake-pay rail (lde/dev); the
// paid transition comes from POST /api/v1/checkout/fake-pay (csi-rel 077).
type StubPayments struct{}

func (StubPayments) CreateIntent(_ context.Context, orderID string, _ int, _ string) (string, string, error) {
	return "pi_stub_" + orderID, "pi_stub_secret_" + orderID, nil
}
func (StubPayments) Refund(_ context.Context, _ string, _ int) error { return nil }

// CancelIntent: the stub has no provider to talk to; trivially idempotent.
func (StubPayments) CancelIntent(_ context.Context, _ string) error { return nil }
