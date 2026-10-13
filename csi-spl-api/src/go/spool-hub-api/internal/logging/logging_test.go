package logging

import (
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
