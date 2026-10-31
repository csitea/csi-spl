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

// TestStateDir: SPOOL_ENC_STATE wins when absolute, a relative one is
// refused, and with it unset the dir is under $HOME (refused with no home).
func TestStateDir(t *testing.T) {
	home := t.TempDir()
	cases := []struct {
		name, env, home, want, err string
	}{
		{name: "absolute env", env: "/srv/enc", home: home, want: "/srv/enc"},
		{name: "relative env", env: "rel/enc", home: home, err: "must be absolute"},
		{name: "home", home: home, want: filepath.Join(home, ".spool", "enc")},
		{name: "no home", err: "cannot resolve"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("SPOOL_ENC_STATE", tc.env)
			t.Setenv("HOME", tc.home)
			got, err := StateDir()
			if tc.err != "" {
				if err == nil || !strings.Contains(err.Error(), tc.err) {
					t.Fatalf("got %q, %v; want error %q", got, err, tc.err)
				}
				return
			}
			if err != nil || got != tc.want {
				t.Fatalf("got %q, %v; want %q", got, err, tc.want)
			}
		})
	}
}

// TestInitAgentRefusals: every refusal returns an error and no recipient.
// Each setup makes one step fail with a temp dir and a test passphrase.
func TestInitAgentRefusals(t *testing.T) {
	pass := randPass(t)
	cases := []struct {
		name  string
		setup func(t *testing.T, dir string) (ws, id string, pass []byte)
		err   string
	}{
		{name: "bad id", err: "agent id is not valid", setup: func(t *testing.T, dir string) (string, string, []byte) {
			return randWS(t), "nope", pass
		}},
		{name: "state dir under a file", err: "could not create the key state", setup: func(t *testing.T, dir string) (string, string, []byte) {
			writeKey(t, filepath.Join(dir, "keys"), []byte("x"), 0600)
			return randWS(t), "c-101", pass
		}},
		{name: "bad workspace", err: "workspace id is not a uuid", setup: func(t *testing.T, dir string) (string, string, []byte) {
			return "not-a-uuid", "c-101", pass
		}},
		{name: "workspace mismatch", err: "workspace mismatch", setup: func(t *testing.T, dir string) (string, string, []byte) {
			initAgent(t, dir, "c-101", pass)
			return randWS(t), "c-102", pass
		}},
		{name: "wrong passphrase", err: "could not open the agent keys", setup: func(t *testing.T, dir string) (string, string, []byte) {
			return initAgent(t, dir, "c-101", pass), "c-102", randPass(t)
		}},
		{name: "already exists", err: "identity already exists", setup: func(t *testing.T, dir string) (string, string, []byte) {
			return initAgent(t, dir, "c-101", pass), "c-101", pass
		}},
		{name: "bundle stat fails", err: "could not open the agent keys", setup: func(t *testing.T, dir string) (string, string, []byte) {
			mkKeys(t, dir)
			if err := os.Symlink("agents.age", agentsPath(dir)); err != nil {
				t.Fatal(err)
			}
			return randWS(t), "c-101", pass
		}},
		{name: "empty passphrase", err: "could not seal the agent keys", setup: func(t *testing.T, dir string) (string, string, []byte) {
			return randWS(t), "c-101", nil
		}},
		{name: "recipient not writable", err: "could not store the recipient", setup: func(t *testing.T, dir string) (string, string, []byte) {
			mkKeys(t, dir)
			if err := os.Mkdir(filepath.Join(dir, "keys", "c-101.pub"), 0700); err != nil {
				t.Fatal(err)
			}
			return randWS(t), "c-101", pass
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			ws, id, p := tc.setup(t, dir)
			pub, err := InitAgent(dir, ws, id, p)
			if err == nil || !strings.Contains(err.Error(), tc.err) {
				t.Fatalf("got %v, want %q", err, tc.err)
			}
			if pub != "" {
				t.Fatal("a refusal returned a recipient")
			}
		})
	}
}

func initAgent(t *testing.T, dir, id string, pass []byte) string {
	t.Helper()
	ws := randWS(t)
	if _, err := InitAgent(dir, ws, id, pass); err != nil {
		t.Fatal(err)
	}
	return ws
}

