// Package testkit provides shared fixtures for the spool's tests: a throwaway
// $SPOOL_ROOT/keys/pins triple and a box keygen+pin helper. It imports only config and sign, so
// it never creates an import cycle with the packages under test.
package testkit

import (
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

// NewConfig returns a Config rooted in a fresh per-test temp dir, with keys held
// strictly outside the spool root (as in production).
func NewConfig(t *testing.T) *config.Config {
	t.Helper()
	root := t.TempDir()
	return &config.Config{
		SpoolRoot: filepath.Join(root, "msgs"),
		KeysDir:   filepath.Join(root, "keys"),
		PinsDir:   filepath.Join(root, "msgs", "pins"),
		LogLevel:  "error",
		LogFormat: "console",
	}
}

// KeygenPin creates the keypair of box id and pins its public key. Local mode
// never uses it; it exists for the optional key ceremony and hub mode.
func KeygenPin(t *testing.T, cfg *config.Config, id string) {
	t.Helper()
	pub, err := sign.GenerateKey(cfg.KeysDir, id, false)
	if err != nil {
		t.Fatalf("keygen %s: %v", id, err)
	}
	if err := sign.Pin(cfg.PinsDir, id, pub, false); err != nil {
		t.Fatalf("pin %s: %v", id, err)
	}
}
