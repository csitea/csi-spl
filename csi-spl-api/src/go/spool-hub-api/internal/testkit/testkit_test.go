package testkit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

// TestNewConfig: a fresh root per call, keys outside the spool root.
func TestNewConfig(t *testing.T) {
	a, b := NewConfig(t), NewConfig(t)
	if a.SpoolRoot == b.SpoolRoot {
		t.Fatalf("two configs share the spool root %s", a.SpoolRoot)
	}
	if strings.HasPrefix(a.KeysDir, a.SpoolRoot+string(filepath.Separator)) {
		t.Fatalf("KeysDir %s is inside SpoolRoot %s", a.KeysDir, a.SpoolRoot)
	}
	if !strings.HasPrefix(a.PinsDir, a.SpoolRoot) {
		t.Fatalf("PinsDir %s is not under SpoolRoot %s", a.PinsDir, a.SpoolRoot)
	}
}

// TestAgents: each id gets its inbox, outbox and archive.
func TestAgents(t *testing.T) {
	cfg := NewConfig(t)
	Agents(t, cfg, "c-001", "c-002")
	for _, id := range []string{"c-001", "c-002"} {
		for _, d := range []string{"inbox", "outbox", "archive"} {
			if fi, err := os.Stat(filepath.Join(cfg.SpoolRoot, id, d)); err != nil || !fi.IsDir() {
				t.Errorf("%s/%s: %v", id, d, err)
			}
		}
	}
}

// TestKeygenPin: the pinned public key is the one of the generated keypair.
func TestKeygenPin(t *testing.T) {
	cfg := NewConfig(t)
	KeygenPin(t, cfg, "box-a")
	priv, err := sign.LoadPrivate(cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	pub, err := sign.LoadPin(cfg.PinsDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	if !pub.Equal(priv.Public()) {
		t.Fatal("pinned key does not match the generated keypair")
	}
}