func mkKeys(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "keys"), 0700); err != nil {
		t.Fatal(err)
	}
}

// TestWriteScryptErrors: a failed seal leaves neither the target nor a
// temp file; a good one writes the asked mode and opens with the passphrase.
func TestWriteScryptErrors(t *testing.T) {
	pass := randPass(t)
	cases := []struct {
		name  string
		setup func(t *testing.T, dir string) string
		pass  []byte
		err   string
	}{
		{name: "dir missing", pass: pass, err: "could not seal", setup: func(t *testing.T, dir string) string {
			return filepath.Join(dir, "gone", "agents.age")
		}},
		{name: "empty passphrase", err: "could not seal", setup: func(t *testing.T, dir string) string {
			return filepath.Join(dir, "agents.age")
		}},
		{name: "target is a dir", pass: pass, err: "could not seal", setup: func(t *testing.T, dir string) string {
			return fullDir(t, filepath.Join(dir, "agents.age"))
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := tc.setup(t, dir)
			err := writeScrypt(path, []byte(`{"v":1}`), tc.pass, 0600)
			if err == nil || !strings.Contains(err.Error(), tc.err) {
				t.Fatalf("got %v, want %q", err, tc.err)
			}
			assertNoTemp(t, dir)
		})
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "agents.age")
	if err := writeScrypt(path, []byte(`{"v":1}`), pass, 0640); err != nil {
		t.Fatal(err)
	}
	assertMode(t, path, 0640)
	assertNoTemp(t, dir)
	got, err := openScrypt(path, pass)
	if err != nil || string(got) != `{"v":1}` {
		t.Fatalf("sealed file reads %q, %v", got, err)
	}
}

// fullDir makes p a non-empty directory: neither removed nor renamed over.
func fullDir(t *testing.T, p string) string {
	t.Helper()
	if err := os.MkdirAll(p, 0700); err != nil {
		t.Fatal(err)
	}
	writeKey(t, filepath.Join(p, "x"), nil, 0600)
	return p
}

func assertNoTemp(t *testing.T, dir string) {
	t.Helper()
	left, _ := filepath.Glob(filepath.Join(dir, ".w-*"))
	if len(left) != 0 {
		t.Fatalf("temp file left behind: %d", len(left))
	}
}

// TestWriteNewErrors: each failed step returns an error and leaves no file
// at path; a good write fills it with the asked mode.
func TestWriteNewErrors(t *testing.T) {
	fill := func(f *os.File) error { _, err := f.WriteString("x"); return err }
	cases := []struct {
		name  string
		setup func(t *testing.T, dir string) string
		fill  func(*os.File) error
		gone  bool
	}{
		{name: "old path not removable", fill: fill, setup: func(t *testing.T, dir string) string {
			return fullDir(t, filepath.Join(dir, "k"))
		}},
		{name: "dir missing", fill: fill, gone: true, setup: func(t *testing.T, dir string) string {
			return filepath.Join(dir, "gone", "k")
		}},
		{name: "fill fails", gone: true, fill: func(*os.File) error { return errors.New("fill") }, setup: func(t *testing.T, dir string) string {
			return filepath.Join(dir, "k")
		}},
		{name: "sync fails", gone: true, fill: func(f *os.File) error { return f.Close() }, setup: func(t *testing.T, dir string) string {
			return filepath.Join(dir, "k")
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := tc.setup(t, dir)
			err := writeNew(path, 0400, tc.fill)
			if err == nil || err.Error() != "could not write the key state" {
				t.Fatalf("got %v, want the write refusal", err)
			}
			if tc.gone && present(path) {
				t.Fatal("a failed write left the file")
			}
		})
	}
	path := filepath.Join(t.TempDir(), "k")
	writeKey(t, path, []byte("old"), 0600)
	if err := writeNew(path, 0400, fill); err != nil {
		t.Fatal(err)
	}
	assertMode(t, path, 0400)
	if b, err := os.ReadFile(path); err != nil || string(b) != "x" {
		t.Fatalf("written file reads %q, %v", b, err)
	}
}
