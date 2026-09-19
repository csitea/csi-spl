// Package payments is the M2 buy-a-tenant surface (specs/006
// contracts/checkout-v1.md, payment.md): the PaymentProvider seam copied from
// csi-rel (read-only reference, never imported), cnf-selected rails, the
// signed payment webhook, lde/dev fake-pay, and the claim-once key handover.
//
// Rails are named by PROTOCOL, never by vendor (no-baked-host.tst.sh): which
// company sits behind a rail is cnf's business.
package payments

import (
	"fmt"
	"net/mail"
	"net/url"
	"strings"
	"time"

	"github.com/caarlos0/env/v10"
)

// SPOOL_HUB_PAYMENT_PROVIDER values.
const (
	ProviderNone       = ""
	ProviderFake       = "fake"
	ProviderHostedHMAC = "hosted-hmac"
)

// Rails as the WUI sees them (GET /api/v1/checkout/plan).
const (
	RailNone   = "none"
	RailFake   = "fake"
	RailHosted = "hosted"
)

// Config is the payment slice of the hub env. Every name is published in
// cnf hub.env; SecretKey is a Secret Manager slot, never logged.
type Config struct {
	Provider      string        `env:"SPOOL_HUB_PAYMENT_PROVIDER"`
	EnableFakePay bool          `env:"SPOOL_HUB_ENABLE_FAKE_PAY" envDefault:"false"`
	PlanID        string        `env:"SPOOL_HUB_PAYMENT_PLAN_ID" envDefault:"default"`
	PlanCents     int           `env:"SPOOL_HUB_PAYMENT_PLAN_CENTS" envDefault:"0"`
	Currency      string        `env:"SPOOL_HUB_PAYMENT_CURRENCY" envDefault:"eur"`
	PublicScheme  string        `env:"SPOOL_HUB_PAYMENT_PUBLIC_SCHEME" envDefault:"https"`
	Hold          time.Duration `env:"SPOOL_HUB_PAYMENT_HOLD" envDefault:"1h"`
	APIBase       string        `env:"SPOOL_HUB_PAYMENT_API_BASE"`
	MerchantID    string        `env:"SPOOL_HUB_PAYMENT_MERCHANT_ID"`
	SecretKey     string        `env:"SPOOL_HUB_PAYMENT_SECRET_KEY"`
	SuccessURL    string        `env:"SPOOL_HUB_PAYMENT_SUCCESS_URL"`
	CancelURL     string        `env:"SPOOL_HUB_PAYMENT_CANCEL_URL"`
	CallbackURL   string        `env:"SPOOL_HUB_PAYMENT_CALLBACK_URL"`

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

// validate is the fail-closed boot guard (T018): the hub refuses to start on
// an unknown rail, a named rail it cannot run, or fake-pay outside lde/dev.
// No rail ("") is valid: the hub serves boxes and checkout answers 503.
func (c *Config) validate() error {
	if c.EnableFakePay && !fakeEnv(c.Env) {
		return fmt.Errorf("SPOOL_HUB_ENABLE_FAKE_PAY=true is allowed only with SPOOL_HUB_ENV=lde or dev (got %q)", c.Env)
	}
	switch c.Provider {
	case ProviderNone:
	case ProviderFake:
		if !c.EnableFakePay {
			return fmt.Errorf("SPOOL_HUB_PAYMENT_PROVIDER=fake needs SPOOL_HUB_ENABLE_FAKE_PAY=true (lde/dev only)")
		}
	case ProviderHostedHMAC:
		for name, v := range map[string]string{
			"SPOOL_HUB_PAYMENT_MERCHANT_ID": c.MerchantID,
			"SPOOL_HUB_PAYMENT_SECRET_KEY":  c.SecretKey,
		} {
			if strings.TrimSpace(v) == "" || LooksLikePlaceholderSecret(v) {
				return fmt.Errorf("%s must be set (not a placeholder) while SPOOL_HUB_PAYMENT_PROVIDER=%s", name, c.Provider)
			}
		}
		for name, v := range map[string]string{
			"SPOOL_HUB_PAYMENT_API_BASE":     c.APIBase,
			"SPOOL_HUB_PAYMENT_SUCCESS_URL":  c.SuccessURL,
			"SPOOL_HUB_PAYMENT_CANCEL_URL":   c.CancelURL,
			"SPOOL_HUB_PAYMENT_CALLBACK_URL": c.CallbackURL,
		} {
			if err := c.checkURL(name, v); err != nil {
				return err
			}
		}
		if c.PlanCents <= 0 {
			return fmt.Errorf("SPOOL_HUB_PAYMENT_PLAN_CENTS must be > 0 while SPOOL_HUB_PAYMENT_PROVIDER=%s", c.Provider)
		}
	default:
		return fmt.Errorf("SPOOL_HUB_PAYMENT_PROVIDER %q is not a known rail (\"\", %s, %s)", c.Provider, ProviderFake, ProviderHostedHMAC)
	}
	if c.PlanCents < 0 {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_PLAN_CENTS must not be negative")
	}
	if len(c.Currency) != 3 {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_CURRENCY %q must be a 3-letter code", c.Currency)
	}
	if strings.TrimSpace(c.PlanID) == "" {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_PLAN_ID must not be empty")
	}
	if c.PublicScheme != "https" && c.PublicScheme != "http" {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_PUBLIC_SCHEME %q must be http or https", c.PublicScheme)
	}
	if c.Hold <= 0 {
		return fmt.Errorf("SPOOL_HUB_PAYMENT_HOLD must be positive")
	}
	return nil
}

// checkURL: an absolute URL with no placeholder; https outside lde.
func (c *Config) checkURL(name, v string) error {
	u, err := url.Parse(strings.TrimSpace(v))
	if v == "" || err != nil || u.Host == "" || LooksLikePlaceholderSecret(v) ||
		(u.Scheme != "https" && !(u.Scheme == "http" && c.Env == "lde")) {
		return fmt.Errorf("%s must be an absolute https URL while SPOOL_HUB_PAYMENT_PROVIDER=%s (no default host)", name, c.Provider)
	}
	return nil
}

// Rail is what checkout runs: the named provider, or fake when only the
// fake-pay flag is set.
func (c *Config) Rail() string {
	switch {
	case c.Provider == ProviderHostedHMAC:
		return RailHosted
	case c.Provider == ProviderFake, c.Provider == ProviderNone && c.EnableFakePay:
		return RailFake
	}
	return RailNone
}

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
