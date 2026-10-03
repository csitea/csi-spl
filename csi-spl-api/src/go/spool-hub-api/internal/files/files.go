// Package files implements on-box file/dir sharing in two modes:
//
//   - blob: bytes are copied into $SPOOL_ROOT/files/<file_id> content-addressed
//     by sha256. A directory is packed into a deterministic tar first, so its
//     file_id is stable and it can later cross a hub (003).
//   - path: a reference to an absolute on-box path; nothing is copied. Only
//     valid on the same box / shared filesystem.
//
// Get/Resolve re-hash blobs and refuse a mismatch or an absent object (never a
// partial write).
package files

import (
	"archive/tar"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// ErrHashMismatch is returned when read-back bytes do not match the file_id.
var ErrHashMismatch = fmt.Errorf("content hash does not match file_id")

// PutFile copies the file at path into the blob store and returns a blob
// attachment. Idempotent: identical bytes dedupe to one object.
func PutFile(filesDir, path string) (msg.Attachment, error) {
	info, err := os.Stat(path)
	if err != nil {
		return msg.Attachment{}, err
	}
	if info.IsDir() {
		return msg.Attachment{}, fmt.Errorf("%s is a directory; use PutDir", path)
	}
	f, err := os.Open(path)
	if err != nil {
		return msg.Attachment{}, err
	}
	defer f.Close()
	id, n, err := writeBlob(filesDir, f)
	if err != nil {
		return msg.Attachment{}, err
	}
	return msg.Attachment{
		Mode: "blob", Kind: "file", FileID: id, SHA256: id,
		Name: filepath.Base(path), Bytes: n,
	}, nil
}

// PutDir packs the directory at path into a deterministic tar, stores it as a
// blob, and returns a blob attachment of kind dir.
func PutDir(filesDir, path string) (msg.Attachment, error) {
	info, err := os.Stat(path)
	if err != nil {
		return msg.Attachment{}, err
	}
	if !info.IsDir() {
		return msg.Attachment{}, fmt.Errorf("%s is not a directory; use PutFile", path)
	}
	tmp, err := os.CreateTemp(filesDir, ".tar-*")
	if err != nil {
		if err := os.MkdirAll(filesDir, 0o755); err != nil {
			return msg.Attachment{}, err
		}
		tmp, err = os.CreateTemp(filesDir, ".tar-*")
		if err != nil {
			return msg.Attachment{}, err
		}
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := writeDeterministicTar(tmp, path); err != nil {
		tmp.Close()
		return msg.Attachment{}, err
	}
	if err := tmp.Close(); err != nil {
		return msg.Attachment{}, err
	}
	tf, err := os.Open(tmpName)
	if err != nil {
		return msg.Attachment{}, err
	}
	defer tf.Close()
	id, n, err := writeBlob(filesDir, tf)
	if err != nil {
		return msg.Attachment{}, err
	}
	return msg.Attachment{
		Mode: "blob", Kind: "dir", FileID: id, SHA256: id,
		Name: filepath.Base(path), Bytes: n,
	}, nil
}

// RefBlob makes the blob attachment for a file_id already in the store
// (`send --file-id`). The name is the file_id, as the store keeps no display
// name. Bytes is the stored length, so the ref carries message-schema.md's
// four fields (SC-006). An id not in the store is kept as before, without
// bytes, and is not refused.
func RefBlob(filesDir, fileID string) msg.Attachment {
	a := msg.Attachment{Mode: "blob", Kind: "file", FileID: fileID, SHA256: fileID, Name: fileID}
	if !isSHA256Hex(fileID) {
		return a // never stat a path built from a non-hash id
	}
	if info, err := os.Stat(filepath.Join(filesDir, fileID)); err == nil && info.Mode().IsRegular() {
		a.Bytes = info.Size()
	}
	return a
}

func isSHA256Hex(s string) bool {
	if len(s) != 64 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

// RefFile makes a path-mode attachment referencing an on-box file. It captures
// the size and content hash at send time so a receiver can detect drift.
func RefFile(path string) (msg.Attachment, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return msg.Attachment{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return msg.Attachment{}, err
	}
	if info.IsDir() {
		return msg.Attachment{}, fmt.Errorf("%s is a directory; use RefDir", abs)
	}
	f, err := os.Open(abs)
	if err != nil {
		return msg.Attachment{}, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return msg.Attachment{}, err
	}
	return msg.Attachment{
		Mode: "path", Kind: "file", Path: abs, Name: filepath.Base(abs),
		Bytes: info.Size(), SHA256: hex.EncodeToString(h.Sum(nil)),
	}, nil
}

// RefDir makes a path-mode attachment referencing an on-box directory.
func RefDir(path string) (msg.Attachment, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return msg.Attachment{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return msg.Attachment{}, err
	}
	if !info.IsDir() {
		return msg.Attachment{}, fmt.Errorf("%s is not a directory; use RefFile", abs)
	}
	return msg.Attachment{Mode: "path", Kind: "dir", Path: abs, Name: filepath.Base(abs)}, nil
}

// Resolve materialises an attachment at dest. For path mode it copies from the
// referenced path (files) or reports the directory location (dirs). For blob
// mode it verifies the hash and writes/unpacks into dest.
func Resolve(filesDir string, a msg.Attachment, dest string) error {
	switch a.Mode {
	case "blob":
		if a.Kind == "dir" {
			return GetDir(filesDir, a.FileID, dest)
		}
		return GetFile(filesDir, a.FileID, dest)
	case "path":
		if a.Kind == "dir" {
			// A dir reference is already the location; nothing to copy.
			return fmt.Errorf("path-dir %q is referenced in place; read it directly", a.Path)
		}
		return copyVerify(a.Path, dest, a.SHA256)
	default:
		return fmt.Errorf("unknown attachment mode %q", a.Mode)
	}
}

// GetFile copies blob file_id to dest and verifies the read-back hash.
func GetFile(filesDir, fileID, dest string) error {
	src := filepath.Join(filesDir, fileID)
	return copyVerify(src, dest, fileID)
}

// GetDir reads blob file_id (a tar), verifies its hash, and unpacks into dest.
func GetDir(filesDir, fileID, dest string) error {
	src := filepath.Join(filesDir, fileID)
	f, err := os.Open(src)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	tr := tar.NewReader(io.TeeReader(f, h))
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return err
	}
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if err := extractOne(tr, hdr, dest); err != nil {
			return err
		}
	}
	if hex.EncodeToString(h.Sum(nil)) != fileID {
		return ErrHashMismatch
	}
	return nil
}

func extractOne(tr *tar.Reader, hdr *tar.Header, dest string) error {
	clean := filepath.Clean(hdr.Name)
	if filepath.IsAbs(clean) || clean == ".." || hasDotDot(clean) {
		return fmt.Errorf("unsafe tar path %q", hdr.Name)
	}
	target := filepath.Join(dest, clean)
	switch hdr.Typeflag {
	case tar.TypeDir:
		return os.MkdirAll(target, 0o755)
	case tar.TypeReg:
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			return err
		}
		defer out.Close()
		_, err = io.Copy(out, tr)
		return err
	default:
		return nil // skip symlinks/devices in 002
	}
}

