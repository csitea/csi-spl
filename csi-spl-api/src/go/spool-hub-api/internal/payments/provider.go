package payments

import (
	"context"
	"fmt"
	"net/http"
)

// PaymentProvider is the rail seam every driver implements (copied from
// csi-rel orders/payment_provider.go + its RedirectProvider extension, cut to
// what selling one tenant needs; card-country / BIN / Connect / invoices are
// payment.md "Do not copy"). Amount is the M2 tenant plan from cnf.
type PaymentProvider interface {
	// CreateRedirectOrder starts the provider-side payment for checkoutID and
	// returns the provider's reference plus the URL to send the buyer to
	// ("" for a rail with no hosted page).
	CreateRedirectOrder(ctx context.Context, checkoutID, email, currency string, totalCents int) (ref, redirectURL string, err error)
	// Refund and CancelIntent exist for the operator; M2 checkout never calls
	// them (a refund is decided by a human, payment.md).
	Refund(ctx context.Context, ref string, amountCents int) error
	// CancelIntent is idempotent: cancelling a terminal payment is benign.
	CancelIntent(ctx context.Context, ref string) error
}

// WebhookVerifier is implemented by rails with a signed server-to-server
// callback. Verify MUST fail before the caller writes anything.
type WebhookVerifier interface {
	// VerifyWebhook authenticates r (whose body is already read into body)
	// and returns the event. Any failure is ErrSigBad.
	VerifyWebhook(r *http.Request, body []byte) (Event, error)
	// Name is webhook_events_seen.provider for this rail.
	Name() string
}

// Event is a verified provider event mapped onto store.PayEvent*.
type Event struct {
	ID         string // dedup key within the rail
	CheckoutID string
	Kind       string
}

// ErrSigBad covers every verification failure; the handler answers 400 with
// no detail so nobody can iterate on the reason (csi-rel webhooks).
var ErrSigBad = fmt.Errorf("payments: webhook signature verification failed")

// Fake is the credential-free rail (csi-rel 077 / the old Stub): nothing is
// created anywhere; POST /api/v1/checkout/fake-pay marks the checkout paid.
type Fake struct{}

func (Fake) CreateRedirectOrder(_ context.Context, checkoutID, _, _ string, _ int) (string, string, error) {
	return "fake_" + checkoutID, "", nil
}
func (Fake) Refund(context.Context, string, int) error  { return nil }
func (Fake) CancelIntent(context.Context, string) error { return nil }

// Wire builds the driver cnf names; Load has already refused a rail it
// cannot run, so this cannot fail for a loaded Config.
func Wire(c *Config) (PaymentProvider, WebhookVerifier, error) {
	switch c.Rail() {
	case RailFake:
		return Fake{}, nil, nil
	case RailHosted:
		h := &HostedHMAC{MerchantID: c.MerchantID, Secret: c.SecretKey, BaseURL: c.APIBase,
			SuccessURL: c.SuccessURL, CancelURL: c.CancelURL, CallbackURL: c.CallbackURL}
		return h, h, nil
	case RailNone:
		return nil, nil, nil
	}
	return nil, nil, fmt.Errorf("payments: no driver for rail %q", c.Rail())
}
