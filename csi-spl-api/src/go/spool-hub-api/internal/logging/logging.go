// Package logging builds the spool's structured logger (zerolog): RFC3339
// timestamps, a service tag, level from config, and human console output
// for the CLI or JSON when deployed.
package logging

import (
	"bytes"
	"io"
	"os"
	"sync"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// zerolog.TimeFieldFormat is a package GLOBAL, so setting it on every New was
// a write that two concurrent callers could make at once - a real data race,
// dormant only because nothing built a logger from two goroutines until the
// notify queue did. The value never varies, so it is set once.
var timeFormatOnce sync.Once

// New returns a logger configured from cfg. It never fails: an unknown level
// falls back to info. Safe to call concurrently.
func New(cfg *config.Config) zerolog.Logger {
	return newTo(cfg, os.Stderr)
}

// newTo is New writing to w, so a test can read the lines.
func newTo(cfg *config.Config, w io.Writer) zerolog.Logger {
	timeFormatOnce.Do(func() { zerolog.TimeFieldFormat = time.RFC3339 })
	lvl, err := zerolog.ParseLevel(cfg.LogLevel)
	if err != nil {
		lvl = zerolog.InfoLevel
	}
	base := zerolog.New(severityWriter{w})
	if cfg.LogFormat != "json" {
		base = zerolog.New(zerolog.ConsoleWriter{Out: w, TimeFormat: time.RFC3339})
	}
	return base.Level(lvl).With().Timestamp().Str("service", "spool").Logger()
}

// severities maps a zerolog level to its Cloud Logging severity. Cloud Run
// reads only `severity` from a JSON line, never `level`, so without it an
// error line is invisible to severity>=ERROR filters, log alerts and Error
// Reporting (SPL-4473). A level not in the map (no level) gets none: DEFAULT.
var severities = map[zerolog.Level][]byte{
	zerolog.TraceLevel: []byte(`{"severity":"DEBUG",`),
	zerolog.DebugLevel: []byte(`{"severity":"DEBUG",`),
	zerolog.InfoLevel:  []byte(`{"severity":"INFO",`),
	zerolog.WarnLevel:  []byte(`{"severity":"WARNING",`),
	zerolog.ErrorLevel: []byte(`{"severity":"ERROR",`),
	zerolog.FatalLevel: []byte(`{"severity":"CRITICAL",`),
	zerolog.PanicLevel: []byte(`{"severity":"ALERT",`),
}

// severityWriter puts the level's severity first in each JSON line, unless
// the line sets severity itself (.Str("severity", "CRITICAL")): that one
// wins, and the line never carries the key twice. Inside a JSON string a
// quote is escaped, so `{"severity":` or `,"severity":` only ever matches a
// key. zerolog's own `level` stays, for the readers that query it.
type severityWriter struct{ w io.Writer }

func (s severityWriter) Write(p []byte) (int, error) { return s.w.Write(p) }

func (s severityWriter) WriteLevel(l zerolog.Level, p []byte) (int, error) {
	head, ok := severities[l]
	if !ok || len(p) < 2 || p[0] != '{' || p[1] == '}' ||
		bytes.HasPrefix(p, []byte(`{"severity":`)) || bytes.Contains(p, []byte(`,"severity":`)) {
		return s.w.Write(p)
	}
	line := make([]byte, 0, len(head)+len(p))
	line = append(append(line, head...), p[1:]...)
	if _, err := s.w.Write(line); err != nil {
		return 0, err
	}
	return len(p), nil
}
