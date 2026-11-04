package lockkey

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Row r49-06: checkIDs, writeFile and shred, each on its own branches, in
// t.TempDir() only.

// siWantErrNaming fails unless err is non-nil and names want.
func siWantErrNaming(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("want an error naming %q, got %v", want, err)
	}
}

// siPlainFile writes b to a new regular file under dir and returns its path.
func siPlainFile(t *testing.T, dir, name string, b []byte) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestCheckIDs(t *testing.T) {
	siWantErrNaming(t, checkIDs("Bad Tenant", tBox), "tenant")
	siWantErrNaming(t, checkIDs("dev", tBox), "tenant")
	siWantErrNaming(t, checkIDs(tTenant, "Bad Box"), "box")
	siWantErrNaming(t, checkIDs(tTenant, ""), "box")
	if err := checkIDs(tTenant, tBox); err != nil {
		t.Fatalf("valid ids refused: %v", err)
	}
}

func TestWriteFileStoreIO(t *testing.T) {
	dir := t.TempDir()
	parent := siPlainFile(t, dir, "parent", nil)
	if err := writeFile(filepath.Join(parent, "child"), []byte("x")); err == nil {
		t.Fatal("writeFile under a regular file did not fail")
	}

	p := filepath.Join(dir, "key")
	want := []byte("sealed key bytes")
	if err := writeFile(p, want); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o, want 600", st.Mode().Perm())
	}
	if got, _ := os.ReadFile(p); !bytes.Equal(got, want) {
		t.Fatalf("content %q, want %q", got, want)
	}
}

func TestShred(t *testing.T) {
	dir := t.TempDir()
	if err := shred(filepath.Join(dir, "missing")); err != nil {
		t.Fatalf("missing path: %v", err)
	}

	// A hard link keeps the inode readable after shred unlinks the path,
	// so the zeroing itself is checked, not only the removal.
	p := siPlainFile(t, dir, "key", []byte("secret key material"))
	link := filepath.Join(dir, "key.link")
	if err := os.Link(p, link); err != nil {
		t.Fatal(err)
	}
	if err := shred(p); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("shredded path still there: %v", err)
	}
	got, err := os.ReadFile(link)
	if err != nil {
		t.Fatal(err)
	}
	if want := make([]byte, len("secret key material")); !bytes.Equal(got, want) {
		t.Fatalf("content not zeroed: %q", got)
	}

	sub := filepath.Join(dir, "sub")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := shred(sub); err == nil {
		t.Fatal("shred of a directory did not fail")
	}
}
