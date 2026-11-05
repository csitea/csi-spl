package files

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// r50-08: writeBlob, copyVerify and SniffBytes on their error and
// magic-signature branches, in t.TempDir() only.

// scErrReader fails its first Read.
type scErrReader struct{}

func (scErrReader) Read([]byte) (int, error) { return 0, errors.New("sc read fail") }

// scRegularFile writes dir/name as a regular file and returns its path.
func scRegularFile(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// scBlobTemps lists the .blob-* temp files left in dir.
func scBlobTemps(t *testing.T, dir string) []string {
	t.Helper()
	m, err := filepath.Glob(filepath.Join(dir, ".blob-*"))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestWriteBlobFilesDirIsRegularFile(t *testing.T) {
	notDir := scRegularFile(t, t.TempDir(), "files")
	if _, _, err := writeBlob(notDir, strings.NewReader("a")); err == nil {
		t.Fatal("writeBlob into a regular file: want error, got nil")
	}
}

func TestWriteBlobReadErrorLeavesNoTemp(t *testing.T) {
	dir := t.TempDir()
	if _, _, err := writeBlob(dir, scErrReader{}); err == nil {
		t.Fatal("writeBlob with a failing reader: want error, got nil")
	}
	if left := scBlobTemps(t, dir); len(left) != 0 {
		t.Fatalf("temp files left behind: %v", left)
	}
}

func TestWriteBlobDedupe(t *testing.T) {
	dir := t.TempDir()
	body := "same bytes twice\n"
	sum := sha256.Sum256([]byte(body))
	want := hex.EncodeToString(sum[:])
	id1, n1, err := writeBlob(dir, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	id2, n2, err := writeBlob(dir, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if id1 != want || id2 != want || n1 != int64(len(body)) || n2 != n1 {
		t.Fatalf("got (%s,%d) and (%s,%d), want (%s,%d) twice", id1, n1, id2, n2, want, len(body))
	}
	if left := scBlobTemps(t, dir); len(left) != 0 {
		t.Fatalf("temp files left behind: %v", left)
	}
	got, err := os.ReadFile(filepath.Join(dir, want))
	if err != nil || string(got) != body {
		t.Fatalf("stored blob = %q, %v; want %q", got, err, body)
	}
}

func TestCopyVerify(t *testing.T) {
	dir := t.TempDir()
	body := "copy me\n"
	src := filepath.Join(dir, "src.txt")
	if err := os.WriteFile(src, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(body))
	good := hex.EncodeToString(sum[:])

	t.Run("dest parent is a regular file", func(t *testing.T) {
		parent := scRegularFile(t, t.TempDir(), "notdir")
		if err := copyVerify(src, filepath.Join(parent, "out"), good); err == nil {
			t.Fatal("want error, got nil")
		}
	})
	t.Run("src is a directory", func(t *testing.T) {
		dest := filepath.Join(t.TempDir(), "out")
		if err := copyVerify(t.TempDir(), dest, ""); err == nil {
			t.Fatal("want error, got nil")
		}
		if _, err := os.Stat(dest); !os.IsNotExist(err) {
			t.Fatalf("dest exists after a failed copy: %v", err)
		}
	})
	t.Run("hash mismatch", func(t *testing.T) {
		dest := filepath.Join(t.TempDir(), "out")
		if err := copyVerify(src, dest, strings.Repeat("0", 64)); !errors.Is(err, ErrHashMismatch) {
			t.Fatalf("err = %v, want ErrHashMismatch", err)
		}
		if _, err := os.Stat(dest); !os.IsNotExist(err) {
			t.Fatalf("dest exists after a mismatch: %v", err)
		}
	})
	t.Run("hash match writes dest", func(t *testing.T) {
		dest := filepath.Join(t.TempDir(), "sub", "out")
		if err := copyVerify(src, dest, good); err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(dest)
		if err != nil || string(got) != body {
			t.Fatalf("dest = %q, %v; want %q", got, err, body)
		}
	})
}

// scFtyp is an ISO-BMFF head with brand: a box size that matches no magic
// (never "\x00\x00\x01\x00", which is ico), then "ftyp" and the brand.
func scFtyp(brand string) []byte {
	return []byte("\x00\x00\x00\x18ftyp" + brand + "\x00\x00\x00\x00")
}

func TestSniffBytesRiffAndFtyp(t *testing.T) {
	for _, c := range []struct {
		name string
		b    []byte
		want string
	}{
		{"riff wave", []byte("RIFF\x00\x00\x00\x00WAVE"), "wav"},
		{"riff webp", []byte("RIFF\x00\x00\x00\x00WEBP"), "webp"},
		{"ftyp avif", scFtyp("avif"), "avif"},
		{"ftyp avis", scFtyp("avis"), "avif"},
		{"ftyp heic", scFtyp("heic"), "heic"},
		{"ftyp heix", scFtyp("heix"), "heic"},
		{"ftyp mif1", scFtyp("mif1"), "heic"},
		{"ftyp qt", scFtyp("qt  "), "mov"},
		{"ftyp isom", scFtyp("isom"), "mp4"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := SniffBytes(c.b, true); got != c.want {
				t.Fatalf("SniffBytes(%q) = %q, want %q", c.b, got, c.want)
			}
		})
	}
}
