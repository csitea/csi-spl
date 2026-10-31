package logging

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// TestNewLevel: the level comes from config, and an unknown one falls back
// to info rather than failing.
func TestNewLevel(t *testing.T) {
	for _, c := range []struct {
		level, format string
		want          zerolog.Level
	}{
		{"debug", "json", zerolog.DebugLevel},
		{"error", "console", zerolog.ErrorLevel},
		{"no-such-level", "json", zerolog.InfoLevel},
		{"", "console", zerolog.NoLevel},
	} {
		got := New(&config.Config{LogLevel: c.level, LogFormat: c.format}).GetLevel()
		if got != c.want {
			t.Errorf("New(level %q, format %q).GetLevel() = %v, want %v", c.level, c.format, got, c.want)
		}
	}
}

// TestNewConcurrent: New is safe to call from several goroutines (the race
// detector of run-all-tests.sh's full tier fails it otherwise).
func TestNewConcurrent(t *testing.T) {
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			New(&config.Config{LogLevel: "info", LogFormat: "json"})
		}()
	}
	wg.Wait()
	if zerolog.TimeFieldFormat != "2006-01-02T15:04:05Z07:00" {
		t.Fatalf("TimeFieldFormat = %q, want RFC3339", zerolog.TimeFieldFormat)
	}
}

// jsonLines logs through a JSON logger and returns each line decoded, keyed
// by its message, and the raw output.
func jsonLines(t *testing.T, log func(zerolog.Logger)) (map[string]map[string]any, string) {
	t.Helper()
	var buf bytes.Buffer
	log(newTo(&config.Config{LogLevel: "trace", LogFormat: "json"}, &buf))
	out := map[string]map[string]any{}
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("line %q is not JSON: %v", line, err)
		}
		msg, _ := m["message"].(string)
		out[msg] = m
	}
	return out, buf.String()
}

// TestJSONSeverity: Cloud Run reads only `severity`, never zerolog's `level`,
// so every JSON line carries the Cloud Logging severity of its level (SPL-4473).
func TestJSONSeverity(t *testing.T) {
	got, _ := jsonLines(t, func(l zerolog.Logger) {
		l.Trace().Msg("t")
		l.Debug().Msg("d")
		l.Info().Msg("i")
		l.Warn().Msg("w")
		l.Error().Msg("e")
	})
	for msg, want := range map[string]string{"t": "DEBUG", "d": "DEBUG", "i": "INFO", "w": "WARNING", "e": "ERROR"} {
		if sev := got[msg]["severity"]; sev != want {
			t.Errorf("%q line severity = %v, want %s (line %v)", msg, sev, want, got[msg])
		}
		if got[msg]["level"] == nil {
			t.Errorf("%q line lost its level field: %v", msg, got[msg])
		}
	}
}

// TestJSONSeverityExplicitWins: a call site that sets severity itself
// (.Str("severity", "CRITICAL") on an error) keeps it, and every line holds
// the key once: a duplicate key is ambiguous to a JSON reader.
func TestJSONSeverityExplicitWins(t *testing.T) {
	got, raw := jsonLines(t, func(l zerolog.Logger) {
		l.Error().Str("severity", "CRITICAL").Msg("crit")
		l.Warn().Str("severity", "WARNING").Msg("warn")
		l.Error().Str("note", `"severity":"x"`).Msg("quoted")
	})
	if sev := got["crit"]["severity"]; sev != "CRITICAL" {
		t.Errorf("crit severity = %v, want CRITICAL", sev)
	}
	if sev := got["quoted"]["severity"]; sev != "ERROR" {
		t.Errorf("a value that quotes the key still needs its own severity: got %v, want ERROR", sev)
	}
	for _, line := range strings.Split(strings.TrimSpace(raw), "\n") {
		if n := strings.Count(line, `"severity":`); n != 1 {
			t.Errorf("line has %d severity keys, want 1: %s", n, line)
		}
	}
}

// TestConsoleUnchanged: the console (CLI) format gets no severity field.
func TestConsoleUnchanged(t *testing.T) {
	var buf bytes.Buffer
	l := newTo(&config.Config{LogLevel: "info", LogFormat: "console"}, &buf)
	l.Error().Msg("boom")
	if out := buf.String(); strings.Contains(out, "severity") || !strings.Contains(out, "ERR") || !strings.Contains(out, "boom") {
		t.Errorf("console line = %q, want the plain ERR line with no severity", out)
	}
}

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("disk full") }

// TestSeverityWriterEdges: a line with no level gets no severity (Cloud
// Logging reads DEFAULT), a plain Write passes through, and a write error
// is returned rather than a byte count.
func TestSeverityWriterEdges(t *testing.T) {
	var buf bytes.Buffer
	if n, err := (severityWriter{&buf}).Write([]byte(`{"a":1}`)); n != 7 || err != nil || buf.String() != `{"a":1}` {
		t.Errorf("Write = %d, %v, %q; want it passed through", n, err, buf.String())
	}
	buf.Reset()
	l := newTo(&config.Config{LogLevel: "trace", LogFormat: "json"}, &buf)
	l.Log().Msg("plain")
	if strings.Contains(buf.String(), "severity") {
		t.Errorf("no-level line = %q, want no severity", buf.String())
	}
	if n, err := (severityWriter{failWriter{}}).WriteLevel(zerolog.ErrorLevel, []byte(`{"m":1}`)); n != 0 || err == nil {
		t.Errorf("WriteLevel on a failing writer = %d, %v; want 0 and the error", n, err)
	}
}
