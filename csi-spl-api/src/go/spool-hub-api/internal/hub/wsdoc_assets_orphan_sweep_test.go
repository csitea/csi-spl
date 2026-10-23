package hub_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/storage"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 114 R3 left a workspace's Qto pictures in its own docs store at
// qto-assets/<sha256>, and the file retention sweep listed only the shared
// store: a picture no doc names stayed there for ever (SPL-2963). Red
// control: on the sweep without the own-store walk, the gone doc's picture
// survives and TestWorkspaceDocAssetOwnSweep fails on it.
//
//	go test ./internal/hub -run 'WorkspaceDocAssetOwnSweep' -v

// missingBucket is a workspace's store whose bucket does not exist yet (dev
// before step 052's apply): every List fails with the provider's error.
type missingBucket struct {
	blob.Dir
	err error
}

func (m missingBucket) List(context.Context, string, func(string, time.Time) error) error {
	return m.err
}

// s3NoBucket is the S3 API's answer for a bucket that does not exist.
type s3NoBucket struct{}

func (s3NoBucket) Error() string     { return "api error NoSuchBucket: no such bucket" }
func (s3NoBucket) ErrorCode() string { return "NoSuchBucket" }

// ownKeys lists qto-assets/ of tenant's own store.
func ownKeys(t *testing.T, d *hub.WorkspaceDocs, tid string) map[string]bool {
	t.Helper()
	st, err := d.Store(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	err = st.List(context.Background(), hub.DocAssetPrefix, func(k string, _ time.Time) error {
		out[k] = true
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// ageOwn sets the upload time of key in tenant's own store.
func ageOwn(t *testing.T, d *hub.WorkspaceDocs, tid, key string, at time.Time) {
	t.Helper()
	if err := os.Chtimes(filepath.Join(mustLoc(t, d, tid), filepath.FromSlash(key)), at, at); err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceDocAssetOwnSweep(t *testing.T) {
	root := t.TempDir()
	var gcsGone, s3Gone string // tenants whose bucket does not exist
	d, err := hub.NewWorkspaceDocs(filepath.Join(root, "{tenant}"), func(_ context.Context, dir string) (blob.Store, error) {
		switch filepath.Base(dir) {
		case gcsGone:
			return missingBucket{blob.Dir{Root: dir}, fmt.Errorf("list: %w", storage.ErrBucketNotExist)}, nil
		case s3Gone:
			return missingBucket{blob.Dir{Root: dir}, fmt.Errorf("list: %w", s3NoBucket{})}, nil
		}
		return blob.Dir{Root: dir}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	e := rbacEnv(t, func(o *hub.Options) { o.WorkspaceDocs = d })
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	ctx := context.Background()
	tid, _ := e.tenant()
	gcsGone, _ = e.tenant()
	s3Gone, _ = e.tenant()
	as := seat(t, e, tid, "developer")
	put := func(title, path string, pic []byte) string {
		t.Helper()
		doc := docTreeAPI + "/" + dtStr(mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": title}, 200), "id")
		if code, out, _ := rawCall(t, e, tid, http.MethodPut, doc+"/assets/"+path, as, "image/png", pic); code != 200 {
			t.Fatalf("put %s: %d %s", path, code, out)
		}
		return doc
	}
	kept, gone, young := pngOf(t, 61), pngOf(t, 62), pngOf(t, 63)
	put("kept", "kept.assets/01-a.png", kept)
	goneDoc := put("gone", "gone.assets/01-b.png", gone)
	mustCall(t, e, tid, http.MethodDelete, goneDoc, as, nil, 200)
	youngDoc := put("young", "young.assets/01-c.png", young)
	mustCall(t, e, tid, http.MethodDelete, youngDoc, as, nil, 200)
	st, _ := d.Store(ctx, tid)
	if err := st.Put(ctx, "notes.md", []byte("x")); err != nil { // a doc, not a picture
		t.Fatal(err)
	}
	old := time.Now().Add(-2 * hub.FileOrphanGrace)
	k := func(b []byte) string { return hub.DocAssetPrefix + shaHex(b) }
	for _, key := range []string{k(kept), k(gone), "notes.md"} {
		ageOwn(t, d, tid, key, old)
	}
	if n := len(ownKeys(t, d, tid)); n != 3 {
		t.Fatalf("before the sweep: %d pictures in qto-assets/, want 3", n)
	}
	r, err := e.srv.SweepFiles(ctx, time.Now())
	if err != nil {
		t.Fatalf("sweep (2 workspaces with no bucket): %v", err)
	}
	after := ownKeys(t, d, tid)
	if after[k(gone)] {
		t.Fatalf("the picture of a deleted doc outlived the sweep in the workspace's own store (%d pictures left, deleted %d)", len(after), r.Deleted)
	}
	if !after[k(kept)] {
		t.Fatalf("CONTROL: the sweep deleted a picture a doc still names")
	}
	if !after[k(young)] {
		t.Fatalf("CONTROL: the sweep deleted an unnamed picture younger than the grace")
	}
	if _, err := os.Stat(filepath.Join(mustLoc(t, d, tid), "notes.md")); err != nil {
		t.Fatalf("CONTROL: the sweep touched a key outside qto-assets/: %v", err)
	}
	// Another workspace's doc naming the same bytes keeps nothing here.
	other, _ := e.tenant()
	oas := seat(t, e, other, "developer")
	odoc := docTreeAPI + "/" + dtStr(mustCall(t, e, other, http.MethodPost, docTreeAPI, oas, map[string]any{"title": "other"}, 200), "id")
	if code, out, _ := rawCall(t, e, other, http.MethodPut, odoc+"/assets/other.assets/01-y.png", oas, "image/png", young); code != 200 {
		t.Fatalf("put in the other workspace: %d %s", code, out)
	}
	ageOwn(t, d, tid, k(young), old)
	if _, err := e.srv.SweepFiles(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if ownKeys(t, d, tid)[k(young)] {
		t.Fatalf("a doc of another workspace kept this workspace's unnamed picture")
	}
	if !ownKeys(t, d, other)[k(young)] {
		t.Fatalf("CONTROL: the other workspace's named picture is gone")
	}
	// Bytes already there, uploaded again: their upload time restarts.
	ageOwn(t, d, tid, k(kept), old)
	put("again", "again.assets/01-a.png", kept)
	if up, err := st.Uploaded(ctx, k(kept)); err != nil || time.Since(up) > time.Hour {
		t.Fatalf("a re-upload of bytes already stored kept the old upload time %v (%v)", up, err)
	}
	t.Logf("own sweep: 3 pictures, the gone doc's one deleted, the named one and the young one kept, notes.md kept; " +
		"then the young one aged is deleted although another workspace names the same bytes; a re-upload restarts the upload time; 2 workspaces with no bucket skipped")
}

// TestWorkspaceDocAssetOwnSweepError: a store error other than a missing
// bucket is the sweep's error, and the other workspaces are still swept.
func TestWorkspaceDocAssetOwnSweepError(t *testing.T) {
	root := t.TempDir()
	var broken string
	d, err := hub.NewWorkspaceDocs(filepath.Join(root, "{tenant}"), func(_ context.Context, dir string) (blob.Store, error) {
		if filepath.Base(dir) == broken {
			return missingBucket{blob.Dir{Root: dir}, errors.New("list: 503 backend unavailable")}, nil
		}
		return blob.Dir{Root: dir}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	e := rbacEnv(t, func(o *hub.Options) { o.WorkspaceDocs = d })
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	ctx := context.Background()
	broken, _ = e.tenant()
	tid, _ := e.tenant()
	st, err := d.Store(ctx, tid)
	if err != nil {
		t.Fatal(err)
	}
	stray := hub.DocAssetPrefix + strings.Repeat("5", 64)
	if err := st.Put(ctx, stray, []byte("stray")); err != nil {
		t.Fatal(err)
	}
	ageOwn(t, d, tid, stray, time.Now().Add(-2*hub.FileOrphanGrace))
	_, err = e.srv.SweepFiles(ctx, time.Now())
	if err == nil || !strings.Contains(err.Error(), "503 backend unavailable") {
		t.Fatalf("sweep with a broken store: %v, want its error", err)
	}
	if ownKeys(t, d, tid)[stray] {
		t.Fatalf("a broken workspace store stopped the sweep of the others")
	}
	t.Logf("own sweep: a broken store is the sweep's error, the other workspace's stray picture still deleted")
}
