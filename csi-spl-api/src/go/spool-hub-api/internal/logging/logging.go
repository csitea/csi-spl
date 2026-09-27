// Package logging builds the spool's structured logger (zerolog): RFC3339
// timestamps, a service tag, level from config, and human console output
// for the CLI or JSON when deployed.
package logging

import (
	"os"
	"sync"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// zerolog.TimeFieldFormat is a package GLOBAL, so setting it on every New was
// a write that two concurrent callers could make at once - a real data race,
// dormant only because nothing built a logger from two goroutines until the
// notify queue did (CLE-3435). The value never varies, so it is set once.
var timeFormatOnce sync.Once

// New returns a logger configured from cfg. It never fails: an unknown level
// falls back to info. Safe to call concurrently.
func New(cfg *config.Config) zerolog.Logger {
	timeFormatOnce.Do(func() { zerolog.TimeFieldFormat = time.RFC3339 })
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
