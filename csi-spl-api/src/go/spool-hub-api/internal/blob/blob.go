// Package blob is the hub's object store for file bytes: one bucket, keys
// t/<tenant_id>/files/<sha256> (FR-007, FR-015). GCS in production, a local
// directory in tests and lde. Never the Cloud Run container disk (FR-012):
// the Dir driver exists for tests and local dev only.
package blob

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"cloud.google.com/go/storage"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/iterator"
)

// ErrNotFound is returned for an absent object.
var ErrNotFound = errors.New("object not found")

var sha256Re = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Key returns the object key of file_id in tenant, or an error for a malformed id.
func Key(tenantID, fileID string) (string, error) {
	if !sha256Re.MatchString(fileID) {
		return "", fmt.Errorf("file_id %q is not a sha256 hex digest", fileID)
	}
	return "t/" + tenantID + "/files/" + fileID, nil
}

// AvatarKey is the hub-wide key of a person's own IdP picture (CLE-3406):
// avatars/<sha256>, outside every tenant prefix, so a sign-in with no tenant
// or into a tenant the person is not yet a member of still keeps it, and it
// never counts against a tenant's file quota.
func AvatarKey(fileID string) (string, error) {
	if !sha256Re.MatchString(fileID) {
		return "", fmt.Errorf("file_id %q is not a sha256 hex digest", fileID)
	}
	return "avatars/" + fileID, nil
}

// TmpKey is the scratch key of one in-flight upload of tenant (027 T020):
// tmp/<tenant>/<nonce>, outside every t/<tenant>/files/ prefix, so it never
// counts against a quota and one bucket lifecycle rule on "tmp/" can sweep
// what a crashed hub leaves behind.
func TmpKey(tenantID, nonce string) string { return "tmp/" + tenantID + "/" + nonce }

// Store holds immutable, content-addressed objects.
type Store interface {
	Put(ctx context.Context, key string, data []byte) error
	// PutReader streams r into key (a TmpKey: no content-address
	// precondition) and returns the bytes written. On any error nothing is
	// left at key: the caller need not clean up after a failed PutReader.
	PutReader(ctx context.Context, key string, r io.Reader) (int64, error)
	// Promote moves src to dst. When dst already exists (content-addressed:
	// same bytes) dst is kept, src is removed and existed is true.
	Promote(ctx context.Context, src, dst string) (existed bool, err error)
	Get(ctx context.Context, key string) (io.ReadCloser, error)
	Exists(ctx context.Context, key string) (bool, error)
	// Delete removes the object; ErrNotFound when it is absent (owner-requested
	// DELETE /v1/files/{file_id}, specs/003 contracts/http-v1.md §3).
	Delete(ctx context.Context, key string) error
	// PrefixBytes sums object sizes under prefix (tenant file quota, 006).
	PrefixBytes(ctx context.Context, prefix string) (int64, error)
	// Uploaded is when key was last uploaded: its creation, or the latest
	// Touch. ErrNotFound when it is absent. The file read door lets an
	// attachment no message carries through only this soon after an upload,
	// and retention deletes such a blob only once it is older (CLE-34962).
	Uploaded(ctx context.Context, key string) (time.Time, error)
	// Touch marks key uploaded now: a re-upload of bytes the store already
	// holds (content-addressed) is a fresh upload for Uploaded.
	Touch(ctx context.Context, key string) error
	// List calls fn with every key under prefix and its Uploaded time.
	List(ctx context.Context, prefix string, fn func(key string, uploaded time.Time) error) error
	Close() error
}

// Dir stores objects under a local directory (tests / lde only).
type Dir struct{ Root string }

func (d Dir) path(key string) string { return filepath.Join(d.Root, filepath.FromSlash(key)) }

func (d Dir) Put(_ context.Context, key string, data []byte) error {
	p := d.path(key)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), ".tmp-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), p)
}

func (d Dir) PutReader(_ context.Context, key string, r io.Reader) (int64, error) {
	p := d.path(key)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return 0, err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), ".tmp-*")
	if err != nil {
		return 0, err
	}
	n, err := io.Copy(tmp, r)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), p)
	}
	if err != nil {
		os.Remove(tmp.Name())
		return n, err
	}
	return n, nil
}

// Promote hard-links src to dst (fails with EEXIST when dst is present, so a
// concurrent upload of the same bytes cannot overwrite it), then drops src.
func (d Dir) Promote(_ context.Context, src, dst string) (bool, error) {
	ps, pd := d.path(src), d.path(dst)
	if err := os.MkdirAll(filepath.Dir(pd), 0o755); err != nil {
		return false, err
	}
	err := os.Link(ps, pd)
	existed := errors.Is(err, os.ErrExist)
	if err != nil && !existed {
		return false, err
	}
	if err := os.Remove(ps); err != nil && !os.IsNotExist(err) {
		return existed, err
	}
	return existed, nil
}

