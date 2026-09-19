// Package auth is the hub's browser sign-in (spec 010-spool-social-auth):
// Google (OIDC), Facebook (OAuth 2.0 + Graph) and the generic OIDC providers
// Microsoft, LinkedIn and xAI (FR-012) — authorization-code login for the WUI, a signed CSRF `state` bound to a browser cookie, a server-side code
// exchange with the provider's client secret, and a stateless HMAC-signed
// session cookie.
//
// Modeled on csi-rel spec 052: a confidential server-side client (no PKCE),
// the verified email is the identity, an IdP response never mints privilege.
// Registering the human (HUM-*, spec 004) and deciding which tenant a session
// may read are the hub's calls, made through the Registrar hook and
// SessionFromRequest; this package never touches the store.
//
// Every value is an env var. Auth is OFF until SPOOL_HUB_AUTH_PROVIDERS names
// a provider; from then on every variable a listed provider needs must hold a
// real (non-placeholder) value or Load fails fast.
package auth

import (
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/caarlos0/env/v10"
)

// Provider slugs: the {provider} path segment, the session's `p` claim and the
// SPOOL_HUB_AUTH_<SLUG>_* env prefix.
const (
	ProviderGoogle    = "google"
	ProviderFacebook  = "facebook"
	ProviderMicrosoft = "microsoft"
	ProviderLinkedIn  = "linkedin"
	ProviderXAI       = "xai"
)

// knownProviders are the slugs this package implements.
var knownProviders = map[string]bool{ProviderGoogle: true, ProviderFacebook: true,
	ProviderMicrosoft: true, ProviderLinkedIn: true, ProviderXAI: true}

// plannedProviders are named by SPEC-spool-social-auth.md §1 on the same
// rails but not built yet: listing one fails fast instead of silently
// advertising a button that 404s. Empty since T040-T042.
var plannedProviders = map[string]bool{}

// microsoftConsumers is the Entra authority for personal Microsoft accounts
// only, the one tenant whose email Microsoft itself verifies (OQ-I1).
const microsoftConsumers = "consumers"

// Config is the resolved auth configuration. The env names are published in
// csi-spl-cnf all.env.yaml env.auth.social; the code reads those names only.
type Config struct {
	// Providers is the comma list of enabled slugs. Empty = auth off: the
	// provider list is empty and start/callback answer 404.
	Providers string `env:"SPOOL_HUB_AUTH_PROVIDERS"`
	// SessionKey signs the session cookie and the OAuth state (separate derived
	// subkeys). A secret: Secret Manager, never cnf. At least 32 bytes.
	SessionKey string `env:"SPOOL_HUB_AUTH_SESSION_KEY"`
	// AppURL is the WUI origin the browser lands on after the callback. A
	// failure lands on <AppURL>/login?auth_error=<code>.
	AppURL       string        `env:"SPOOL_HUB_AUTH_APP_URL"`
	SessionTTL   time.Duration `env:"SPOOL_HUB_AUTH_SESSION_TTL" envDefault:"12h"`
	StateTTL     time.Duration `env:"SPOOL_HUB_AUTH_STATE_TTL" envDefault:"15m"`
	CookieName   string        `env:"SPOOL_HUB_AUTH_COOKIE_NAME" envDefault:"spool_session"`
	CookieDomain string        `env:"SPOOL_HUB_AUTH_COOKIE_DOMAIN"`
	CookieSecure bool          `env:"SPOOL_HUB_AUTH_COOKIE_SECURE" envDefault:"true"`
	// IdPBaseURL points EVERY provider at one fake IdP (fakeidp: lde, tests,
	// the auth-demo). Refused in prd, where it would hand client secrets to
	// that host.
	IdPBaseURL string `env:"SPOOL_HUB_AUTH_IDP_BASE_URL"`

	GoogleClientID     string `env:"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID"`
	GoogleClientSecret string `env:"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET"`
	GoogleRedirectURI  string `env:"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI"`
	GoogleScopes       string `env:"SPOOL_HUB_AUTH_GOOGLE_SCOPES" envDefault:"openid email profile"`

	FacebookClientID     string `env:"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID"`
	FacebookClientSecret string `env:"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET"`
	FacebookRedirectURI  string `env:"SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI"`
	FacebookScopes       string `env:"SPOOL_HUB_AUTH_FACEBOOK_SCOPES" envDefault:"email,public_profile"`

	MicrosoftClientID     string `env:"SPOOL_HUB_AUTH_MICROSOFT_CLIENT_ID"`
	MicrosoftClientSecret string `env:"SPOOL_HUB_AUTH_MICROSOFT_CLIENT_SECRET"`
	MicrosoftRedirectURI  string `env:"SPOOL_HUB_AUTH_MICROSOFT_REDIRECT_URI"`
	MicrosoftScopes       string `env:"SPOOL_HUB_AUTH_MICROSOFT_SCOPES" envDefault:"openid email profile"`
	// MicrosoftTenant is the Entra authority segment. OQ-I1 (a): "consumers"
	// (personal accounts, verified email). Anything else needs
	// MicrosoftTrustEmail, because a work tenant's email claim is set by that
	// tenant's admin and never verified.
	MicrosoftTenant     string `env:"SPOOL_HUB_AUTH_MICROSOFT_TENANT" envDefault:"consumers"`
	MicrosoftTrustEmail bool   `env:"SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL" envDefault:"false"`

	LinkedInClientID     string `env:"SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID"`
	LinkedInClientSecret string `env:"SPOOL_HUB_AUTH_LINKEDIN_CLIENT_SECRET"`
	LinkedInRedirectURI  string `env:"SPOOL_HUB_AUTH_LINKEDIN_REDIRECT_URI"`
	LinkedInScopes       string `env:"SPOOL_HUB_AUTH_LINKEDIN_SCOPES" envDefault:"openid profile email"`

	// xAI's endpoints are cnf only (narrative §1: never baked in Go); they
	// are required while xai is listed.
	XAIClientID     string `env:"SPOOL_HUB_AUTH_XAI_CLIENT_ID"`
	XAIClientSecret string `env:"SPOOL_HUB_AUTH_XAI_CLIENT_SECRET"`
	XAIRedirectURI  string `env:"SPOOL_HUB_AUTH_XAI_REDIRECT_URI"`
	XAIScopes       string `env:"SPOOL_HUB_AUTH_XAI_SCOPES" envDefault:"openid profile email"`
	XAIAuthURL      string `env:"SPOOL_HUB_AUTH_XAI_AUTH_URL"`
	XAITokenURL     string `env:"SPOOL_HUB_AUTH_XAI_TOKEN_URL"`
	XAIUserinfoURL  string `env:"SPOOL_HUB_AUTH_XAI_USERINFO_URL"`

	// Env is SPOOL_HUB_ENV (lde|dev|prd), passed in by the caller.
	Env string `env:"-"`

	enabled []string
}

