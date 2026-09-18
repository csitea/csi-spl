// Package config loads the spool's runtime configuration from the environment,
// failing fast on a malformed value and resolving documented defaults. It
// follows the pas-psf pattern (caarlos0/env), scoped to the on-box spool.
package config

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/caarlos0/env/v10"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// Config is the resolved on-box spool configuration. Every value is an env var
// with a documented default (Constitution II/VI); nothing else is baked in.
type Config struct {
	// SpoolRoot is the on-box message tree: a pre-created system dir, separate
	// from any other tool's message tree (owner decision 2026-09-18).
	SpoolRoot string `env:"SPOOL_ROOT" envDefault:"/var/spool-hub"`
	// KeysDir holds the box PRIVATE key, strictly outside SpoolRoot. Empty here
	// means "$HOME/.spool/keys", resolved in Load.
	KeysDir string `env:"SPOOL_KEYS_DIR"`
	// PinsDir holds shared PUBLIC box pins. Empty here means "<SpoolRoot>/pins".
	PinsDir string `env:"SPOOL_PINS_DIR"`
	// BoxID names this box for its keypair and hub routing. No default: local
	// mode never needs it, and keygen/pin fail fast when it is unset.
	BoxID string `env:"SPOOL_BOX_ID"`
	// LogLevel is a zerolog level name (trace|debug|info|warn|error).
	LogLevel string `env:"SPOOL_LOG_LEVEL" envDefault:"info"`
	// LogFormat is "console" (CLI) or "json" (deployed).
	LogFormat string `env:"SPOOL_LOG_FORMAT" envDefault:"console"`
	// HubURL switches the box into hub mode (spec 003): https://<tenant>.<domain>.
	// Unset = the unchanged local 002 path.
	HubURL string `env:"SPOOL_HUB_URL"`
	// TenantRootKey is the path to the tenant root PRIVATE key used by spool-pin
	// to POST/DELETE /v1/pins. Empty = local pin file only (002).
	TenantRootKey string `env:"SPOOL_TENANT_ROOT_KEY"`
	// MirrorLocal also hub-sends same-box mail: unset/0/false (default) or 1/true.
	MirrorLocal string `env:"SPOOL_MIRROR_LOCAL"`
}

// Load parses the environment and resolves defaults that depend on $HOME or
// SpoolRoot. It fails fast on an unparseable env value.
func Load() (*Config, error) {
	var c Config
	if err := env.Parse(&c); err != nil {
		return nil, fmt.Errorf("parse spool config: %w", err)
	}
	if c.SpoolRoot == "" {
		return nil, fmt.Errorf("SPOOL_ROOT resolved empty")
	}
	if c.KeysDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("resolve $HOME for keys dir: %w", err)
		}
		c.KeysDir = filepath.Join(home, ".spool", "keys")
	}
	if c.PinsDir == "" {
		c.PinsDir = filepath.Join(c.SpoolRoot, "pins")
	}
	if c.HubURL != "" {
		// Local mode ignores the mirror flag (trust-modes §6), so only hub mode
		// fails fast on an illegal value.
		if _, err := c.Mirror(); err != nil {
			return nil, err
		}
		u, err := url.Parse(c.HubURL)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
			return nil, fmt.Errorf("SPOOL_HUB_URL %q must be an http(s) URL", c.HubURL)
		}
		// FR-002 / 004 T002: hub mode is a box identity; no silent empty box_id.
		if !msg.ValidBoxID(c.BoxID) {
			return nil, fmt.Errorf("SPOOL_BOX_ID must be a valid box id when SPOOL_HUB_URL is set")
		}
	}
	return &c, nil
}

// Mirror reports $SPOOL_MIRROR_LOCAL; any value but unset/0/false/1/true fails
// fast (trust-modes §6).
func (c *Config) Mirror() (bool, error) {
	switch strings.ToLower(c.MirrorLocal) {
	case "", "0", "false":
		return false, nil
	case "1", "true":
		return true, nil
	}
	return false, fmt.Errorf("SPOOL_MIRROR_LOCAL %q must be unset, 0, false, 1 or true", c.MirrorLocal)
}

// HubDir is the box's private hub state: roster cache, pending and rejected
// envelopes. Hidden, so the $SPOOL_ROOT/*/ agent scan never sees it.
func (c *Config) HubDir() string { return filepath.Join(c.SpoolRoot, ".hub") }

