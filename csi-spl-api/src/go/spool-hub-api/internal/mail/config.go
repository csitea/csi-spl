package mail

import (
	"fmt"
	"strings"
	"time"

	"github.com/caarlos0/env/v10"
	"github.com/rs/zerolog"
)

// Transports (SPOOL_HUB_MAIL_TRANSPORT).
const (
	TransportNone = "none"
	TransportLog  = "log"
	TransportSMTP = "smtp"
)

// Config is the relay configuration. No host, port or sender has a default:
// a relay pinned in code leaks one environment into every other (FR-010).
// SMTPPassword is a secret (Secret Manager slot csi-spl-hub-mail-smtp-password).
type Config struct {
	Transport    string        `env:"SPOOL_HUB_MAIL_TRANSPORT" envDefault:"none"`
	SMTPHost     string        `env:"SPOOL_HUB_MAIL_SMTP_HOST"`
	SMTPPort     int           `env:"SPOOL_HUB_MAIL_SMTP_PORT"`
	SMTPUser     string        `env:"SPOOL_HUB_MAIL_SMTP_USER"`
	SMTPPassword string        `env:"SPOOL_HUB_MAIL_SMTP_PASSWORD"`
	SMTPTLS      string        `env:"SPOOL_HUB_MAIL_SMTP_TLS" envDefault:"starttls"`
	From         string        `env:"SPOOL_HUB_MAIL_FROM"`
	FromName     string        `env:"SPOOL_HUB_MAIL_FROM_NAME"`
	Timeout      time.Duration `env:"SPOOL_HUB_MAIL_TIMEOUT" envDefault:"10s"`
	// Preflight is the relay check at hub start (spec 047 W7): off, warn
	// (log a CRITICAL line, keep serving) or require (refuse to start).
	Preflight string `env:"SPOOL_HUB_MAIL_PREFLIGHT" envDefault:"warn"`
}

// Load reads the process environment.
func Load() (*Config, error) { return load(env.Options{}) }

// LoadFrom reads only vars (tests).
func LoadFrom(vars map[string]string) (*Config, error) {
	return load(env.Options{Environment: vars})
}

func load(o env.Options) (*Config, error) {
	var c Config
	if err := env.ParseWithOptions(&c, o); err != nil {
		return nil, fmt.Errorf("parse mail config: %w", err)
	}
	c.Transport = strings.ToLower(strings.TrimSpace(c.Transport))
	c.Preflight = strings.ToLower(strings.TrimSpace(c.Preflight))
	if err := c.validate(); err != nil {
		return nil, err
	}
	return &c, nil
}

func placeholder(v string) bool { return strings.Contains(strings.ToUpper(v), "PLACEHOLDER") }

func (c *Config) validate() error {
	switch c.Preflight {
	case PreflightOff, PreflightWarn, PreflightRequire:
	default:
		return fmt.Errorf("SPOOL_HUB_MAIL_PREFLIGHT %q must be off, warn or require", c.Preflight)
	}
	switch c.Transport {
	case TransportNone, TransportLog:
		return nil
	case TransportSMTP:
	default:
		return fmt.Errorf("SPOOL_HUB_MAIL_TRANSPORT %q must be none, log or smtp", c.Transport)
	}
	if c.SMTPHost == "" || placeholder(c.SMTPHost) {
		return fmt.Errorf("SPOOL_HUB_MAIL_SMTP_HOST must be set while the transport is smtp (no default)")
	}
	if c.SMTPPort <= 0 || c.SMTPPort > 65535 {
		return fmt.Errorf("SPOOL_HUB_MAIL_SMTP_PORT must be set while the transport is smtp (no default)")
	}
	if c.From == "" || !strings.Contains(c.From, "@") || placeholder(c.From) {
		return fmt.Errorf("SPOOL_HUB_MAIL_FROM must be an address while the transport is smtp (no default)")
	}
	switch c.SMTPTLS {
	case TLSStartTLS, TLSImplicit:
	case TLSNone:
		if !isLoopbackHost(c.SMTPHost) {
			return fmt.Errorf("SPOOL_HUB_MAIL_SMTP_TLS=none is only allowed for a loopback catcher")
		}
	default:
		return fmt.Errorf("SPOOL_HUB_MAIL_SMTP_TLS %q must be starttls, implicit or none", c.SMTPTLS)
	}
	if c.SMTPUser != "" && (c.SMTPPassword == "" || placeholder(c.SMTPPassword)) {
		return fmt.Errorf("SPOOL_HUB_MAIL_SMTP_PASSWORD must be set when SPOOL_HUB_MAIL_SMTP_USER is (Secret Manager, no default)")
	}
	return nil
}

// Delivers reports whether a message will actually reach an inbox.
func (c *Config) Delivers() bool { return c != nil && c.Transport == TransportSMTP }

// Sender builds the Sender this config names.
func (c *Config) Sender(log zerolog.Logger) Sender {
	switch c.Transport {
	case TransportSMTP:
		return &SMTP{Host: c.SMTPHost, Port: c.SMTPPort, User: c.SMTPUser, Pass: c.SMTPPassword,
			From: c.From, FromName: c.FromName, Timeout: c.Timeout, TLSMode: c.SMTPTLS}
	case TransportLog:
		return Log{Logger: log.With().Str("component", "mail").Logger()}
	}
	return None{}
}