// minSessionKeyLen is 256 bits of key material.
const minSessionKeyLen = 32

// Load reads the process environment. hubEnv is SPOOL_HUB_ENV.
func Load(hubEnv string) (*Config, error) { return load(hubEnv, env.Options{}) }

// LoadFrom reads only the given map (tests, the auth-demo).
func LoadFrom(hubEnv string, vars map[string]string) (*Config, error) {
	return load(hubEnv, env.Options{Environment: vars})
}

func load(hubEnv string, o env.Options) (*Config, error) {
	var c Config
	if err := env.ParseWithOptions(&c, o); err != nil {
		return nil, fmt.Errorf("parse auth config: %w", err)
	}
	c.Env = hubEnv
	if err := c.validate(); err != nil {
		return nil, err
	}
	return &c, nil
}

// Enabled lists the configured providers in SPOOL_HUB_AUTH_PROVIDERS order.
func (c *Config) Enabled() []string { return append([]string(nil), c.enabled...) }

func (c *Config) validate() error {
	seen := map[string]bool{}
	for _, p := range strings.Split(c.Providers, ",") {
		p = strings.ToLower(strings.TrimSpace(p))
		switch {
		case p == "" || seen[p]:
			continue
		case plannedProviders[p]:
			return fmt.Errorf("SPOOL_HUB_AUTH_PROVIDERS: %q is planned (spec 010) but not implemented", p)
		case !knownProviders[p]:
			return fmt.Errorf("SPOOL_HUB_AUTH_PROVIDERS: unknown provider %q", p)
		}
		seen[p] = true
		c.enabled = append(c.enabled, p)
	}
	if len(c.enabled) == 0 {
		return nil // auth off: nothing else is required
	}
	if len(c.SessionKey) < minSessionKeyLen || isPlaceholder(c.SessionKey) {
		return fmt.Errorf("SPOOL_HUB_AUTH_SESSION_KEY must be set to at least %d bytes (no default)", minSessionKeyLen)
	}
	if err := checkURL("SPOOL_HUB_AUTH_APP_URL", c.AppURL, c.requireHTTPS()); err != nil {
		return err
	}
	if c.SessionTTL <= 0 || c.StateTTL <= 0 {
		return fmt.Errorf("SPOOL_HUB_AUTH_SESSION_TTL and SPOOL_HUB_AUTH_STATE_TTL must be positive")
	}
	if c.CookieName == "" {
		return fmt.Errorf("SPOOL_HUB_AUTH_COOKIE_NAME must not be empty")
	}
	if c.IdPBaseURL != "" {
		if c.Env == "prd" {
			return fmt.Errorf("SPOOL_HUB_AUTH_IDP_BASE_URL is refused in prd")
		}
		if err := checkURL("SPOOL_HUB_AUTH_IDP_BASE_URL", c.IdPBaseURL, false); err != nil {
			return err
		}
	}
	for _, p := range c.enabled {
		id, secret, redirect := c.creds(p)
		pre := "SPOOL_HUB_AUTH_" + strings.ToUpper(p) + "_"
		if id == "" || isPlaceholder(id) {
			return fmt.Errorf("%sCLIENT_ID must be set to a real value while %s is enabled (no default)", pre, p)
		}
		if secret == "" || isPlaceholder(secret) {
			return fmt.Errorf("%sCLIENT_SECRET must be set to a real value while %s is enabled (no default)", pre, p)
		}
		if err := checkURL(pre+"REDIRECT_URI", redirect, c.requireHTTPS()); err != nil {
			return err
		}
		u, _ := url.Parse(redirect)
		if want := RoutePrefix + p + "/callback"; u.Path != want {
			return fmt.Errorf("%sREDIRECT_URI %q must have the path %s", pre, redirect, want)
		}
		if err := c.validateProvider(p); err != nil {
			return err
		}
	}
	return nil
}

