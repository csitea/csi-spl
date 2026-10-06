package files

import (
	"archive/tar"
	"bytes"
	"errors"
	"io"
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

// trailerFailWriter accepts the archive body and fails on the tar footer.
// archive/tar.Writer.Close writes that footer as 512-byte zero blocks after
// any short entry padding, so the first full zero block is the trailer.
type trailerFailWriter struct {
	err error
}

func (w *trailerFailWriter) Write(p []byte) (int, error) {
	if isTarTrailerBlock(p) {
		return 0, w.err
	}
	return len(p), nil
}

func isTarTrailerBlock(p []byte) bool {
	if len(p) != 512 {
		return false
	}
	for _, b := range p {
		if b != 0 {
			return false
		}
	}
	return true
}

// TestWriteDeterministicTarTrailerWriteFails: a trailer write that fails must
// fail the pack. defer tw.Close() used to drop that error, so PutDir minted a
// file_id for a truncated tar.
func TestWriteDeterministicTarTrailerWriteFails(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}

	var ok bytes.Buffer
	if err := writeDeterministicTar(&ok, dir); err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(&ok)
	hdr, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if hdr.Name != "a.txt" {
		t.Fatalf("name %q", hdr.Name)
	}
	body, err := io.ReadAll(tr)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "hello" {
		t.Fatalf("body %q", body)
	}
	if _, err := tr.Next(); err != io.EOF {
		t.Fatalf("archive tail: %v", err)
	}

	boom := errors.New("trailer write failed")
	err = writeDeterministicTar(&trailerFailWriter{err: boom}, dir)
	if !errors.Is(err, boom) {
		t.Fatalf("trailer failure: got %v, want %v", err, boom)
	}
}
