package config

import (
	"os"
	"path/filepath"
	"testing"
)

// TestFR009_KeysDirMustBeOutsideRoot: FR-009 / NFR-002 put the box private key
// strictly outside $SPOOL_ROOT. Before the fix nothing checked it, and
// `SPOOL_KEYS_DIR=$SPOOL_ROOT/keys spool keygen` exited 0 with the key inside
// the shared root.
func TestFR009_KeysDirMustBeOutsideRoot(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "spool")
	if err := os.MkdirAll(root, 0o775); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "via-link")
	if err := os.Symlink(root, link); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, keys string
		ok         bool
	}{
		{"outside", filepath.Join(base, "keys"), true},
		{"sibling-prefix", root + "-keys", true},
		{"root-itself", root, false},
		{"inside", filepath.Join(root, "keys"), false},
		{"inside-dotdot", filepath.Join(base, "x", "..", "spool", "keys"), false},
		{"inside-via-symlink", filepath.Join(link, "keys"), false},
	}
	for _, c := range cases {
		cfg := &Config{SpoolRoot: root, KeysDir: c.keys}
		err := cfg.CheckKeysDir()
		if (err == nil) != c.ok {
			t.Errorf("%s: KeysDir=%s err=%v, want ok=%v", c.name, c.keys, err, c.ok)
		}
	}
	// the root reached through a symlink, key dir given by the real path
	cfg := &Config{SpoolRoot: link, KeysDir: filepath.Join(root, "keys")}
	if cfg.CheckKeysDir() == nil {
		t.Errorf("symlinked SpoolRoot: key dir inside the real root was accepted")
	}
}