func (d Dir) Get(_ context.Context, key string) (io.ReadCloser, error) {
	f, err := os.Open(d.path(key))
	if os.IsNotExist(err) {
		return nil, ErrNotFound
	}
	return f, err
}

func (d Dir) Exists(_ context.Context, key string) (bool, error) {
	_, err := os.Stat(d.path(key))
	if os.IsNotExist(err) {
		return false, nil
	}
	return err == nil, err
}

func (d Dir) Delete(_ context.Context, key string) error {
	err := os.Remove(d.path(key))
	if os.IsNotExist(err) {
		return ErrNotFound
	}
	return err
}

func (d Dir) PrefixBytes(_ context.Context, prefix string) (int64, error) {
	root := d.path(prefix)
	fi, err := os.Stat(root)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if !fi.IsDir() {
		return fi.Size(), nil
	}
	var n int64
	err = filepath.Walk(root, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() {
			n += info.Size()
		}
		return nil
	})
	return n, err
}

// Uploaded is the file's mtime: Put and PutReader write a fresh file, a
// Promote hard link keeps the tmp file's, and Touch moves it.
func (d Dir) Uploaded(_ context.Context, key string) (time.Time, error) {
	fi, err := os.Stat(d.path(key))
	if os.IsNotExist(err) {
		return time.Time{}, ErrNotFound
	}
	if err != nil {
		return time.Time{}, err
	}
	return fi.ModTime(), nil
}

func (d Dir) Touch(_ context.Context, key string) error {
	now := time.Now()
	err := os.Chtimes(d.path(key), now, now)
	if os.IsNotExist(err) {
		return ErrNotFound
	}
	return err
}

func (d Dir) List(_ context.Context, prefix string, fn func(string, time.Time) error) error {
	root := d.path(prefix)
	if _, err := os.Stat(root); os.IsNotExist(err) {
		return nil
	}
	return filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			if os.IsNotExist(err) { // deleted while we walk
				return nil
			}
			return err
		}
		if info.IsDir() || strings.HasPrefix(info.Name(), ".tmp-") {
			return nil
		}
		rel, err := filepath.Rel(d.Root, p)
		if err != nil {
			return err
		}
		return fn(filepath.ToSlash(rel), info.ModTime())
	})
}

func (d Dir) Close() error { return nil }

// GCS stores objects in one bucket. Credentials come from the runtime service
// account (ADC); STORAGE_EMULATOR_HOST points the client at a local emulator.
type GCS struct {
	client *storage.Client
	bucket *storage.BucketHandle
}

// OpenGCS opens bucket with application-default credentials.
// Object reads use the JSON API so the same client works against
// STORAGE_EMULATOR_HOST (fake-gcs in lde does not serve XML downloads).
func OpenGCS(ctx context.Context, bucket string) (*GCS, error) {
	c, err := storage.NewClient(ctx, storage.WithJSONReads())
	if err != nil {
		return nil, fmt.Errorf("open gcs: %w", err)
	}
	return &GCS{client: c, bucket: c.Bucket(bucket)}, nil
}

func (g *GCS) Put(ctx context.Context, key string, data []byte) error {
	// Content-addressed: an existing object already holds these bytes.
	w := g.bucket.Object(key).If(storage.Conditions{DoesNotExist: true}).NewWriter(ctx)
	w.ContentType = "application/octet-stream"
	if _, err := w.Write(data); err != nil {
		w.Close()
		return err
	}
	err := w.Close()
	if isPrecondition(err) {
		return nil
	}
	return err
}

func (g *GCS) PutReader(parent context.Context, key string, r io.Reader) (int64, error) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	w := g.bucket.Object(key).NewWriter(ctx)
	w.ContentType = "application/octet-stream"
	// 0 = one streamed request with no client buffer (the default is a 16 MiB
	// buffer per in-flight upload). A failed upload is not resumed: the body
	// is a one-shot stream anyway, so the client retries the POST.
	w.ChunkSize = 0
	n, err := io.Copy(w, r)
	if err != nil {
		// Cancel aborts the upload, but Close can still race it and finalize
		// the bytes sent so far (seen on a slow CI runner). One delete after
		// Close is not enough: the finalize has landed AFTER that delete
		// returned, leaving the object at key and failing the contract above
		// (run 35634691126, 2026-09-21: "failed PutReader left an object at
		// its key"). So delete until the key is provably gone.
		cancel()
		w.Close()
		if derr := g.deleteUntilGone(context.WithoutCancel(parent), key); derr != nil {
			return n, errors.Join(err, derr)
		}
		return n, err
	}
	return n, w.Close()
}