// Hub is the hub process configuration (`spool serve`, spec 003). The names are
// the infra lane's (csi-spl-cnf all.env.yaml env.hub); nothing is baked in.
type Hub struct {
	ListenAddr string `env:"SPOOL_HUB_LISTEN_ADDR" envDefault:":8080"`
	Port       string `env:"PORT"` // Cloud Run: wins over ListenAddr
	Env        string `env:"SPOOL_HUB_ENV"`
	DBDSN      string `env:"SPOOL_HUB_DB_DSN"`
	// Exactly one blob store: a GCS bucket (prod) or a local dir (tests / lde).
	FilesBucket string `env:"SPOOL_HUB_FILES_BUCKET"`
	FilesDir    string `env:"SPOOL_HUB_FILES_DIR"`
	// TenantHostPattern is "{tenant}.<fqdn>"; the tenant comes from the Host.
	TenantHostPattern string        `env:"SPOOL_HUB_TENANT_HOST_PATTERN"`
	AllowTextOnly     bool          `env:"SPOOL_HUB_ALLOW_TEXT_ONLY_WHEN_FILE_MISSING" envDefault:"false"`
	QueueTTL          time.Duration `env:"SPOOL_HUB_QUEUE_TTL" envDefault:"168h"`
	QueueMaxPerBox    int           `env:"SPOOL_HUB_QUEUE_MAX_PER_BOX" envDefault:"1000"`
	RetentionAlerts   time.Duration `env:"SPOOL_HUB_RETENTION_ALERTS" envDefault:"168h"`
	RetentionChannels time.Duration `env:"SPOOL_HUB_RETENTION_CHANNELS" envDefault:"720h"`
	HelloSkew         time.Duration `env:"SPOOL_HUB_HELLO_SKEW" envDefault:"300s"`
	UploadTokenTTL    time.Duration `env:"SPOOL_HUB_UPLOAD_TOKEN_TTL" envDefault:"5m"`
	// Quota fields: 0 = unlimited (tests / internal). Production values live in cnf.
	QuotaMessagesPerMonth int           `env:"SPOOL_HUB_QUOTA_MESSAGES_PER_MONTH" envDefault:"0"`
	QuotaPins             int           `env:"SPOOL_HUB_QUOTA_PINS" envDefault:"0"`
	QuotaFileBytes        int64         `env:"SPOOL_HUB_QUOTA_FILE_BYTES" envDefault:"0"`
	BillingGrace          time.Duration `env:"SPOOL_HUB_BILLING_GRACE" envDefault:"168h"`
	GracefulShutdown      time.Duration `env:"SPOOL_HUB_GRACEFUL_SHUTDOWN" envDefault:"10s"`
	LogLevel              string        `env:"SPOOL_HUB_LOG_LEVEL" envDefault:"info"`
	LogFormat             string        `env:"SPOOL_HUB_LOG_FORMAT" envDefault:"json"`
	MigrationsDir         string        `env:"SPOOL_HUB_MIGRATIONS_DIR"`
}

// LoadHub parses the hub environment and fails fast on a missing or
// contradictory value.
func LoadHub() (*Hub, error) {
	var h Hub
	if err := env.Parse(&h); err != nil {
		return nil, fmt.Errorf("parse hub config: %w", err)
	}
	if h.Port != "" {
		h.ListenAddr = ":" + h.Port
	}
	if h.DBDSN == "" {
		return nil, fmt.Errorf("SPOOL_HUB_DB_DSN must be set (no default)")
	}
	if (h.FilesBucket == "") == (h.FilesDir == "") {
		return nil, fmt.Errorf("exactly one of SPOOL_HUB_FILES_BUCKET or SPOOL_HUB_FILES_DIR must be set")
	}
	if !strings.HasPrefix(h.TenantHostPattern, "{tenant}.") || len(h.TenantHostPattern) <= len("{tenant}.") {
		return nil, fmt.Errorf("SPOOL_HUB_TENANT_HOST_PATTERN %q must look like {tenant}.<fqdn> (no default)", h.TenantHostPattern)
	}
	if h.QueueTTL <= 0 || h.HelloSkew <= 0 || h.UploadTokenTTL <= 0 || h.QueueMaxPerBox <= 0 ||
		h.RetentionAlerts <= 0 || h.RetentionChannels <= 0 || h.BillingGrace <= 0 {
		return nil, fmt.Errorf("hub durations and SPOOL_HUB_QUEUE_MAX_PER_BOX must be positive")
	}
	if h.QuotaMessagesPerMonth < 0 || h.QuotaPins < 0 || h.QuotaFileBytes < 0 {
		return nil, fmt.Errorf("hub quotas must be zero (unlimited) or positive")
	}
	return &h, nil
}

// FilesDir is the shared content-addressed blob store.
func (c *Config) FilesDir() string { return filepath.Join(c.SpoolRoot, "files") }
