package keyd

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// keyFileStore makes an agent bundle sealed under a generated key file.
func keyFileStore(t *testing.T) (dir, keyPath string, key []byte) {
	t.Helper()
	dir = shortDir(t)
	key, err := NewUnlockKey()
	if err != nil {
		t.Fatal(err)
	}
	if len(key) != 44 {
		t.Fatalf("key length %d, want 44", len(key))
	}
	if _, err := InitAgent(dir, randWS(t), "c-101", key); err != nil {
		t.Fatal(err)
	}
	keyPath = UnlockKeyPath(dir)
	writeKey(t, keyPath, append(append([]byte{}, key...), '\n'), 0400)
	return dir, keyPath, key
}

func identities(t *testing.T, dir string, pass []byte) []string {
	t.Helper()
	agents, err := LoadAgents(dir, pass)
	if err != nil {
		t.Fatalf("the bundle does not open: %v", err)
	}
	var out []string
	for _, a := range agents {
		out = append(out, a.ID+" "+a.Identity)
	}
	return out
}

func fileKey(t *testing.T, path string) []byte {
	t.Helper()
	k, err := ReadKeyFile(path)
	if err != nil {
		t.Fatalf("key file: %v", err)
	}
	return k
}

func assertNoTmp(t *testing.T, dir, keyPath string) {
	t.Helper()
	for _, p := range []string{agentsPath(dir) + ".tmp", keyPath + ".tmp"} {
		if present(p) {
			t.Fatalf("%s left behind", filepath.Base(p))
		}
	}
}

// TestRotateUnlockKey: the new key opens the same identities, the old one
// no longer does, the file stays 0400 and no .tmp is left.
func TestRotateUnlockKey(t *testing.T) {
	dir, keyPath, old := keyFileStore(t)
	before := identities(t, dir, old)
	if err := RotateUnlockKey(dir, keyPath); err != nil {
		t.Fatal(err)
	}
	next := fileKey(t, keyPath)
	if bytes.Equal(next, old) {
		t.Fatal("the key did not change")
	}
	if got := identities(t, dir, next); strings.Join(got, ",") != strings.Join(before, ",") {
		t.Fatal("identities changed")
	}
	if _, err := LoadAgents(dir, old); err == nil {
		t.Fatal("the old key still opens the bundle")
	}
	assertMode(t, keyPath, 0400)
	assertMode(t, agentsPath(dir), 0600)
	assertNoTmp(t, dir, keyPath)
}

// TestRotateCrashRecovers stops a rotation after each durable step, as a
// crash would, and proves RecoverUnlockKey leaves a key file that opens the
// bundle with the same identities and no .tmp. The control: before the
// recovery, a crash between the two renames leaves a key file that does not
// open the bundle, so the recovery is what restores it.
func TestRotateCrashRecovers(t *testing.T) {
	for _, step := range []string{"agents-tmp", "key-tmp", "agents-renamed"} {
		t.Run(step, func(t *testing.T) {
			dir, keyPath, old := keyFileStore(t)
			before := identities(t, dir, old)
			crash := errors.New("crash at " + step)
			rekeyStep = func(s string) error {
				if s == step {
					return crash
				}
				return nil
			}
			err := RotateUnlockKey(dir, keyPath)
			rekeyStep = func(string) error { return nil }
			if !errors.Is(err, crash) {
				t.Fatalf("rotation did not stop: %v", err)
			}
			if !present(agentsPath(dir)+".tmp") && !present(keyPath+".tmp") {
				t.Fatal("the crash left no .tmp file")
			}
			cur := fileKey(t, keyPath)
			if step == "agents-renamed" && opensBundle(dir, cur) {
				t.Fatal("control: the key file still opens the bundle before recovery")
			}
			Wipe(cur)
			if err := RecoverUnlockKey(dir, keyPath); err != nil {
				t.Fatal(err)
			}
			assertNoTmp(t, dir, keyPath)
			assertMode(t, keyPath, 0400)
			got := identities(t, dir, fileKey(t, keyPath))
			if strings.Join(got, ",") != strings.Join(before, ",") {
				t.Fatal("identities changed")
			}
		})
	}
}

// TestRecoverRefusesInconsistent: when no key opens the bundle the files
// are left for the owner and an error is returned.
func TestRecoverRefusesInconsistent(t *testing.T) {
	dir, keyPath, _ := keyFileStore(t)
	writeKey(t, keyPath+".tmp", randPass(t), 0400)
	if err := os.Chmod(keyPath, 0600); err != nil {
		t.Fatal(err)
	}
	if err := RecoverUnlockKey(dir, keyPath); err == nil || !strings.Contains(err.Error(), "mode must be 0400") {
		t.Fatalf("a 0600 key file was used for recovery: %v", err)
	}
	if err := os.Remove(keyPath); err != nil {
		t.Fatal(err)
	}
	writeKey(t, keyPath, randPass(t), 0400)
	if err := RecoverUnlockKey(dir, keyPath); err == nil || !strings.Contains(err.Error(), "inconsistent") {
		t.Fatalf("no key opens the bundle, got %v", err)
	}
	if !present(keyPath + ".tmp") {
		t.Fatal("an inconsistent state was changed")
	}
}

// TestRekeyBetweenFileAndPassphrase: rekey to a typed passphrase, then back
// to a key file. Each time the new secret opens the bundle and the old one
// does not.
func TestRekeyBetweenFileAndPassphrase(t *testing.T) {
	dir, keyPath, key := keyFileStore(t)
	before := identities(t, dir, key)
	typed := randPass(t)
	if err := RekeyToPass(dir, key, typed); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadAgents(dir, key); err == nil {
		t.Fatal("the key file still opens the bundle")
	}
	if got := identities(t, dir, typed); strings.Join(got, ",") != strings.Join(before, ",") {
		t.Fatal("identities changed")
	}
	if present(agentsPath(dir) + ".tmp") {
		t.Fatal("agents.age.tmp left behind")
	}
	if err := os.Remove(keyPath); err != nil {
		t.Fatal(err)
	}
	if err := RekeyToFile(dir, key, keyPath); err == nil {
		t.Fatal("the stale key rekeyed the bundle")
	}
	if err := RekeyToFile(dir, typed, keyPath); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadAgents(dir, typed); err == nil {
		t.Fatal("the typed passphrase still opens the bundle")
	}
	assertMode(t, keyPath, 0400)
	if got := identities(t, dir, fileKey(t, keyPath)); strings.Join(got, ",") != strings.Join(before, ",") {
		t.Fatal("identities changed")
	}
	assertNoTmp(t, dir, keyPath)
}