// deleteUntilGone removes key and then PROVES it gone, briefly retrying: an
// aborted upload can be finalized by the server after the first delete has
// already returned, and the caller's contract is "nothing is left at key",
// not "a delete was issued". Error path only; it costs nothing on success.
func (g *GCS) deleteUntilGone(ctx context.Context, key string) error {
	const attempts, gap = 20, 50 * time.Millisecond // <= 1s
	var last error
	for i := 0; i < attempts; i++ {
		if err := g.bucket.Object(key).Delete(ctx); err != nil && !errors.Is(err, storage.ErrObjectNotExist) {
			last = err
		}
		switch ok, err := g.Exists(ctx, key); {
		case err != nil:
			last = err
		case !ok:
			return nil
		}
		time.Sleep(gap)
	}
	return errors.Join(last, fmt.Errorf("blob: %s is still present after an aborted upload", key))
}

// Promote is a server-side copy (no bytes through the hub) guarded by
// DoesNotExist on dst, then a delete of src. The explicit Exists first is for
// fake-gcs, which ignores the precondition on rewrite; GCS enforces it, so a
// concurrent upload of the same bytes still cannot overwrite dst.
func (g *GCS) Promote(ctx context.Context, src, dst string) (bool, error) {
	existed, err := g.Exists(ctx, dst)
	if err != nil {
		return false, err
	}
	if !existed {
		_, err = g.bucket.Object(dst).If(storage.Conditions{DoesNotExist: true}).
			CopierFrom(g.bucket.Object(src)).Run(ctx)
		existed = isPrecondition(err)
		if err != nil && !existed {
			return false, err
		}
	}
	if err := g.Delete(ctx, src); err != nil && !errors.Is(err, ErrNotFound) {
		return existed, err
	}
	return existed, nil
}

func (g *GCS) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	r, err := g.bucket.Object(key).NewReader(ctx)
	if errors.Is(err, storage.ErrObjectNotExist) {
		return nil, ErrNotFound
	}
	return r, err
}

func (g *GCS) Exists(ctx context.Context, key string) (bool, error) {
	_, err := g.bucket.Object(key).Attrs(ctx)
	if errors.Is(err, storage.ErrObjectNotExist) {
		return false, nil
	}
	return err == nil, err
}

func (g *GCS) Delete(ctx context.Context, key string) error {
	err := g.bucket.Object(key).Delete(ctx)
	if errors.Is(err, storage.ErrObjectNotExist) {
		return ErrNotFound
	}
	return err
}

func (g *GCS) PrefixBytes(ctx context.Context, prefix string) (int64, error) {
	it := g.bucket.Objects(ctx, &storage.Query{Prefix: prefix})
	var n int64
	for {
		attrs, err := it.Next()
		if err == iterator.Done {
			return n, nil
		}
		if err != nil {
			return 0, err
		}
		n += attrs.Size
	}
}

// uploadedMeta is the object metadata key Touch writes: a re-upload of
// bytes already held rewrites nothing, so the object's Created stays old.
const uploadedMeta = "spool-uploaded"

func uploadedAt(a *storage.ObjectAttrs) time.Time {
	if v, ok := a.Metadata[uploadedMeta]; ok {
		if t, err := time.Parse(time.RFC3339Nano, v); err == nil && t.After(a.Created) {
			return t
		}
	}
	return a.Created
}

func (g *GCS) Uploaded(ctx context.Context, key string) (time.Time, error) {
	a, err := g.bucket.Object(key).Attrs(ctx)
	if errors.Is(err, storage.ErrObjectNotExist) {
		return time.Time{}, ErrNotFound
	}
	if err != nil {
		return time.Time{}, err
	}
	return uploadedAt(a), nil
}

func (g *GCS) Touch(ctx context.Context, key string) error {
	_, err := g.bucket.Object(key).Update(ctx, storage.ObjectAttrsToUpdate{
		Metadata: map[string]string{uploadedMeta: time.Now().UTC().Format(time.RFC3339Nano)}})
	if errors.Is(err, storage.ErrObjectNotExist) {
		return ErrNotFound
	}
	return err
}

func (g *GCS) List(ctx context.Context, prefix string, fn func(string, time.Time) error) error {
	it := g.bucket.Objects(ctx, &storage.Query{Prefix: prefix})
	for {
		a, err := it.Next()
		if err == iterator.Done {
			return nil
		}
		if err != nil {
			return err
		}
		if err := fn(a.Name, uploadedAt(a)); err != nil {
			return err
		}
	}
}

func (g *GCS) Close() error { return g.client.Close() }

func isPrecondition(err error) bool {
	if err == nil {
		return false
	}
	var gerr *googleapi.Error
	return errors.As(err, &gerr) && gerr.Code == 412
}
