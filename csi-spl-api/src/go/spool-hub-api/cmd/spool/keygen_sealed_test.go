package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestKeygenSealedBox: on a box sealed by the owner lock (spec 025
// box-owner-lock.md 4.6) the key exists only as box-<id>.key.enc, and
// `spool keygen` must not make a clear box-<id>.key next to it, with or
// without --force: that would be a second identity. Bug round 4 row 01.
func TestKeygenSealedBox(t *testing.T) {
	e := newLockEnv(t)
	if rc, _, errOut := e.run(t, []string{ltSecret}, "seal"); rc != 0 {
		t.Fatalf("seal rc %d %q", rc, errOut)
	}
	clear := filepath.Join(e.cfg.KeysDir, "box-"+e.cfg.BoxID+".key")
	if _, err := os.Stat(clear); err == nil {
		t.Fatalf("after seal a clear key %s still exists", clear)
	}
	for _, args := range [][]string{nil, {"--force"}} {
		rc, out, errOut := capture(t, "", func() int { return cmdKeygen(e.cfg, args) })
		_, err := os.Stat(clear)
		if rc == 0 || err == nil || !strings.Contains(errOut, "spool lock") {
			t.Errorf("keygen %v on a sealed box: rc %d out %q err %q, clear key written %v; want a refusal naming `spool lock` and no clear key",
				args, rc, out, errOut, err == nil)
		}
	}

	// Control: an unsealed keys dir still gets its key.
	u := newLockEnv(t)
	if rc, out, errOut := capture(t, "", func() int { return cmdKeygen(u.cfg, nil) }); rc != 0 || len(strings.TrimSpace(out)) != 44 {
		t.Fatalf("keygen on an unsealed box: rc %d out %q err %q", rc, out, errOut)
	}
	if _, err := os.Stat(filepath.Join(u.cfg.KeysDir, "box-"+u.cfg.BoxID+".key")); err != nil {
		t.Fatalf("keygen on an unsealed box wrote no key: %v", err)
	}
}
