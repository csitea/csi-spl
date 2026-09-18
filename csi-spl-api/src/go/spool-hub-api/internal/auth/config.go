// Package auth is the hub's browser sign-in (spec 010-spool-social-auth):
// Google (OIDC) and Facebook (OAuth 2.0 + Graph) authorization-code login for
// the WUI, a signed CSRF `state` bound to a browser cookie, a server-side code
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
	ProviderGoogle   = "google"
	ProviderFacebook = "facebook"
)

// plannedProviders are named by SPEC-spool-social-auth.md §1 on the same
// rails but not built yet: listing one fails fast instead of silently
// advertising a button that 404s.
var plannedProviders = map[string]bool{"microsoft": true, "linkedin": true, "xai": true}

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
	// IdPBaseURL points BOTH providers at one fake IdP (fakeidp: lde, tests,
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
		case p != ProviderGoogle && p != ProviderFacebook:
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
	}
	return nil
}

// requireHTTPS: dev and prd are TLS only; lde and tests may use plain http.
func (c *Config) requireHTTPS() bool { return c.Env == "dev" || c.Env == "prd" }

func (c *Config) creds(p string) (id, secret, redirect string) {
	switch p {
	case ProviderGoogle:
		return c.GoogleClientID, c.GoogleClientSecret, c.GoogleRedirectURI
	case ProviderFacebook:
		return c.FacebookClientID, c.FacebookClientSecret, c.FacebookRedirectURI
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
