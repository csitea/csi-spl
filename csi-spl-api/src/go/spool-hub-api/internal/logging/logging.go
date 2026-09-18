// Package logging builds the spool's structured logger (zerolog), following the
// pas-psf convention: RFC3339 timestamps, a service tag, level from config, and
// human console output for the CLI or JSON when deployed.
package logging

import (
	"os"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// New returns a logger configured from cfg. It never fails: an unknown level
// falls back to info.
func New(cfg *config.Config) zerolog.Logger {
	zerolog.TimeFieldFormat = time.RFC3339
	lvl, err := zerolog.ParseLevel(cfg.LogLevel)
	if err != nil {
		lvl = zerolog.InfoLevel
	}
	var w = os.Stderr
	base := zerolog.New(w)
	if cfg.LogFormat != "json" {
		base = zerolog.New(zerolog.ConsoleWriter{Out: w, TimeFormat: time.RFC3339})
	}
	return base.Level(lvl).With().Timestamp().Str("service", "spool").Logger()
}
