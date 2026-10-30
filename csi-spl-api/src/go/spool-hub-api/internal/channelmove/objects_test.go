package channelmove

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

const (
	srcT = "src-ws"
	dstT = "dst-ws"
)

// rows is the database side of a test: which tenant's rows list a blob.
type rows struct {
	attached map[string]map[string]bool // tenant -> file id
	docs     map[string]map[string]bool // tenant -> asset id
}

func newRows() *rows {
	return &rows{attached: map[string]map[string]bool{}, docs: map[string]map[string]bool{}}
}

func put(m map[string]map[string]bool, tenant, id string, on bool) {
	if m[tenant] == nil {
		m[tenant] = map[string]bool{}
	}
	m[tenant][id] = on
}

func (r *rows) FileAttached(_ context.Context, tenant, id string, _ time.Time) (bool, error) {
	return r.attached[tenant][id], nil
}

func (r *rows) DocAssetHeld(_ context.Context, tenant, id string) (bool, error) {
	return r.docs[tenant][id], nil
}

func blobOf(t *testing.T, s string) (string, []byte) {
	t.Helper()
	b := []byte(s)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), b
}

func seed(t *testing.T, st blob.Store, key string, b []byte) {
	t.Helper()
	if err := st.Put(context.Background(), key, b); err != nil {
		t.Fatal(err)
	}
}

func fkey(tenant, id string) string { k, _ := blob.Key(tenant, id); return k }

