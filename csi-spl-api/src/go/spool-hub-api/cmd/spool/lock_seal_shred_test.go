package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// SPL-5137: the operator of a box sealed with its clear key left behind still
// gets the code, is told what state the box is in, and sees a non-zero exit.
func TestLockSealShowsTheCodeWhenShredFails(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root opens a 0400 file for writing, so shred does not fail here")
	}
	e := newLockEnv(t)
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(e.cfg.KeysDir, "box-"+e.cfg.BoxID+".key")
	if err := os.WriteFile(path, []byte(base64.StdEncoding.EncodeToString(priv)), 0o400); err != nil {
		t.Fatal(err)
	}
	rc, out, errOut := e.run(t, []string{ltSecret}, "seal")
	if rc == 0 {
		t.Fatalf("seal rc 0 with the clear key left behind; stderr %q", errOut)
	}
	if !codeRe.MatchString(out) {
		t.Fatalf("no recovery code on stdout: %q", out)
	}
	for _, want := range []string{"the box IS sealed", "still on disk", "sealed, but the clear box key was not removed"} {
		if !strings.Contains(errOut, want) {
			t.Fatalf("stderr %q does not say %q", errOut, want)
		}
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the clear key was expected to stay: %v", err)
	}
}
