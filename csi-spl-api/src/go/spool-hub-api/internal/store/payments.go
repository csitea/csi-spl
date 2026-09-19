package store

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"time"
)

// M2 checkout state (specs/006 contracts/checkout-v1.md, rdb 0003 + 0011).
// A checkout HOLDS a slug; the tenants row is created only by a paid event.

// ErrNotPaid is a claim on a checkout that is not paid yet.
var ErrNotPaid = errors.New("checkout not paid")

// ErrClaimed is a second claim: the sealed key is already gone.
var ErrClaimed = errors.New("checkout already claimed")

// payment_checkouts.status values.
const (
	CheckoutPending   = "pending"
	CheckoutPaid      = "paid"
	CheckoutFailed    = "failed"
	CheckoutCancelled = "cancelled"
)

// Payment event kinds (ApplyPayment). The rail maps its own status onto these.
const (
	PayEventPaid   = "paid"
	PayEventFailed = "failed"
	PayEventRefund = "refund"
	PayEventCancel = "cancel"
	PayEventIgnore = "ignore"
)

// ApplyPayment outcomes (the webhook's "action").
const (
	PayOutcomeDuplicate   = "duplicate"
	PayOutcomePaid        = "paid"
	PayOutcomeAlreadyPaid = "already_paid"
	PayOutcomeFailed      = "failed"
	PayOutcomeRefund      = "refund"
	PayOutcomeIgnored     = "ignored"
	PayOutcomeNoMatch     = "no_matching_checkout"
	// PayOutcomeConflict: paid, but the slug belongs to another root key.
	// Nothing is written but the dedup row; a human refunds.
	PayOutcomeConflict = "conflict"
)

// Checkout is one payment_checkouts row. SealedRootKey is ciphertext the hub
// cannot open (checkout-v1 §0.2); ClaimHash is SHA-256 of the claim token.
type Checkout struct {
	ID            string // payment_checkouts.intent_id
	TenantID      string
	PlanID        string
	Provider      string
	ProviderRef   string
	AmountCents   int
	Currency      string
	Status        string
	Email         string
	RootPubKey    ed25519.PublicKey
	SealedRootKey []byte
	ClaimHash     []byte
	CreatedAt     time.Time
	PaidAt        time.Time // zero = NULL
	ClaimedAt     time.Time // zero = NULL
}

// PaymentEvent is one verified provider (or fake-pay) event.
type PaymentEvent struct {
	Provider   string // webhook_events_seen.provider
	EventID    string // dedup key within Provider
	CheckoutID string
	Kind       string // PayEvent*
}

// Payments is the checkout persistence contract.
type Payments interface {
	// HoldCheckout inserts a pending checkout. ErrConflict when the tenant
	// exists or another pending hold on the slug is younger than hold; an
	// older hold is cancelled first.
	HoldCheckout(ctx context.Context, c Checkout, now time.Time, hold time.Duration) error
	GetCheckout(ctx context.Context, id string) (Checkout, error)
	// CheckoutByProviderRef finds the checkout whose provider-side id (a card
	// intent, a wallet order) is ref: webhooks name the provider's id, as in
	// csi-rel (orders.payment_intent_id / provider_order_id). ErrNotFound if none.
	CheckoutByProviderRef(ctx context.Context, provider, ref string) (Checkout, error)
	// ApplyPayment records (Provider, EventID) and applies the event in ONE
	// transaction: a duplicate changes nothing, and a failed apply leaves no
	// dedup row, so the provider's retry is not swallowed.
	ApplyPayment(ctx context.Context, ev PaymentEvent, now time.Time) (outcome string, err error)
	// ClaimCheckout returns the paid checkout (with its seal) and wipes the
	// seal atomically. ErrNotFound for an unknown id or a wrong hash,
	// ErrNotPaid while pending, ErrClaimed after the first claim.
	ClaimCheckout(ctx context.Context, id string, claimHash []byte, now time.Time) (Checkout, error)
}

func errUnknownPayEvent(kind string) error {
	return fmt.Errorf("payment event kind %q is not paid|failed|refund|cancel|ignore", kind)
}

func normalizeCheckout(c *Checkout) error {
	if c.ID == "" || c.TenantID == "" || c.Provider == "" {
		return errors.New("checkout id, tenant and provider are required")
	}
	if len(c.RootPubKey) != ed25519.PublicKeySize {
		return fmt.Errorf("checkout root pubkey must be %d bytes", ed25519.PublicKeySize)
	}
	if len(c.ClaimHash) != 32 || len(c.SealedRootKey) == 0 {
		return errors.New("checkout needs a 32-byte claim hash and a sealed key")
	}
	if c.AmountCents < 0 || c.Currency == "" {
		return errors.New("checkout amount must be >= 0 with a currency")
	}
	if c.PlanID == "" {
		c.PlanID = "default"
	}
	return nil
}
