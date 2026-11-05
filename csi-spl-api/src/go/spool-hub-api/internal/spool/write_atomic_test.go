package spool

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// Refactor round 24 row 06 (r50-06): the stderr fallback of Store.warnOut and
// the error paths of writeFileAtomic, each under 75% before this file.

func TestWarnOut_NilWriterFallsBackToStderr(t *testing.T) {
	st := &Store{}
	if got := st.warnOut(); got != os.Stderr {
		t.Fatalf("warnOut() with warn == nil = %v, want os.Stderr", got)
	}
}

func TestWarnOut_CustomWriterIsReturned(t *testing.T) {
	var buf bytes.Buffer
	st := &Store{warn: &buf}
	if got := st.warnOut(); got != &buf {
		t.Fatalf("warnOut() = %v, want the custom writer", got)
	}
}

// waWriteFile creates a regular file at dir/name and returns its path.
func waWriteFile(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestWriteFileAtomic_ParentIsRegularFile(t *testing.T) {
	parent := waWriteFile(t, t.TempDir(), "not-a-dir")
	if err := writeFileAtomic(filepath.Join(parent, "msg.json"), []byte("{}"), 0o644); err == nil {
		t.Fatal("writeFileAtomic under a regular file: err = nil, want MkdirAll error")
	}
}

func TestWriteFileAtomic_ParentIsReadOnly(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	dir := filepath.Join(t.TempDir(), "ro")
	if err := os.Mkdir(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	if err := writeFileAtomic(filepath.Join(dir, "msg.json"), []byte("{}"), 0o644); err == nil {
		t.Fatal("writeFileAtomic in a 0500 dir: err = nil, want CreateTemp error")
	}
	if left, _ := filepath.Glob(filepath.Join(dir, ".tmp-*")); len(left) != 0 {
		t.Fatalf("temp files left behind: %v", left)
	}
}

func TestWriteFileAtomic_WritesDataWithMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sub", "msg.json")
	want := []byte(`{"v":1}`)
	if err := writeFileAtomic(path, want, 0o640); err != nil {
		t.Fatalf("writeFileAtomic: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("content = %q, want %q", got, want)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o640 {
		t.Fatalf("mode = %v, want 0640", fi.Mode().Perm())
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "sub", ".tmp-*")); len(left) != 0 {
		t.Fatalf("temp files left behind: %v", left)
	}
}
