package files

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// TestGetFileHonoursUmask: a get-file dest gets 0666 less the umask, like a
// plain create. A seated MCP server writes it as the box user for an agent
// user to read (its launcher sets umask 022 -> 0644); os.CreateTemp's fixed
// 0600 made every such file unreadable to the agent (measured 2026-09-25,
// spool-mcp-probe: EACCES on the dest). A umask of 077 still yields 0600.
func TestGetFileHonoursUmask(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.txt")
	if err := os.WriteFile(src, []byte("attachment\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	store := filepath.Join(dir, "files")
	a, err := PutFile(store, src)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		umask int
		want  os.FileMode
	}{{0o022, 0o644}, {0o077, 0o600}} {
		old := syscall.Umask(c.umask)
		dest := filepath.Join(dir, "out", "u"+string(rune('0'+c.umask%8)))
		err := GetFile(store, a.FileID, dest)
		syscall.Umask(old)
		if err != nil {
			t.Fatalf("umask %03o: %v", c.umask, err)
		}
		fi, err := os.Stat(dest)
		if err != nil {
			t.Fatal(err)
		}
		if got := fi.Mode().Perm(); got != c.want {
			t.Errorf("umask %03o: dest mode %03o, want %03o", c.umask, got, c.want)
		}
	}
	// a mismatch still leaves nothing behind, temp file included
	bad := filepath.Join(dir, "out", "bad")
	if err := copyVerify(src, bad, "00"); err != ErrHashMismatch {
		t.Fatalf("mismatch: %v", err)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "out", ".get-*")); len(left) != 0 || fileExists(bad) {
		t.Errorf("a refused copy left %v (dest exists: %v)", left, fileExists(bad))
	}
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }
