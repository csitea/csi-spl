package files

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func pdTree(t *testing.T) (dir, src string) {
	t.Helper()
	dir = t.TempDir()
	src = filepath.Join(dir, "src")
	if err := os.MkdirAll(filepath.Join(src, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "sub", "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir, src
}

// TestPutDirStoreCannotBeMade: a filesDir under a regular file cannot be
// created, and PutDir returns the MkdirAll error.
func TestPutDirStoreCannotBeMade(t *testing.T) {
	dir, src := pdTree(t)
	plain := filepath.Join(dir, "plain")
	if err := os.WriteFile(plain, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := PutDir(filepath.Join(plain, "files"), src)
	var pe *os.PathError
	if !errors.As(err, &pe) || pe.Op != "mkdir" || !errors.Is(err, syscall.ENOTDIR) {
		t.Fatalf("err = %v, want the MkdirAll ENOTDIR error", err)
	}
}

// TestPutDirTreeCannotBeRead: a subdirectory of mode 000 fails the tar walk,
// and no .tar-* temp file is left in filesDir.
func TestPutDirTreeCannotBeRead(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode 000 directory")
	}
	dir, src := pdTree(t)
	sub := filepath.Join(src, "sub")
	if err := os.Chmod(sub, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(sub, 0o755) })
	store := filepath.Join(dir, "files")
	if err := os.MkdirAll(store, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := PutDir(store, src); err == nil {
		t.Fatal("PutDir of an unreadable tree succeeded")
	}
	left, err := filepath.Glob(filepath.Join(store, ".tar-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Fatalf("temp tar left behind: %v", left)
	}
}
