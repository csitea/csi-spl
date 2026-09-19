package auth

import (
	"fmt"
	"time"

	"github.com/caarlos0/env/v10"
)

// NativeConfig is spec 015's email + password sign-in configuration. Native
// sign-in is OFF unless SPOOL_HUB_AUTH_NATIVE_ENABLED=true (FR-013). The
// session key, cookie and APP_URL are the 010 Config's (one session).
type NativeConfig struct {
	Enabled        bool `env:"SPOOL_HUB_AUTH_NATIVE_ENABLED" envDefault:"false"`
	VerifyRequired bool `env:"SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED" envDefault:"true"`
	// DebugTokens returns plaintext tokens in the body (lde/dev only, FR-011).
	DebugTokens      bool          `env:"SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS" envDefault:"false"`
	PasswordMinLen   int           `env:"SPOOL_HUB_AUTH_NATIVE_PASSWORD_MIN_LEN" envDefault:"12"`
	Argon2MemoryKiB  uint32        `env:"SPOOL_HUB_AUTH_NATIVE_ARGON2_MEMORY_KIB" envDefault:"19456"`
	Argon2Iterations uint32        `env:"SPOOL_HUB_AUTH_NATIVE_ARGON2_ITERATIONS" envDefault:"2"`
	VerifyTTL        time.Duration `env:"SPOOL_HUB_AUTH_NATIVE_VERIFY_TTL" envDefault:"24h"`
	ResetTTL         time.Duration `env:"SPOOL_HUB_AUTH_NATIVE_RESET_TTL" envDefault:"1h"`
	// Per-account mail floor, counted in the database (FR-006a).
	MailMinInterval time.Duration `env:"SPOOL_HUB_AUTH_NATIVE_MAIL_MIN_INTERVAL" envDefault:"60s"`
	MailMaxPerDay   int           `env:"SPOOL_HUB_AUTH_NATIVE_MAIL_MAX_PER_DAY" envDefault:"5"`
	// In-process limiter (FR-006b): attempts per RateWindow.
	RateWindow    time.Duration `env:"SPOOL_HUB_AUTH_NATIVE_RATE_WINDOW" envDefault:"15m"`
	LoginPerEmail int           `env:"SPOOL_HUB_AUTH_NATIVE_LOGIN_PER_EMAIL" envDefault:"10"`
	LoginPerIP    int           `env:"SPOOL_HUB_AUTH_NATIVE_LOGIN_PER_IP" envDefault:"30"`
	FormPerIP     int           `env:"SPOOL_HUB_AUTH_NATIVE_FORM_PER_IP" envDefault:"10"`
	// TrustedProxyHops is how many proxies we trust in front of the hub (Cloud
	// Run front end, Hosting rewrite): the client IP is the hops-th
	// X-Forwarded-For entry from the right. 0 = the TCP peer is the client.
	TrustedProxyHops int `env:"SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS" envDefault:"0"`

	Env string `env:"-"`
}

// OWASP 2023 argon2id minimum (m=19 MiB, t=2, p=1); dev/prd refuse less.
const (
	minArgon2MemoryKiB  = 19456
	minArgon2Iterations = 2
	minPasswordLen      = 8
)

// LoadNative reads the process environment. hubEnv is SPOOL_HUB_ENV.
func LoadNative(hubEnv string) (*NativeConfig, error) { return loadNative(hubEnv, env.Options{}) }

// LoadNativeFrom reads only vars (tests).
func LoadNativeFrom(hubEnv string, vars map[string]string) (*NativeConfig, error) {
	return loadNative(hubEnv, env.Options{Environment: vars})
}

func loadNative(hubEnv string, o env.Options) (*NativeConfig, error) {
	var c NativeConfig
	if err := env.ParseWithOptions(&c, o); err != nil {
		return nil, fmt.Errorf("parse native auth config: %w", err)
	}
	c.Env = hubEnv
	if err := c.validate(); err != nil {
		return nil, err
	}
	return &c, nil
}

func (c *NativeConfig) validate() error {
	if !c.Enabled {
		return nil
	}
	deployed := c.Env == "dev" || c.Env == "prd"
	if c.DebugTokens && c.Env != "lde" && c.Env != "dev" {
		return fmt.Errorf("SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS is refused in %q (lde/dev only)", c.Env)
	}
	if !c.VerifyRequired && c.Env != "lde" {
		return fmt.Errorf("SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED=false is refused in %q (lde only)", c.Env)
	}
	if deployed && (c.Argon2MemoryKiB < minArgon2MemoryKiB || c.Argon2Iterations < minArgon2Iterations) {
		return fmt.Errorf("SPOOL_HUB_AUTH_NATIVE_ARGON2_* below m=%d,t=%d is refused in dev/prd", minArgon2MemoryKiB, minArgon2Iterations)
	}
	if c.Argon2MemoryKiB < 8 || c.Argon2Iterations < 1 || c.Argon2MemoryKiB > 1<<20 {
		return fmt.Errorf("SPOOL_HUB_AUTH_NATIVE_ARGON2_* out of range")
	}
	if c.PasswordMinLen < minPasswordLen || c.PasswordMinLen > 128 {
		return fmt.Errorf("SPOOL_HUB_AUTH_NATIVE_PASSWORD_MIN_LEN must be %d..128", minPasswordLen)
	}
	if c.VerifyTTL <= 0 || c.ResetTTL <= 0 || c.RateWindow <= 0 || c.MailMinInterval < 0 {
		return fmt.Errorf("SPOOL_HUB_AUTH_NATIVE_* durations must be positive")
	}
	if c.MailMaxPerDay < 1 || c.LoginPerEmail < 1 || c.LoginPerIP < 1 || c.FormPerIP < 1 || c.TrustedProxyHops < 0 {
		return fmt.Errorf("SPOOL_HUB_AUTH_NATIVE_* limits must be positive")
	}
	return nil
}

func (c *NativeConfig) argon2() Argon2Params {
	return Argon2Params{MemoryKiB: c.Argon2MemoryKiB, Iterations: c.Argon2Iterations}
}
