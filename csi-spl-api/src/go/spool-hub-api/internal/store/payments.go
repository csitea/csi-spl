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

// ErrClaimed is a second claim: the key was already minted and shown once.
var ErrClaimed = errors.New("checkout already claimed")

// ErrClaimExpired is a claim after claim_expires_at.
var ErrClaimExpired = errors.New("checkout claim expired")

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

// Checkout is one payment_checkouts row. RootPubKey is a PLACEHOLDER until the
// claim rotates it to the key minted then (checkout-v1 §0.2, 017 T008): no
// private key exists before the claim and none is ever stored. ClaimHash /
// MailClaimHash are SHA-256 of the browser and the emailed claim tokens.
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
	ClaimHash     []byte
	MailClaimHash []byte    // nil until SetClaimLink
	ClaimExpires  time.Time // zero = no expiry set yet
	CreatedAt     time.Time
	PaidAt        time.Time // zero = NULL
	ClaimedAt     time.Time // zero = NULL
	// M4 line items (009 T004, rdb 0016): seats bought (0 = none; the M2 SKU
	// always carries 0) and, for a dedicated SKU, the buyer's org / app codes
	// ("" = hosted: no project_id is minted). The paid transition writes the
	// seat caps, the monthly period and the project stamp from these.
	SeatsUsers int
	SeatsBots  int
	Org        string
	App        string
}

// SeatPeriod is one tenant_seat_periods row: the seats paid for one UTC
// calendar month (009 T002, D-4).
type SeatPeriod struct {
	TenantID    string
	PeriodStart time.Time // first day of the UTC month, 00:00 UTC
	SeatsUsers  int
	SeatsBots   int
	CheckoutID  string
	AmountCents int
	PaidAt      time.Time
}

// PaymentEvent is one verified provider (or fake-pay) event.
type PaymentEvent struct {
	Provider   string // webhook_events_seen.provider
	EventID    string // dedup key within Provider
	CheckoutID string
	Kind       string // PayEvent*
	// Env is the hub env (lde | dev | prd): the {env} of a dedicated SKU's
	// project_id, minted at this event's UTC minute (009 T005).
	Env string
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
	// A paid event also applies the checkout's M4 line items in that same
	// transaction (applySeats): the seat caps, the month's seat period and,
	// for a dedicated SKU, the project_id stamp at now's UTC minute.
	ApplyPayment(ctx context.Context, ev PaymentEvent, now time.Time) (outcome string, err error)
	// SetClaimLink stores the emailed claim token's hash and the claim expiry
	// (set once, when the checkout is paid). ErrNotFound for an unknown id.
	SetClaimLink(ctx context.Context, id string, mailClaimHash []byte, expires time.Time) error
	// ClaimCheckout accepts either claim hash of a paid, unclaimed, unexpired
	// checkout and, atomically: rotates the tenant's and the checkout's root
	// pubkey from the placeholder to newPub, marks it claimed and burns both
	// hashes. ErrNotFound for an unknown id or a wrong hash, ErrNotPaid while
	// pending, ErrClaimed after the first claim, ErrClaimExpired past the TTL,
	// ErrConflict when the tenant no longer carries the placeholder.
	ClaimCheckout(ctx context.Context, id string, claimHash []byte, now time.Time, newPub ed25519.PublicKey) (Checkout, error)
	// SeatPeriods lists the tenant's paid seat months, oldest first.
	SeatPeriods(ctx context.Context, tenantID string) ([]SeatPeriod, error)
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
	if len(c.ClaimHash) != 32 {
		return errors.New("checkout needs a 32-byte claim hash")
	}
	if c.AmountCents < 0 || c.Currency == "" {
		return errors.New("checkout amount must be >= 0 with a currency")
	}
	if c.PlanID == "" {
		c.PlanID = "default"
	}
	if err := checkSeatCaps(c.SeatsUsers, c.SeatsBots); err != nil {
		return err
	}
	if (c.Org == "") != (c.App == "") {
		return errors.New("checkout org and app come together (dedicated SKU) or not at all")
	}
	return checkBuyStamp(c.Org, c.App, "")
}