// validateProvider holds the per-provider rules beyond id/secret/redirect.
func (c *Config) validateProvider(p string) error {
	switch p {
	case ProviderMicrosoft:
		t := strings.TrimSpace(c.MicrosoftTenant)
		if t == "" || isPlaceholder(t) || strings.ContainsAny(t, "/?#") {
			return fmt.Errorf("SPOOL_HUB_AUTH_MICROSOFT_TENANT %q must be an Entra tenant segment", t)
		}
		if t != microsoftConsumers && !c.MicrosoftTrustEmail {
			return fmt.Errorf("SPOOL_HUB_AUTH_MICROSOFT_TENANT=%q accepts work accounts whose email is unverified; "+
				"use %q or set SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL=true (spec 010 OQ-I1)", t, microsoftConsumers)
		}
	case ProviderLinkedIn:
		// spec 019 FR-L2: without openid there is no userinfo and without
		// email no verified address, so every sign-in would fail.
		if !hasScopes(c.LinkedInScopes, "openid", "email") {
			return fmt.Errorf("SPOOL_HUB_AUTH_LINKEDIN_SCOPES %q must include openid and email (spec 019 FR-L2)", c.LinkedInScopes)
		}
	case ProviderXAI:
		for name, v := range map[string]string{"SPOOL_HUB_AUTH_XAI_AUTH_URL": c.XAIAuthURL,
			"SPOOL_HUB_AUTH_XAI_TOKEN_URL": c.XAITokenURL, "SPOOL_HUB_AUTH_XAI_USERINFO_URL": c.XAIUserinfoURL} {
			// endpoints are always TLS, even in lde (the fake IdP override
			// replaces them wholesale)
			if err := checkURL(name, v, true); err != nil {
				return err
			}
		}
	}
	return nil
}

// hasScopes reports whether the space-separated scope list holds every want.
func hasScopes(list string, want ...string) bool {
	have := map[string]bool{}
	for _, s := range strings.Fields(list) {
		have[s] = true
	}
	for _, w := range want {
		if !have[w] {
			return false
		}
	}
	return true
}

// requireHTTPS: dev and prd are TLS only; lde and tests may use plain http.
func (c *Config) requireHTTPS() bool { return c.Env == "dev" || c.Env == "prd" }

func (c *Config) creds(p string) (id, secret, redirect string) {
	switch p {
	case ProviderGoogle:
		return c.GoogleClientID, c.GoogleClientSecret, c.GoogleRedirectURI
	case ProviderFacebook:
		return c.FacebookClientID, c.FacebookClientSecret, c.FacebookRedirectURI
	case ProviderMicrosoft:
		return c.MicrosoftClientID, c.MicrosoftClientSecret, c.MicrosoftRedirectURI
	case ProviderLinkedIn:
		return c.LinkedInClientID, c.LinkedInClientSecret, c.LinkedInRedirectURI
	case ProviderXAI:
		return c.XAIClientID, c.XAIClientSecret, c.XAIRedirectURI
	}
	return "", "", ""
}

// isPlaceholder recognises the cnf stand-ins ("PLACEHOLDER-…") that hold a
// slot until the provider apps are registered.
func isPlaceholder(v string) bool { return strings.Contains(strings.ToUpper(v), "PLACEHOLDER") }

func checkURL(name, raw string, https bool) error {
	if raw == "" || isPlaceholder(raw) {
		return fmt.Errorf("%s must be set (no default)", name)
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return fmt.Errorf("%s %q must be an absolute http(s) URL", name, raw)
	}
	if https && u.Scheme != "https" {
		return fmt.Errorf("%s %q must be https in dev/prd", name, raw)
	}
	return nil
}
