package files

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// r6-06: blob and path attachments end to end - put, ref, resolve, get -
// and the tar guard that keeps an unpacked dir inside its dest.

// writeTree makes dir/<rel> = body for each pair and returns dir.
func writeTree(t *testing.T, dir string, kv ...string) string {
	t.Helper()
	for i := 0; i < len(kv); i += 2 {
		p := filepath.Join(dir, kv[i])
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(kv[i+1]), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestIsSHA256Hex(t *testing.T) {
	for _, c := range []struct {
		in   string
		want bool
	}{
		{strings.Repeat("a", 64), true},
		{strings.Repeat("0f", 32), true},
		{strings.Repeat("a", 63), false},
		{strings.Repeat("a", 65), false},
		{strings.Repeat("g", 64), false},
		{"../" + strings.Repeat("a", 61), false},
		{"", false},
	} {
		if got := isSHA256Hex(c.in); got != c.want {
			t.Errorf("isSHA256Hex(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestRefBlob(t *testing.T) {
	dir := t.TempDir()
	store := filepath.Join(dir, "files")
	a, err := PutFile(store, writeTree(t, dir, "x.txt", "twelve bytes")+"/x.txt")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(store, strings.Repeat("b", 64)), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, id string
		bytes    int64
	}{
		{"stored id carries its size", a.FileID, 12},
		{"absent id kept, no size", strings.Repeat("c", 64), 0},
		{"a dir under a hash name is not a blob", strings.Repeat("b", 64), 0},
		{"non-hash id is never stat'ed", "../x.txt", 0},
	} {
		got := RefBlob(store, c.id)
		want := msg.Attachment{Mode: "blob", Kind: "file", FileID: c.id, SHA256: c.id, Name: c.id, Bytes: c.bytes}
		if got != want {
			t.Errorf("%s: %+v, want %+v", c.name, got, want)
		}
	}
}

func TestPutAndRefRefusals(t *testing.T) {
	dir := t.TempDir()
	writeTree(t, dir, "f.txt", "x")
	f, d, none := filepath.Join(dir, "f.txt"), dir, filepath.Join(dir, "none")
	store := filepath.Join(dir, "files")
	for _, c := range []struct {
		name string
		call func() error
		want string
	}{
		{"PutFile on a dir", func() error { _, err := PutFile(store, d); return err }, "is a directory; use PutDir"},
		{"PutFile absent", func() error { _, err := PutFile(store, none); return err }, "no such file"},
		{"PutDir on a file", func() error { _, err := PutDir(store, f); return err }, "is not a directory; use PutFile"},
		{"PutDir absent", func() error { _, err := PutDir(store, none); return err }, "no such file"},
		{"RefFile on a dir", func() error { _, err := RefFile(d); return err }, "is a directory; use RefDir"},
		{"RefFile absent", func() error { _, err := RefFile(none); return err }, "no such file"},
		{"RefDir on a file", func() error { _, err := RefDir(f); return err }, "is not a directory; use RefFile"},
		{"RefDir absent", func() error { _, err := RefDir(none); return err }, "no such file"},
	} {
		if err := c.call(); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want %q", c.name, err, c.want)
		}
	}
}

// TestPutFileDedupes: identical bytes are one object with one id.
func TestPutFileDedupes(t *testing.T) {
	dir := t.TempDir()
	writeTree(t, dir, "a", "same", "b", "same")
	store := filepath.Join(dir, "files")
	a, err := PutFile(store, filepath.Join(dir, "a"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := PutFile(store, filepath.Join(dir, "b"))
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("same"))
	if a.FileID != b.FileID || a.FileID != hex.EncodeToString(sum[:]) || b.Name != "b" || b.Bytes != 4 {
		t.Fatalf("a %+v b %+v", a, b)
	}
	if left, _ := os.ReadDir(store); len(left) != 1 {
		t.Fatalf("store holds %d entries, want 1 (no temp left)", len(left))
	}
}

// TestResolve drives every mode/kind branch of Resolve.
func TestResolve(t *testing.T) {
	dir := t.TempDir()
	store := filepath.Join(dir, "files")
	src := writeTree(t, filepath.Join(dir, "src"), "top.txt", "top", "sub/deep.txt", "deep")
	fileBlob, err := PutFile(store, filepath.Join(src, "top.txt"))
	if err != nil {
		t.Fatal(err)
	}
	dirBlob, err := PutDir(store, src)
	if err != nil {
		t.Fatal(err)
	}
	// a second pack of the same tree is the same id (deterministic tar)
	if again, err := PutDir(store, src); err != nil || again.FileID != dirBlob.FileID || again.Kind != "dir" {
		t.Fatalf("repack %+v %v, want id %s", again, err, dirBlob.FileID)
	}
	fileRef, err := RefFile(filepath.Join(src, "sub", "deep.txt"))
	if err != nil {
		t.Fatal(err)
	}
	dirRef, err := RefDir(src)
	if err != nil {
		t.Fatal(err)
	}
	if dirRef.Path != src || dirRef.Name != "src" || fileRef.Bytes != 4 || fileRef.Mode != "path" {
		t.Fatalf("refs %+v %+v", dirRef, fileRef)
	}

	out := filepath.Join(dir, "out")
	if err := Resolve(store, fileBlob, filepath.Join(out, "blob.txt")); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, filepath.Join(out, "blob.txt")); got != "top" {
		t.Errorf("blob file: %q", got)
	}
	if err := Resolve(store, dirBlob, filepath.Join(out, "tree")); err != nil {
		t.Fatal(err)
	}
	if a, b := readFile(t, filepath.Join(out, "tree", "top.txt")), readFile(t, filepath.Join(out, "tree", "sub", "deep.txt")); a != "top" || b != "deep" {
		t.Errorf("blob dir: %q %q", a, b)
	}
	if err := Resolve(store, fileRef, filepath.Join(out, "ref.txt")); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, filepath.Join(out, "ref.txt")); got != "deep" {
		t.Errorf("path file: %q", got)
	}

	for _, c := range []struct {
		name string
		a    msg.Attachment
		want string
		is   error
	}{
		{"path dir is referenced in place", dirRef, "is referenced in place", nil},
		{"unknown mode", msg.Attachment{Mode: "carrier-pigeon"}, `unknown attachment mode "carrier-pigeon"`, nil},
		{"absent blob", msg.Attachment{Mode: "blob", Kind: "file", FileID: strings.Repeat("d", 64)}, "absent", nil},
		{"absent dir blob", msg.Attachment{Mode: "blob", Kind: "dir", FileID: strings.Repeat("d", 64)}, "no such file", nil},
		{"drifted path ref", msg.Attachment{Mode: "path", Kind: "file", Path: fileRef.Path, SHA256: fileBlob.SHA256}, "", ErrHashMismatch},
	} {
		err := Resolve(store, c.a, filepath.Join(out, "x-"+strings.ReplaceAll(c.name, " ", "-")))
		switch {
		case c.is != nil && !errors.Is(err, c.is):
			t.Errorf("%s: %v, want %v", c.name, err, c.is)
		case c.is == nil && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%s: %v, want %q", c.name, err, c.want)
		}
	}
}

// TestGetDirHashMismatch: a dir blob whose bytes do not match its id is
// refused after the unpack read the whole tar.
func TestGetDirHashMismatch(t *testing.T) {
	dir := t.TempDir()
	store := filepath.Join(dir, "files")
	a, err := PutDir(store, writeTree(t, filepath.Join(dir, "src"), "a.txt", "a"))
	if err != nil {
		t.Fatal(err)
	}
	wrong := strings.Repeat("e", 64)
	if err := os.Rename(filepath.Join(store, a.FileID), filepath.Join(store, wrong)); err != nil {
		t.Fatal(err)
	}
	if err := GetDir(store, wrong, filepath.Join(dir, "out")); !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("got %v, want ErrHashMismatch", err)
	}
}

// tarOf builds a tar of the given headers (a reg entry's body is its name).
func tarOf(t *testing.T, hdrs ...*tar.Header) []byte {
	t.Helper()
	var b bytes.Buffer
	tw := tar.NewWriter(&b)
	for _, h := range hdrs {
		body := ""
		if h.Typeflag == tar.TypeReg {
			body = h.Name
			h.Size = int64(len(body))
		}
		if h.Mode == 0 {
			h.Mode = 0o644
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if body != "" {
			if _, err := tw.Write([]byte(body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// storeRaw writes raw into store under its own sha256 and returns the id.
func storeRaw(t *testing.T, store string, raw []byte) string {
	t.Helper()
	if err := os.MkdirAll(store, 0o755); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	id := hex.EncodeToString(sum[:])
	if err := os.WriteFile(filepath.Join(store, id), raw, 0o644); err != nil {
		t.Fatal(err)
	}
	return id
}

// TestGetDirExtract: unsafe names are refused before anything lands outside
// dest; links are skipped; a dir entry and a reg file in a new dir unpack.
func TestGetDirExtract(t *testing.T) {
	cases := []struct {
		name    string
		hdrs    []*tar.Header
		wantErr string
		files   map[string]string // rel -> body that must exist under dest
		absent  []string          // rel under dest that must not exist
	}{
		{"absolute path", []*tar.Header{{Name: "/etc/evil", Typeflag: tar.TypeReg}}, "unsafe tar path", nil, nil},
		{"parent dir", []*tar.Header{{Name: "..", Typeflag: tar.TypeDir}}, "unsafe tar path", nil, nil},
		{"climbs out", []*tar.Header{{Name: "a/../../evil", Typeflag: tar.TypeReg}}, "unsafe tar path", nil, nil},
		{"dir then file", []*tar.Header{{Name: "d/", Typeflag: tar.TypeDir, Mode: 0o755}, {Name: "d/f.txt", Typeflag: tar.TypeReg}},
			"", map[string]string{"d/f.txt": "d/f.txt"}, nil},
		{"file in an unlisted dir", []*tar.Header{{Name: "x/y/z.txt", Typeflag: tar.TypeReg}}, "", map[string]string{"x/y/z.txt": "x/y/z.txt"}, nil},
		{"symlink skipped", []*tar.Header{{Name: "ln", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd"}, {Name: "ok.txt", Typeflag: tar.TypeReg}},
			"", map[string]string{"ok.txt": "ok.txt"}, []string{"ln"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			store := filepath.Join(dir, "files")
			id := storeRaw(t, store, tarOf(t, c.hdrs...))
			dest := filepath.Join(dir, "a", "dest")
			err := GetDir(store, id, dest)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("got %v, want %q", err, c.wantErr)
				}
				if _, serr := os.Stat(filepath.Join(dir, "evil")); serr == nil {
					t.Fatal("an unsafe entry was written outside dest")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			for rel, body := range c.files {
				if got := readFile(t, filepath.Join(dest, rel)); got != body {
					t.Errorf("%s: %q, want %q", rel, got, body)
				}
			}
			for _, rel := range c.absent {
				if _, err := os.Lstat(filepath.Join(dest, rel)); err == nil {
					t.Errorf("%s was extracted", rel)
				}
			}
		})
	}
}

// TestGetDirCorruptTar: bytes that are not a tar end the unpack with an error.
func TestGetDirCorruptTar(t *testing.T) {
	dir := t.TempDir()
	store := filepath.Join(dir, "files")
	raw := tarOf(t, &tar.Header{Name: "a.txt", Typeflag: tar.TypeReg})
	copy(raw[148:156], "garbage!") // the header checksum field
	id := storeRaw(t, store, raw)
	if err := GetDir(store, id, filepath.Join(dir, "out")); err == nil {
		t.Fatal("a corrupt tar header was accepted")
	}
}

func TestHasDotDot(t *testing.T) {
	for _, c := range []struct {
		in   string
		want bool
	}{
		{"a/b", false},
		{"a/../b", true},
		{"..", true},
		{"a..b/c", false},
		{"..a", false},
		{"", false},
	} {
		if got := hasDotDot(c.in); got != c.want {
			t.Errorf("hasDotDot(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}
