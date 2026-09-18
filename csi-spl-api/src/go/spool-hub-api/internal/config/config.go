// Package config loads the spool's runtime configuration from the environment,
// failing fast on a malformed value and resolving documented defaults. It
// follows the pas-psf pattern (caarlos0/env), scoped to the on-box spool.
package config

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/caarlos0/env/v10"
)

// Config is the resolved on-box spool configuration. Every value is an env var
// with a documented default (Constitution II/VI); nothing else is baked in.
type Config struct {
	// SpoolRoot is the on-box message tree. Default mirrors the ysg-box reference.
	SpoolRoot string `env:"SPOOL_ROOT" envDefault:"/var/tmp/claude/msgs"`
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
	return &c, nil
}

// FilesDir is the shared content-addressed blob store.
func (c *Config) FilesDir() string { return filepath.Join(c.SpoolRoot, "files") }