// writeBlob streams r into filesDir/<sha256>, idempotently. Returns id and size.
func writeBlob(filesDir string, r io.Reader) (string, int64, error) {
	if err := os.MkdirAll(filesDir, 0o755); err != nil {
		return "", 0, err
	}
	tmp, err := os.CreateTemp(filesDir, ".blob-*")
	if err != nil {
		return "", 0, err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), r)
	if err != nil {
		tmp.Close()
		return "", 0, err
	}
	if err := tmp.Close(); err != nil {
		return "", 0, err
	}
	id := hex.EncodeToString(h.Sum(nil))
	final := filepath.Join(filesDir, id)
	if _, err := os.Stat(final); err == nil {
		return id, n, nil // already stored (dedupe)
	}
	if err := os.Rename(tmpName, final); err != nil {
		return "", 0, err
	}
	return id, n, nil
}

// copyVerify copies src to dest via a temp file, checking the sha256 equals
// want before the final rename (never leaves a partial at dest). dest gets the
// mode a plain create would (0666 less the umask), not os.CreateTemp's 0600: a
// seated MCP server runs as the box user and writes the file for an agent user
// to read, and under its umask 022 that is 0644; a caller with umask 077 still
// gets 0600.
func copyVerify(src, dest, want string) error {
	in, err := os.Open(src)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("source %q absent: %w", src, err)
		}
		return fmt.Errorf("open %q: %w", src, err)
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return fmt.Errorf("mkdir %q: %w", filepath.Dir(dest), err)
	}
	tmp, err := createTemp(filepath.Dir(dest), ".get-")
	if err != nil {
		return fmt.Errorf("temp in %q: %w", filepath.Dir(dest), err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, h), in); err != nil {
		tmp.Close()
		return fmt.Errorf("copy %q: %w", src, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp: %w", err)
	}
	if want != "" && hex.EncodeToString(h.Sum(nil)) != want {
		return ErrHashMismatch
	}
	return os.Rename(tmpName, dest)
}

// createTemp is os.CreateTemp with the umask-honouring 0666 of os.Create.
func createTemp(dir, prefix string) (*os.File, error) {
	for i := 0; i < 16; i++ {
		b := make([]byte, 8)
		if _, err := rand.Read(b); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(filepath.Join(dir, prefix+hex.EncodeToString(b)), os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o666)
		if !os.IsExist(err) {
			return f, err
		}
	}
	return nil, fmt.Errorf("no free temp name in %s", dir)
}

// writeDeterministicTar writes a tar of root with cleared mtime/uid/gid and
// sorted entries, so identical trees produce identical bytes (stable file_id).
func writeDeterministicTar(w io.Writer, root string) error {
	tw := tar.NewWriter(w)
	defer tw.Close()
	var paths []string
	err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if p == root {
			return nil
		}
		paths = append(paths, p)
		return nil
	})
	if err != nil {
		return err
	}
	sort.Strings(paths)
	for _, p := range paths {
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		hdr := &tar.Header{Name: filepath.ToSlash(rel), Mode: 0o644}
		if info.IsDir() {
			hdr.Typeflag = tar.TypeDir
			hdr.Name += "/"
			hdr.Mode = 0o755
		} else if info.Mode().IsRegular() {
			hdr.Typeflag = tar.TypeReg
			hdr.Size = info.Size()
		} else {
			continue // skip non-regular in 002
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if hdr.Typeflag == tar.TypeReg {
			f, err := os.Open(p)
			if err != nil {
				return err
			}
			if _, err := io.Copy(tw, f); err != nil {
				f.Close()
				return err
			}
			f.Close()
		}
	}
	return nil
}

func hasDotDot(p string) bool {
	sep := string(os.PathSeparator)
	for _, s := range splitPath(p, sep) {
		if s == ".." {
			return true
		}
	}
	return false
}

func splitPath(p, sep string) []string {
	var out []string
	cur := ""
	for _, r := range p {
		if string(r) == sep || r == '/' {
			out = append(out, cur)
			cur = ""
			continue
		}
		cur += string(r)
	}
	out = append(out, cur)
	return out
}
