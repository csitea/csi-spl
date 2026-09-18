package blob

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"testing"

	"cloud.google.com/go/storage"
	"google.golang.org/api/googleapi"
)

func TestKey(t *testing.T) {
	id := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	k, err := Key("t1", id)
	if err != nil || k != "t/t1/files/"+id {
		t.Fatalf("Key = %q, %v", k, err)
	}
	if _, err := Key("t1", "../../etc/passwd"); err == nil {
		t.Fatal("path traversal accepted as file_id")
	}
}

func TestDir(t *testing.T) {
	testStore(t, Dir{Root: t.TempDir()})
}

func TestGCS(t *testing.T) {
	testStore(t, openTestGCS(t))
}

func uid() string {
	b := make([]byte, 6)
	rand.Read(b) //nolint:errcheck
	return hex.EncodeToString(b)
}

// testStore is the blob.Store contract: Put/Get/Exists at t/<tenant>/files/<sha256>,
// missing → ErrNotFound, a second Put of the same key is a no-op, and a
// different tenant prefix cannot see the object.
func testStore(t *testing.T, s Store) {
	t.Helper()
	ctx := context.Background()
	data := []byte("hello")
	sum := sha256.Sum256(data)
	id := hex.EncodeToString(sum[:])
	key, err := Key("t-"+uid(), id)
	if err != nil {
		t.Fatal(err)
	}
	if ok, _ := s.Exists(ctx, key); ok {
		t.Fatal("exists before put")
	}
	if _, err := s.Get(ctx, key); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get missing: %v", err)
	}
	if err := s.Put(ctx, key, data); err != nil {
		t.Fatal(err)
	}
	if err := s.Put(ctx, key, data); err != nil {
		t.Fatalf("idempotent put: %v", err)
	}
	r, err := s.Get(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r)
	r.Close()
	if string(b) != "hello" {
		t.Fatalf("got %q", b)
	}
	other, err := Key("t-"+uid(), id)
	if err != nil {
		t.Fatal(err)
	}
	if ok, _ := s.Exists(ctx, other); ok {
		t.Fatal("object visible under another tenant prefix")
	}
}

// openTestGCS opens the GCS driver against $STORAGE_EMULATOR_HOST (fake-gcs
// in lde / hub-gcs.tst.sh). The bucket name is $SPOOL_HUB_FILES_BUCKET, the
// same cnf-published name the hub process uses.
func openTestGCS(t *testing.T) *GCS {
	t.Helper()
	if os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		t.Skip("STORAGE_EMULATOR_HOST unset; GCS emulator not in this run")
	}
	bucket := os.Getenv("SPOOL_HUB_FILES_BUCKET")
	if bucket == "" {
		bucket = "csi-spl-test-files"
	}
	ctx := context.Background()
	c, err := storage.NewClient(ctx)
	if err != nil {
		t.Fatalf("gcs client: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	if err := c.Bucket(bucket).Create(ctx, "test", nil); err != nil {
		var gerr *googleapi.Error
		if !errors.As(err, &gerr) || (gerr.Code != 409 && gerr.Code != 412) {
			t.Fatalf("create bucket %s: %v", bucket, err)
		}
	}
	g, err := OpenGCS(ctx, bucket)
	if err != nil {
		t.Fatalf("OpenGCS(%s): %v", bucket, err)
	}
	t.Cleanup(func() { _ = g.Close() })
	return g
}

func TestDirPrefixBytes(t *testing.T) {
	ctx := context.Background()
	d := Dir{Root: t.TempDir()}
	n, err := d.PrefixBytes(ctx, "t/a/files/")
	if err != nil || n != 0 {
		t.Fatalf("empty prefix: %d %v", n, err)
	}
	if err := d.Put(ctx, "t/a/files/x", []byte("hello")); err != nil {
		t.Fatal(err)
	}
	if err := d.Put(ctx, "t/b/files/x", []byte("xxxxxxxx")); err != nil {
		t.Fatal(err)
	}
	n, err = d.PrefixBytes(ctx, "t/a/files/")
	if err != nil || n != 5 {
		t.Fatalf("tenant a: %d %v", n, err)
	}
	n, err = d.PrefixBytes(ctx, "t/b/files/")
	if err != nil || n != 8 {
		t.Fatalf("tenant b: %d %v", n, err)
	}
}
