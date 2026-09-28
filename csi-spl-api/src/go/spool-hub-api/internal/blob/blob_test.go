package blob

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"testing"
	"time"

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
	testUploaded(t, Dir{Root: t.TempDir()})
}

func TestGCS(t *testing.T) {
	testStore(t, openTestGCS(t))
	testUploaded(t, openTestGCS(t))
}

// testUploaded is the Uploaded / Touch / List contract the file retention
// rests on: an absent key is ErrNotFound, Touch moves Uploaded
// forward, and List names every object under a prefix with that time.
func testUploaded(t *testing.T, s Store) {
	t.Helper()
	ctx := context.Background()
	tenant := "t-" + uid()
	data := []byte("uploaded " + tenant)
	sum := sha256.Sum256(data)
	key, _ := Key(tenant, hex.EncodeToString(sum[:]))
	if _, err := s.Uploaded(ctx, key); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Uploaded of an absent key: %v", err)
	}
	if err := s.Touch(ctx, key); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Touch of an absent key: %v", err)
	}
	before := time.Now().Add(-time.Minute)
	if err := s.Put(ctx, key, data); err != nil {
		t.Fatal(err)
	}
	up, err := s.Uploaded(ctx, key)
	if err != nil || up.Before(before) {
		t.Fatalf("Uploaded after Put: %v %v", up, err)
	}
	if d, ok := s.(Dir); ok { // backdate, so Touch has something to move
		old := time.Now().Add(-48 * time.Hour)
		os.Chtimes(d.path(key), old, old) //nolint:errcheck
		if up, _ = s.Uploaded(ctx, key); up.After(before) {
			t.Fatalf("backdate did not stick: %v", up)
		}
	}
	time.Sleep(10 * time.Millisecond)
	if err := s.Touch(ctx, key); err != nil {
		t.Fatalf("Touch: %v", err)
	}
	touched, err := s.Uploaded(ctx, key)
	if err != nil || !touched.After(up) {
		t.Fatalf("Uploaded after Touch: %v (was %v) %v", touched, up, err)
	}
	var seen []string
	if err := s.List(ctx, "t/"+tenant+"/", func(k string, at time.Time) error {
		seen = append(seen, k)
		if !at.Equal(touched) {
			t.Errorf("List time %v, Uploaded %v", at, touched)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(seen) != 1 || seen[0] != key {
		t.Fatalf("List = %v, want [%s]", seen, key)
	}
	s.Delete(ctx, key) //nolint:errcheck
}

// CONTROL for the aborted-upload cleanup (027 T020): what a finalize racing
// the abort leaves behind is an ordinary object sitting at the tmp key, and
// deleteUntilGone must not return until that key is really gone. One delete
// was not enough on a slow runner -- run 35634691126 read "failed PutReader
// left an object at its key" -- so this asserts the postcondition, not the
// call. The second half is the idempotence the retry loop depends on: an
// absent key is success, never an error.
func TestGCSDeleteUntilGone(t *testing.T) {
	g := openTestGCS(t)
	ctx := context.Background()
	key := TmpKey("t-"+uid(), uid())
	if err := g.Put(ctx, key, []byte("bytes a finalize left behind")); err != nil {
		t.Fatal(err)
	}
	if ok, err := g.Exists(ctx, key); err != nil || !ok {
		t.Fatalf("the planted object is not there: %v %v", ok, err)
	}
	if err := g.deleteUntilGone(ctx, key); err != nil {
		t.Fatalf("deleteUntilGone: %v", err)
	}
	if ok, err := g.Exists(ctx, key); err != nil || ok {
		t.Fatalf("still present after deleteUntilGone: %v %v", ok, err)
	}
	if err := g.deleteUntilGone(ctx, key); err != nil {
		t.Fatalf("deleteUntilGone on an absent key must be nil, got %v", err)
	}
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
	if err := s.Delete(ctx, other); !errors.Is(err, ErrNotFound) {
		t.Fatalf("delete under another tenant prefix: %v", err)
	}
	if err := s.Delete(ctx, key); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := s.Get(ctx, key); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get after delete: %v", err)
	}
	if err := s.Delete(ctx, key); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second delete: %v", err)
	}
	testStream(t, s)
}

type failAfter struct{ n int }

func (f *failAfter) Read(p []byte) (int, error) {
	if f.n <= 0 {
		return 0, errors.New("client went away")
	}
	k := min(len(p), f.n)
	f.n -= k
	return k, nil
}

// testStream is the streamed-upload contract (027 T020): PutReader to a
// TmpKey, Promote to the content key; a second Promote of the same bytes
// keeps one object and removes its tmp; a failed PutReader leaves nothing.
func testStream(t *testing.T, s Store) {
	t.Helper()
	ctx := context.Background()
	tenant := "t-" + uid()
	data := make([]byte, 3<<20+7) // spans several GCS chunks
	rand.Read(data)               //nolint:errcheck
	sum := sha256.Sum256(data)
	key, _ := Key(tenant, hex.EncodeToString(sum[:]))
	for i, wantExisted := range []bool{false, true} {
		tmp := TmpKey(tenant, uid())
		n, err := s.PutReader(ctx, tmp, bytes.NewReader(data))
		if err != nil || n != int64(len(data)) {
			t.Fatalf("PutReader %d: %d %v", i, n, err)
		}
		existed, err := s.Promote(ctx, tmp, key)
		if err != nil || existed != wantExisted {
			t.Fatalf("Promote %d: existed=%v %v", i, existed, err)
		}
		if ok, _ := s.Exists(ctx, tmp); ok {
			t.Fatalf("tmp %s left after Promote %d", tmp, i)
		}
	}
	r, err := s.Get(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(r)
	r.Close()
	if !bytes.Equal(got, data) {
		t.Fatal("promoted bytes differ")
	}
	if n, _ := s.PrefixBytes(ctx, "t/"+tenant+"/files/"); n != int64(len(data)) {
		t.Fatalf("PrefixBytes after dup promote: %d, want one object of %d", n, len(data))
	}
	tmp := TmpKey(tenant, uid())
	if _, err := s.PutReader(ctx, tmp, &failAfter{n: 2 << 20}); err == nil {
		t.Fatal("PutReader of a failing reader succeeded")
	}
	if ok, _ := s.Exists(ctx, tmp); ok {
		t.Fatal("failed PutReader left an object at its key")
	}
	if n, _ := s.PrefixBytes(ctx, "tmp/"+tenant+"/"); n != 0 {
		t.Fatalf("failed PutReader left %d bytes under tmp/", n)
	}
	s.Delete(ctx, key) //nolint:errcheck
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
