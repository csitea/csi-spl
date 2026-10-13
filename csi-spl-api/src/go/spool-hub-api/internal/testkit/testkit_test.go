package testkit_test

import (
	"testing"
	"spool-hub-api/internal/testkit"
)

func TestNewConfig(t *testing.T) {
	cfg := testkit.NewConfig(t)

	if cfg.SpoolRoot == "" {
		t.Error("SpoolRoot is empty")
	}
	if cfg.KeysDir == "" {
		t.Error("KeysDir is empty")
	}
	if cfg.PinsDir == "" {
		t.Error("PinsDir is empty")
	}
}

func TestAgents(t *testing.T) {
	cfg := testkit.NewConfig(t)
	testkit.Agents(t, cfg, "test-agent")

	// Test that the agent directories were created.
	for _, d := range []string{"inbox", "outbox", "archive"} {
		if _, err := os.Stat(filepath.Join(cfg.SpoolRoot, "test-agent", d)); err != nil {
			t.Fatalf("stat %s: %v", d, err)
		}
	}
}