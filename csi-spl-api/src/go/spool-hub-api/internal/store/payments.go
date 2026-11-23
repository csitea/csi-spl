package store

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"regexp"
	"strings"
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
	// Locale is the language the BUYER was reading the checkout in (rdb 0025,
	// spec 021 T022): one of i18n.Supported, or "" when they never said. The
	// claim mail is sent by the paid webhook, long after the request is gone,
	// so it can only follow this column; "" leaves it on the hub default.
	Locale string
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
	WorkspaceOrders
}

func errUnknownPayEvent(kind string) error {
	return fmt.Errorf("payment event kind %q is not paid|failed|refund|cancel|ignore", kind)
}

// PaidOwnerInviteTTL is how long the buyer's biz_owner invite waits for the
// first sign-in (047 W1). It outlives the claim link: payments config refuses
// a SPOOL_HUB_PAYMENT_CLAIM_TTL longer than this.
const PaidOwnerInviteTTL = 30 * 24 * time.Hour

// paidOwnerInvite is the invite the paid transition writes in the same
// transaction as the tenant row (047 W1, D1): the checkout email signs in as
// biz_owner with no operator action. Only that verified address is admitted.
func paidOwnerInvite(c Checkout, now time.Time) (Invite, error) {
	return ownerInvite(c.TenantID, c.Email, now)
}

// ownerInvite is the buyer's biz_owner invite, shared by the paid transition
// and the private-workspace order submit.
func ownerInvite(tenant, email string, now time.Time) (Invite, error) {
	in := Invite{TenantID: tenant, Email: email, Role: RoleTenantOwner,
		InvitedBy: AdmittedCheckout, ExpiresAt: now.Add(PaidOwnerInviteTTL)}
	return in, normalizeInvite(&in)
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
	// The buyer's locale is never trusted onward (it prefixes a URL path and
	// picks a mail template file): an unsupported code is refused here.
	if err := checkLocale(c.Locale); err != nil {
		return err
	}
	return checkBuyStamp(c.Org, c.App, "")
}

// The private-workspace order (spec 181 row B2, rdb 0314, Q-18 C): an order
// only, no card; the submit creates the workspace at once and no payment
// provider is called. The invoice comes monthly in arrears, paid by bank
// transfer (B12). The order is the provisioning order row B8 takes to a plan.

// OrderSubmitted is workspace_orders.status of a new order (B8 adds the rest).
const OrderSubmitted = "submitted"

// Billing detail limits (rdb 0314 holds the non-empty and country rules).
const (
	maxBillingName    = 200
	maxBillingAddress = 1000
	maxBillingVATID   = 32
)

var (
	orderIDRe = regexp.MustCompile(`^wo_[a-z2-7]{26}$`)
	countryRe = regexp.MustCompile(`^[A-Z]{2}$`)
)

// BillingDetails is who the monthly invoice is addressed to.
type BillingDetails struct {
	Name    string
	Address string
	Country string // ISO 3166-1 alpha-2, upper case
	VATID   string // "" = none
}

// WorkspaceOrder is one workspace_orders row. RootPubKey is the tenant's
// PLACEHOLDER root key, as a checkout's: its private half was never kept, and
// the buyer signs in through the biz_owner invite of Email.
type WorkspaceOrder struct {
	ID         string
	TenantID   string
	Status     string
	SeatsUsers int // human members (Q-6 A: agents are not seats)
	Email      string
	Billing    BillingDetails
	Locale     string
	RootPubKey ed25519.PublicKey
	CreatedAt  time.Time
}

// WorkspaceOrders is the order submit's store half.
type WorkspaceOrders interface {
	// SubmitWorkspaceOrder writes, in ONE transaction: the tenant (active,
	// plan private_vm), the buyer's biz_owner invite, the seat caps,
	// box_join_enabled on, the private_vm price plan and the order. It is
	// the same tenant creation as the paid transition, with no payment event.
	// A replay (the tenant already has an order by the same email) writes
	// nothing and returns that order with created false. ErrConflict: the
	// tenant exists without an order, or its order has another email.
	SubmitWorkspaceOrder(ctx context.Context, o WorkspaceOrder, now time.Time) (out WorkspaceOrder, created bool, err error)
	// WorkspaceOrder reads the tenant's order; ErrNotFound when none.
	WorkspaceOrder(ctx context.Context, tenant string) (WorkspaceOrder, error)
}

func normalizeOrder(o *WorkspaceOrder, now time.Time) error {
	o.TenantID = strings.TrimSpace(o.TenantID)
	o.Email = strings.ToLower(strings.TrimSpace(o.Email))
	b := &o.Billing
	b.Name, b.Address = strings.TrimSpace(b.Name), strings.TrimSpace(b.Address)
	b.Country, b.VATID = strings.ToUpper(strings.TrimSpace(b.Country)), strings.TrimSpace(b.VATID)
	switch {
	case !orderIDRe.MatchString(o.ID) || o.TenantID == "":
		return errors.New("order id and tenant are required")
	case len(o.RootPubKey) != ed25519.PublicKeySize:
		return fmt.Errorf("order root pubkey must be %d bytes", ed25519.PublicKeySize)
	case o.SeatsUsers < 1:
		return errors.New("an order seats at least one human member")
	case b.Name == "" || len(b.Name) > maxBillingName, b.Address == "" || len(b.Address) > maxBillingAddress:
		return errors.New("billing name and address are required")
	case !countryRe.MatchString(b.Country), len(b.VATID) > maxBillingVATID:
		return errors.New("billing country is a 2-letter code and the VAT id at most 32 characters")
	}
	o.Status = OrderSubmitted
	if err := checkLocale(o.Locale); err != nil {
		return err
	}
	_, err := ownerInvite(o.TenantID, o.Email, now)
	return err
}

// CheckWorkspaceOrder is the submit's input check without the write, so the
// handler answers a bad billing detail with 400 rather than 500.
func CheckWorkspaceOrder(o WorkspaceOrder) error { return normalizeOrder(&o, time.Now()) }

// orderReplay is the replay rule: the stored order answers a submit for its
// tenant by the same email; another email is a conflict.
func orderReplay(old, o WorkspaceOrder) (WorkspaceOrder, bool, error) {
	if old.Email != o.Email {
		return WorkspaceOrder{}, false, ErrConflict
	}
	return old, false, nil
}
