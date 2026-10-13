package logging_test

import (
	"testing"
	"spool-hub-api/internal/config"
	"spool-hub-api/internal/logging"
)

func TestNew(t *testing.T) {
	cfg := &config.Config{LogLevel: "info", LogFormat: "console"}
	log := logging.New(cfg)

	// Test that the logger is not nil and has the correct service tag.
	hook := &testHook{}
	log = log.Hook(hook)

	log.Info().Msg("test")

	if hook.last == nil {
		t.Fatal("expected a log event")
	}
	if service, ok := hook.last.Get("service").(string); !ok || service != "spool" {
		t.Errorf("service: got %v, want 'spool'", service)
	}
}

type testHook struct {
	last *zerolog.Event
}

func (h *testHook) Run(e *zerolog.Event, _ zerolog.Level, _ string) {
	h.last = e
}