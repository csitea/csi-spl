package hubclient

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

// TestNFR002_LegacyKeyInsideRootWarnsAndStillLoads: a box keyed before keygen
// refused a keys dir inside $SPOOL_ROOT (dab3161) keeps its identity, and the
// operator is told, once per Client, how to move the key out. CONTROL: a keys
// dir outside the root loads silently.
func TestNFR002_LegacyKeyInsideRootWarnsAndStillLoads(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "spool")
	if err := os.MkdirAll(root, 0o775); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, keys string
		warn       bool
	}{
		{"legacy-inside-root", filepath.Join(root, "keys"), true},
		{"outside-root", filepath.Join(base, "home", ".spool", "keys"), false},
	}
	for _, tc := range cases {
		cfg := &config.Config{SpoolRoot: root, KeysDir: tc.keys, BoxID: "box-a"}
		// the legacy fixture: written straight to disk, as keygen did before it refused
		if _, err := sign.GenerateKey(tc.keys, "box-a", true); err != nil {
			t.Fatal(err)
		}
		var buf bytes.Buffer
		c := New(cfg)
		c.Warn = &buf
		for i := 0; i < 2; i++ {
			b, priv, err := c.box()
			if err != nil || b != "box-a" || len(priv) == 0 {
				t.Fatalf("%s: the key must still load: box=%q len=%d err=%v", tc.name, b, len(priv), err)
			}
		}
		out := buf.String()
		if !tc.warn {
			if out != "" {
				t.Errorf("%s: CONTROL: unexpected warning %q", tc.name, out)
			}
			continue
		}
		for _, want := range []string{"WARNING", "box-a", tc.keys, "do_repair_spool_keys", "DRY_RUN=0"} {
			if !strings.Contains(out, want) {
				t.Errorf("%s: warning lacks %q: %q", tc.name, want, out)
			}
		}
		if n := strings.Count(out, "WARNING"); n != 1 {
			t.Errorf("%s: warned %d times over two loads, want once", tc.name, n)
		}
	}
}
