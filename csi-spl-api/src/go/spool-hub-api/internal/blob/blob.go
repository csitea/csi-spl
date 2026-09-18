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

	"cloud.google.com/go/storage"
	"google.golang.org/api/googleapi"
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

// Store holds immutable, content-addressed objects.
type Store interface {
	Put(ctx context.Context, key string, data []byte) error
	Get(ctx context.Context, key string) (io.ReadCloser, error)
	Exists(ctx context.Context, key string) (bool, error)
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

func (g *GCS) Close() error { return g.client.Close() }

func isPrecondition(err error) bool {
	if err == nil {
		return false
	}
	var gerr *googleapi.Error
	return errors.As(err, &gerr) && gerr.Code == 412
}
