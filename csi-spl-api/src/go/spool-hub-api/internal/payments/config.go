// Package payments is the M2 buy-a-tenant surface (specs/006
// contracts/checkout-v1.md, payment.md): csi-rel's payment code copied with
// names adapted (owner direction 2026-09-19: Stripe exactly as csi-rel, plus
// csi-rel's PayPal off by default), the signed webhooks, lde/dev fake-pay,
// and the claim-once key handover. csi-rel is read-only reference; this
// module never imports it. This package is the ONLY Go allowed to name a
// payment vendor (no-baked-host.tst.sh).
package payments

import (
	"fmt"
	"net/mail"
	"net/url"
	"strings"
	"time"

	"github.com/caarlos0/env/v10"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPOOL_HUB_PAYMENT_PROVIDER values: the primary (card) rail.
const (
	ProviderNone   = ""
	ProviderFake   = "fake"
	ProviderStripe = "stripe"
	// ProviderPayPal is the optional wallet rail (SPOOL_HUB_ENABLE_PAYPAL);
	// also payment_checkouts.provider / webhook_events_seen.provider.
	ProviderPayPal = "paypal"
)

// Rails as the WUI sees them (GET /api/v1/checkout/plan, checkout-v1 §1.1).
const (
	RailNone = "none"
	RailFake = "fake"
	RailCard = "card"
)

// Checkout methods (POST /api/v1/checkout "method").
const (
	MethodCard   = "card"
	MethodPayPal = "paypal"
)

// GuardReasonMisconfigured is the 503 detail while a deployed card rail's
// keys are unusable (csi-rel F-17 payment_provider_misconfigured).
const GuardReasonMisconfigured = "payment_provider_misconfigured"

// Config is the payment slice of the hub env. Every name is published in
// cnf hub.env; *_SECRET* values are Secret Manager slots, never logged.
type Config struct {
	Provider      string        `env:"SPOOL_HUB_PAYMENT_PROVIDER"`
	EnableFakePay bool          `env:"SPOOL_HUB_ENABLE_FAKE_PAY" envDefault:"false"`
	PlanID        string        `env:"SPOOL_HUB_PAYMENT_PLAN_ID" envDefault:"default"`
	PlanCents     int           `env:"SPOOL_HUB_PAYMENT_PLAN_CENTS" envDefault:"0"`
	Currency      string        `env:"SPOOL_HUB_PAYMENT_CURRENCY" envDefault:"eur"`
	PublicScheme  string        `env:"SPOOL_HUB_PAYMENT_PUBLIC_SCHEME" envDefault:"https"`
	Hold          time.Duration `env:"SPOOL_HUB_PAYMENT_HOLD" envDefault:"1h"`
	// ClaimURL is the WUI claim page the emailed single-use link opens
	// (017 T008): <ClaimURL>#checkout=<id>&token=<t>. Required with a rail.
	ClaimURL string        `env:"SPOOL_HUB_PAYMENT_CLAIM_URL"`
	ClaimTTL time.Duration `env:"SPOOL_HUB_PAYMENT_CLAIM_TTL" envDefault:"24h"`

	// M4 seats (specs/009 T004): the monthly price of one user (HUM-*) seat
	// and one bot seat, on top of PlanCents. Both 0 = seats are not sold (the
	// M2 SKU, 009 FR-001). A priced kind is bought 1..SeatsMax per checkout;
	// an unpriced kind stays 0 (= unlimited, 009 D-2).
	SeatUserCents int `env:"SPOOL_HUB_PAYMENT_SEAT_USER_CENTS" envDefault:"0"`
	SeatBotCents  int `env:"SPOOL_HUB_PAYMENT_SEAT_BOT_CENTS" envDefault:"0"`
	SeatsMax      int `env:"SPOOL_HUB_PAYMENT_SEATS_MAX" envDefault:"1000"`
	// Dedicated: this SKU mints a GCP project id at the paid event (009
	// T005): checkout then takes the buyer's org / app codes.
	Dedicated bool `env:"SPOOL_HUB_PAYMENT_DEDICATED" envDefault:"false"`

	// Stripe (csi-rel STRIPE_*). SecretKey + WebhookSecret are secrets.
	StripeSecretKey      string `env:"SPOOL_HUB_STRIPE_SECRET_KEY"`
	StripeWebhookSecret  string `env:"SPOOL_HUB_STRIPE_WEBHOOK_SECRET"`
	StripePublishableKey string `env:"SPOOL_HUB_STRIPE_PUBLISHABLE_KEY"`
	StripeAPIBase        string `env:"SPOOL_HUB_STRIPE_API_BASE"`
	StripeAPIVersion     string `env:"SPOOL_HUB_STRIPE_API_VERSION"`

	// PayPal (csi-rel PAYPAL_* + ENABLE_PAYPAL). ClientSecret is a secret.
	EnablePayPal       bool   `env:"SPOOL_HUB_ENABLE_PAYPAL" envDefault:"false"`
	PayPalClientID     string `env:"SPOOL_HUB_PAYPAL_CLIENT_ID"`
	PayPalClientSecret string `env:"SPOOL_HUB_PAYPAL_CLIENT_SECRET"`
	PayPalMode         string `env:"SPOOL_HUB_PAYPAL_MODE" envDefault:"sandbox"`
	PayPalAPIBase      string `env:"SPOOL_HUB_PAYPAL_API_BASE"`
	PayPalWebhookID    string `env:"SPOOL_HUB_PAYPAL_WEBHOOK_ID"`

	// Env is SPOOL_HUB_ENV (lde | dev | prd), set by Load.
	Env string `env:"-"`
}

// Load reads the process environment for hub env hubEnv.
func Load(hubEnv string) (*Config, error) { return load(hubEnv, env.Options{}) }

// LoadFrom reads only vars (tests).
func LoadFrom(hubEnv string, vars map[string]string) (*Config, error) {
	return load(hubEnv, env.Options{Environment: vars})
}

func load(hubEnv string, o env.Options) (*Config, error) {
	var c Config
	if err := env.ParseWithOptions(&c, o); err != nil {
		return nil, fmt.Errorf("parse payment config: %w", err)
	}
	c.Env = strings.ToLower(strings.TrimSpace(hubEnv))
	c.Provider = strings.ToLower(strings.TrimSpace(c.Provider))
	c.Currency = strings.ToLower(strings.TrimSpace(c.Currency))
	if err := c.validate(); err != nil {
		return nil, err
	}
	return &c, nil
}

// fakeEnv: the only envs where money may be faked (csi-rel 077: never prd).
func fakeEnv(e string) bool { return e == "lde" || e == "dev" }

// validate is the boot guard (T018): the hub refuses to start on an unknown
// rail, fake-pay outside lde/dev, or PayPal where csi-rel forbids it (prd or
// live mode) or without its credentials. A card rail with unusable keys does
// NOT stop the hub (it also carries every box): Guard() fail-closes checkout
// with 503, as csi-rel's F-17 guard does.
func (c *Config) validate() error {
	for _, check := range []func() error{c.checkRails, c.checkPayPal, c.checkPrices, c.checkClaim} {
		if err := check(); err != nil {
			return err
		}
	}
	return nil
}

// checkRails refuses fake-pay outside lde/dev, an unknown rail and a malformed API base.
func (c *Config) checkRails() error {
	if c.EnableFakePay && !fakeEnv(c.Env) {
		return fmt.Errorf("SPOOL_HUB_ENABLE_FAKE_PAY=true is allowed only with SPOOL_HUB_ENV=lde or dev (got %q)", c.Env)
	}
	switch c.Provider {
	case ProviderNone, ProviderStripe:
	case ProviderFake:
		if !c.EnableFakePay {
			return fmt.Errorf("SPOOL_HUB_PAYMENT_PROVIDER=fake needs SPOOL_HUB_ENABLE_FAKE_PAY=true (lde/dev only)")
		}
	default:
		return fmt.Errorf("SPOOL_HUB_PAYMENT_PROVIDER %q is not a known rail (\"\", %s, %s)", c.Provider, ProviderFake, ProviderStripe)
	}
	for name, v := range map[string]string{"SPOOL_HUB_STRIPE_API_BASE": c.StripeAPIBase, "SPOOL_HUB_PAYPAL_API_BASE": c.PayPalAPIBase} {
		if err := c.checkBase(name, v); err != nil {
			return err
		}
	}
	return nil
}

// checkPayPal keeps PayPal out of prd and live mode, and needs its credentials.
func (c *Config) checkPayPal() error {
	if !c.EnablePayPal {
		return nil
	}
	// csi-rel PayPalFirstPartyForbidden: never prd, never live mode.
	if c.Env == "prd" || strings.EqualFold(strings.TrimSpace(c.PayPalMode), ModeLive) {
		return fmt.Errorf("SPOOL_HUB_ENABLE_PAYPAL=true is refused in prd and with SPOOL_HUB_PAYPAL_MODE=live (not live-tested)")
	}
	for name, v := range map[string]string{
		"SPOOL_HUB_PAYPAL_CLIENT_ID": c.PayPalClientID, "SPOOL_HUB_PAYPAL_CLIENT_SECRET": c.PayPalClientSecret,
		"SPOOL_HUB_PAYPAL_WEBHOOK_ID": c.PayPalWebhookID,
	} {
		if strings.TrimSpace(v) == "" || LooksLikePlaceholderSecret(v) {
			return fmt.Errorf("%s must be set (not a placeholder) while SPOOL_HUB_ENABLE_PAYPAL=true", name)
		}
	}
	return nil
}

// checkPrices checks the plan and seat prices, the dedicated-project env and the plan identity.
func (c *Config) checkPrices() error {
	if c.PlanCents < 0 {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_PLAN_CENTS must not be negative")
	}
	if c.PlanCents == 0 && (c.Provider == ProviderStripe || c.EnablePayPal) {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_PLAN_CENTS must be > 0 for a real payment rail")
	}
	if c.SeatUserCents < 0 || c.SeatBotCents < 0 || c.SeatsMax < 1 {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_SEAT_*_CENTS must be >= 0 and SPOOL_HUB_PAYMENT_SEATS_MAX >= 1")
	}
	if c.Dedicated {
		if _, err := store.MintProjectID("abc", "abc", c.Env, time.Time{}); err != nil {
			return fmt.Errorf("SPOOL_HUB_PAYMENT_DEDICATED=true needs a hub env usable in a project id: %w", err)
		}
	}
	if len(c.Currency) != 3 {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_CURRENCY %q must be a 3-letter code", c.Currency)
	}
	if strings.TrimSpace(c.PlanID) == "" {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_PLAN_ID must not be empty")
	}
	return nil
}

// checkClaim checks the public scheme, the hold and claim lifetimes and the claim page.
func (c *Config) checkClaim() error {
	if c.PublicScheme != "https" && c.PublicScheme != "http" {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_PUBLIC_SCHEME %q must be http or https", c.PublicScheme)
	}
	if c.Hold <= 0 || c.ClaimTTL <= 0 {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_HOLD and SPOOL_HUB_PAYMENT_CLAIM_TTL must be positive")
	}
	if c.ClaimTTL > store.PaidOwnerInviteTTL { // 047 W1: the owner invite outlives the claim link
		return fmt.Errorf("SPOOL_HUB_PAYMENT_CLAIM_TTL must be at most %s (the buyer's owner invite)", store.PaidOwnerInviteTTL)
	}
	// A SET but malformed claim page refuses boot; an unset one only guards
	// checkout (Guard): an image roll must never crash-loop the hub that also
	// carries every box because the env has not caught up yet.
	if v := strings.TrimSpace(c.ClaimURL); v != "" {
		u, err := url.Parse(v)
		if err != nil || u.Host == "" || u.Fragment != "" || LooksLikePlaceholderSecret(v) ||
			(u.Scheme != "https" && !(u.Scheme == "http" && c.Env == "lde")) {
			return fmt.Errorf("SPOOL_HUB_PAYMENT_CLAIM_URL %q must be the WUI claim page (absolute https URL, no fragment)", c.ClaimURL)
		}
	}
	return nil
}

// checkBase: empty (the driver's own host) or an absolute URL; http only in
// lde (a local stripe-mock).
func (c *Config) checkBase(name, v string) error {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	u, err := url.Parse(strings.TrimSpace(v))
	if err != nil || u.Host == "" || (u.Scheme != "https" && !(u.Scheme == "http" && c.Env == "lde")) {
		return fmt.Errorf("%s %q must be an absolute https URL (http only in lde)", name, v)
	}
	return nil
}

// Guard reports why checkout must 503 (csi-rel F-17): no claim page for the
// link mail (017 T008), or on the card rail a secret key that is unset or not
// Stripe-shaped, or a missing webhook secret / publishable key. "" = usable.
// Shape only; never logs a value.
func (c *Config) Guard() string {
	if strings.TrimSpace(c.ClaimURL) == "" && (c.Rail() != RailNone || c.EnablePayPal) {
		return "claim page unset (SPOOL_HUB_PAYMENT_CLAIM_URL)"
	}
	if c.Provider != ProviderStripe {
		return ""
	}
	if p := StripeKeyProblem(c.StripeSecretKey); p != "" {
		return "secret key " + p
	}
	if w := strings.TrimSpace(c.StripeWebhookSecret); w == "" || LooksLikePlaceholderSecret(w) {
		return "webhook secret unset"
	}
	if pk := strings.TrimSpace(c.StripePublishableKey); !strings.HasPrefix(pk, "pk_test_") && !strings.HasPrefix(pk, "pk_live_") {
		return "publishable key unset or malformed"
	}
	return ""
}

// Rail is the primary rail checkout runs: stripe (card), or fake when the
// fake provider or only the fake-pay flag is set.
func (c *Config) Rail() string {
	switch {
	case c.Provider == ProviderStripe:
		return RailCard
	case c.Provider == ProviderFake, c.Provider == ProviderNone && c.EnableFakePay:
		return RailFake
	}
	return RailNone
}

// Methods lists what POST /api/v1/checkout accepts.
func (c *Config) Methods() []string {
	var m []string
	switch c.Rail() {
	case RailCard, RailFake:
		m = append(m, MethodCard)
	}
	if c.EnablePayPal {
		m = append(m, MethodPayPal)
	}
	return m
}

// SeatsSold reports whether checkout sells M4 seats (a seat kind is priced).
func (c *Config) SeatsSold() bool { return c.SeatUserCents > 0 || c.SeatBotCents > 0 }

// FakePayMounted reports whether POST /api/v1/checkout/fake-pay exists.
func (c *Config) FakePayMounted() bool { return c.Rail() == RailFake && fakeEnv(c.Env) }

// LooksLikePlaceholderSecret reports a provisioning marker rather than a
// credential (csi-rel fail-closed boot guard; shape only, never logs it).
func LooksLikePlaceholderSecret(v string) bool {
	t := strings.TrimSpace(v)
	if t == "" {
		return false
	}
	u := strings.ToUpper(t)
	for _, m := range []string{"PLACEHOL", "CHANGEME", "CHANGE_ME", "CHANGE-ME", "REPLACE", "TODO", "FIXME", "DUMMY"} {
		if strings.Contains(u, m) {
			return true
		}
	}
	if strings.HasPrefix(t, "${") || strings.HasPrefix(t, "<") || strings.HasSuffix(t, ">") {
		return true
	}
	return strings.Trim(u, "X-_.") == ""
}

// validEmail accepts one bare address (no display name, no CR/LF).
func validEmail(s string) bool {
	if s == "" || len(s) > 254 || strings.ContainsAny(s, "\r\n <>") {
		return false
	}
	a, err := mail.ParseAddress(s)
	return err == nil && a.Address == s && strings.Contains(s[strings.LastIndex(s, "@"):], ".")
}
