package secretfile

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func vars(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func write(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestFileWinsOverEnv(t *testing.T) {
	p := write(t, "from-file\n")
	got, err := Lookup("X", vars(map[string]string{"X": "from-env", "X_FILE": p}))
	if err != nil || got != "from-file" {
		t.Fatalf("file must win, the trailing newline dropped: %q %v", got, err)
	}
}

func TestEnvIsTheFallback(t *testing.T) {
	got, err := Lookup("X", vars(map[string]string{"X": "from-env"}))
	if err != nil || got != "from-env" {
		t.Fatalf("env fallback: %q %v", got, err)
	}
	got, err = Lookup("X", vars(map[string]string{"X": "from-env", "X_FILE": "  "}))
	if err != nil || got != "from-env" {
		t.Fatalf("a blank X_FILE is unset: %q %v", got, err)
	}
}

func TestMissingBothIsEmpty(t *testing.T) {
	got, err := Lookup("X", vars(nil))
	if err != nil || got != "" {
		t.Fatalf("neither set must be empty, no error (the caller decides): %q %v", got, err)
	}
}

func TestUnreadableFileIsAnError(t *testing.T) {
	_, err := Lookup("X", vars(map[string]string{"X": "from-env", "X_FILE": filepath.Join(t.TempDir(), "absent")}))
	if err == nil || !strings.Contains(err.Error(), "X_FILE") {
		t.Fatalf("a missing secret file must fail, naming X_FILE: %v", err)
	}
}

func TestTrailingLineBreaksDropped(t *testing.T) {
	for body, want := range map[string]string{"v\r\n": "v", "v": "v", "v\n\n": "v", "a\nb\n": "a\nb", " v ": " v "} {
		got, err := Lookup("X", vars(map[string]string{"X_FILE": write(t, body)}))
		if err != nil || got != want {
			t.Fatalf("%q -> %q, want %q (%v)", body, got, want, err)
		}
	}
}