func exists(t *testing.T, st blob.Store, key string) bool {
	t.Helper()
	ok, err := st.Exists(context.Background(), key)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// read is what a staying post's reader gets: the bytes, or the 404.
func read(t *testing.T, o Objects, tenant, id string) ([]byte, error) {
	t.Helper()
	rc, err := o.Open(context.Background(), tenant, id)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

// moveRows is P4 for the test: the moved post's rows leave src for dst.
func moveRows(r *rows, ids ...string) {
	for _, id := range ids {
		put(r.attached, srcT, id, false)
		put(r.attached, dstT, id, true)
	}
}

// C6: a blob also attached in a staying channel is copied, not deleted in
// <SRC>; a blob only the set carries leaves <SRC>.
func TestC6SharedFileKeptInSource(t *testing.T) {
	ctx := context.Background()
	files := blob.Dir{Root: t.TempDir()}
	r := newRows()
	own, ownB := blobOf(t, "only the moved channel carries me")
	shared, sharedB := blobOf(t, "a staying channel carries me too")
	seed(t, files, fkey(srcT, own), ownB)
	seed(t, files, fkey(srcT, shared), sharedB)
	put(r.attached, srcT, own, true)
	put(r.attached, srcT, shared, true)
	o := Objects{Files: files, Held: r}
	set := ObjectSet{Files: []string{own, shared}}

	if rep, err := o.Copy(ctx, srcT, dstT, set); err != nil || rep.Copied != 2 {
		t.Fatalf("P3 copy: %+v %v, want 2 copied", rep, err)
	}
	moveRows(r, own)                    // only the moved post's row leaves <SRC> ...
	put(r.attached, dstT, shared, true) // ... and the shared blob's moved post too
	rep, err := o.Delete(ctx, srcT, dstT, set)
	if err != nil {
		t.Fatalf("P6 delete: %v", err)
	}
	if rep.Deleted != 1 || len(rep.Kept) != 1 || rep.Kept[0] != fkey(srcT, shared) {
		t.Fatalf("P6 report %+v, want 1 deleted and the shared key kept", rep)
	}
	if b, err := read(t, o, srcT, shared); err != nil || !bytes.Equal(b, sharedB) {
		t.Fatalf("staying post's file in <SRC>: %q %v, want its bytes", b, err)
	}
	if exists(t, files, fkey(srcT, own)) {
		t.Fatal("the set's own blob is still in <SRC>")
	}
	for _, id := range set.Files {
		if !exists(t, files, fkey(dstT, id)) {
			t.Fatalf("<DST> lacks %s", id)
		}
	}
}

// C10: a moved file read from <SRC> is 404 although another hub instance's
// LRU still holds its bytes; read from <DST> it is the bytes.
func TestC10MovedFileNotServedFromSourceCache(t *testing.T) {
	ctx := context.Background()
	dir := blob.Dir{Root: t.TempDir()}
	// Two hub instances over one bucket: a delete through one does not evict
	// the other's cache.
	warm := blob.NewCached(dir, 1<<20, 1<<20, time.Hour)
	other := blob.NewCached(dir, 1<<20, 1<<20, time.Hour)
	r := newRows()
	id, b := blobOf(t, "a picture in the moved channel")
	seed(t, dir, fkey(srcT, id), b)
	put(r.attached, srcT, id, true)
	reader := Objects{Files: warm, Held: r}
	if got, err := read(t, reader, srcT, id); err != nil || !bytes.Equal(got, b) {
		t.Fatalf("before the move: %q %v", got, err)
	}

	mover := Objects{Files: other, Held: r}
	set := ObjectSet{Files: []string{id}}
	if _, err := mover.Copy(ctx, srcT, dstT, set); err != nil {
		t.Fatal(err)
	}
	moveRows(r, id)
	if _, err := mover.Delete(ctx, srcT, dstT, set); err != nil {
		t.Fatal(err)
	}

	if got, err := read(t, reader, srcT, id); !errors.Is(err, blob.ErrNotFound) {
		t.Fatalf("<SRC> read after the move: %q %v, want ErrNotFound (404)", got, err)
	}
	if got, err := read(t, reader, dstT, id); err != nil || !bytes.Equal(got, b) {
		t.Fatalf("<DST> read after the move: %q %v, want the bytes", got, err)
	}
	// The control: the cache alone, without the database, still serves the
	// <SRC> bytes; this is what Open must not do.
	rc, err := warm.Get(ctx, fkey(srcT, id))
	if err != nil {
		t.Fatalf("control: the warm cache lost the entry (%v); the case proves nothing", err)
	}
	rc.Close()
}

// P3 re-run: everything already in <DST> counts Present, nothing is rewritten.
func TestCopyIsIdempotent(t *testing.T) {
	ctx := context.Background()
	files := blob.Dir{Root: t.TempDir()}
	id, b := blobOf(t, "once")
	seed(t, files, fkey(srcT, id), b)
	o := Objects{Files: files, Held: newRows()}
	set := ObjectSet{Files: []string{id}}
	if rep, err := o.Copy(ctx, srcT, dstT, set); err != nil || rep.Copied != 1 {
		t.Fatalf("first copy %+v %v", rep, err)
	}
	if rep, err := o.Copy(ctx, srcT, dstT, set); err != nil || rep.Copied != 0 || rep.Present != 1 {
		t.Fatalf("re-run %+v %v, want 1 present", rep, err)
	}
}

// A source object whose bytes do not hash to its id is never copied.
func TestCopyRefusesBadContentAddress(t *testing.T) {
	files := blob.Dir{Root: t.TempDir()}
	id, _ := blobOf(t, "the real bytes")
	seed(t, files, fkey(srcT, id), []byte("other bytes"))
	o := Objects{Files: files, Held: newRows()}
	_, err := o.Copy(context.Background(), srcT, dstT, ObjectSet{Files: []string{id}})
	if err == nil || !strings.Contains(err.Error(), "do not hash") {
		t.Fatalf("err %v, want a hash refusal", err)
	}
	if exists(t, files, fkey(dstT, id)) {
		t.Fatal("bad bytes reached <DST>")
	}
}

// A missing source is an error, not a silent skip.
func TestCopyMissingSource(t *testing.T) {
	id, _ := blobOf(t, "never stored")
	o := Objects{Files: blob.Dir{Root: t.TempDir()}, Held: newRows()}
	_, err := o.Copy(context.Background(), srcT, dstT, ObjectSet{Files: []string{id}})
	if !errors.Is(err, blob.ErrNotFound) {
		t.Fatalf("err %v, want ErrNotFound", err)
	}
}

// P6 never deletes the only copy: no <DST> object = refused, <SRC> intact.
func TestDeleteRefusesWithoutDestinationCopy(t *testing.T) {
	files := blob.Dir{Root: t.TempDir()}
	id, b := blobOf(t, "not yet copied")
	seed(t, files, fkey(srcT, id), b)
	o := Objects{Files: files, Held: newRows()}
	_, err := o.Delete(context.Background(), srcT, dstT, ObjectSet{Files: []string{id}})
	if err == nil || !strings.Contains(err.Error(), "refuse") {
		t.Fatalf("err %v, want a refusal", err)
	}
	if !exists(t, files, fkey(srcT, id)) {
		t.Fatal("<SRC> object deleted with no <DST> copy")
	}
}

// P6 re-run after a crash: what is already gone counts Gone, no error.
func TestDeleteResumes(t *testing.T) {
	ctx := context.Background()
	files := blob.Dir{Root: t.TempDir()}
	id, b := blobOf(t, "resume me")
	seed(t, files, fkey(srcT, id), b)
	o := Objects{Files: files, Held: newRows()}
	set := ObjectSet{Files: []string{id}}
	if _, err := o.Copy(ctx, srcT, dstT, set); err != nil {
		t.Fatal(err)
	}
	if rep, err := o.Delete(ctx, srcT, dstT, set); err != nil || rep.Deleted != 1 {
		t.Fatalf("first delete %+v %v", rep, err)
	}
	if rep, err := o.Delete(ctx, srcT, dstT, set); err != nil || rep.Gone != 1 || rep.Deleted != 0 {
		t.Fatalf("re-run %+v %v, want 1 gone", rep, err)
	}
}

// M8: a Qto picture moves docs store to docs store; one stored before step
// 052 (in the files bucket) is read from there and lands in <DST>'s docs
// store; a picture a staying doc names is kept in <SRC>.
func TestDocAssetsMoveBetweenDocsStores(t *testing.T) {
	ctx := context.Background()
	files := blob.Dir{Root: t.TempDir()}
	docs := map[string]blob.Store{srcT: blob.Dir{Root: t.TempDir()}, dstT: blob.Dir{Root: t.TempDir()}}
	r := newRows()
	newer, newerB := blobOf(t, "picture in the docs store")
	legacy, legacyB := blobOf(t, "picture from before 052")
	shared, sharedB := blobOf(t, "picture a staying doc names")
	seed(t, docs[srcT], docAssetPrefix+newer, newerB)
	seed(t, files, fkey(srcT, legacy), legacyB)
	seed(t, docs[srcT], docAssetPrefix+shared, sharedB)
	o := Objects{Files: files, Held: r,
		Docs: func(_ context.Context, tenant string) (blob.Store, error) { return docs[tenant], nil }}
	set := ObjectSet{DocAssets: []string{newer, legacy, shared}}

	if rep, err := o.Copy(ctx, srcT, dstT, set); err != nil || rep.Copied != 3 {
		t.Fatalf("P3 %+v %v, want 3 copied", rep, err)
	}
	put(r.docs, srcT, shared, true)
	rep, err := o.Delete(ctx, srcT, dstT, set)
	if err != nil {
		t.Fatalf("P6 %v", err)
	}
	if rep.Deleted != 2 || len(rep.Kept) != 2 {
		t.Fatalf("P6 %+v, want 2 deleted and both <SRC> places of the shared picture kept", rep)
	}
	for _, id := range set.DocAssets {
		if !exists(t, docs[dstT], docAssetPrefix+id) {
			t.Fatalf("<DST> docs store lacks %s", id)
		}
	}
	if exists(t, docs[srcT], docAssetPrefix+newer) || exists(t, files, fkey(srcT, legacy)) {
		t.Fatal("a moved picture is still in <SRC>")
	}
	if !exists(t, docs[srcT], docAssetPrefix+shared) {
		t.Fatal("the shared picture left <SRC>")
	}
}
