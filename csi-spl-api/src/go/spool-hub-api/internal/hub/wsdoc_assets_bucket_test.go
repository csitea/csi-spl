package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 114 R3 (section 9.2): a workspace's Qto pictures are written to and
// read from its own docs store (the 052 bucket) at qto-assets/<sha256>, never
// the shared object store (050); a picture stored there before is still read
// until R4 moves it; tenant "system" keeps 050. Red control: with the route
// on the shared store (s.o.Blob.Put) the shared-store and own-store checks
// of TestWorkspaceDocAssetOwnBucket fail.
//
//	go test ./internal/hub -run 'WorkspaceDocAsset(OwnBucket|Quota|System)' -v

// sharedFiles counts the objects under t/<tenant>/files/ of the shared store.
func sharedFiles(t *testing.T, e *env, tid string) int {
	t.Helper()
	n := 0
	err := (blob.Dir{Root: e.blobs}).List(context.Background(), "t/"+tid+"/files/", func(string, time.Time) error {
		n++
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestWorkspaceDocAssetOwnBucket(t *testing.T) {
	d := wsDocs(t, t.TempDir())
	e := rbacEnv(t, func(o *hub.Options) { o.WorkspaceDocs = d })
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	as := seat(t, e, tid, "developer")
	doc := docTreeAPI + "/" + dtStr(mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "own"}, 200), "id")
	one, two := pngOf(t, 11), pngOf(t, 201)
	for p, b := range map[string][]byte{"own.assets/01-a.png": one, "own.assets/02-b.png": two} {
		if code, out, _ := rawCall(t, e, tid, http.MethodPut, doc+"/assets/"+p, as, "image/png", b); code != 200 {
			t.Fatalf("put %s: %d %s", p, code, out)
		}
		if got := readKey(t, d, tid, hub.DocAssetPrefix+shaHex(b)); got != string(b) {
			t.Fatalf("%s: the workspace's own store holds %d bytes at qto-assets/, want %d", p, len(got), len(b))
		}
		if code, got, _ := rawCall(t, e, tid, http.MethodGet, doc+"/assets/"+p, as, "", nil); code != 200 || !bytes.Equal(got, b) {
			t.Fatalf("get %s: %d, %d bytes", p, code, len(got))
		}
	}
	if n := sharedFiles(t, e, tid); n != 0 {
		t.Fatalf("the shared store holds %d objects of the workspace, want 0", n)
	}
	// The same bytes again: kept, still 0 in the shared store.
	if code, out, _ := rawCall(t, e, tid, http.MethodPut, doc+"/assets/own.assets/03-c.png", as, "image/png", one); code != 200 {
		t.Fatalf("put the same bytes: %d %s", code, out)
	}
	// A picture stored before R3 sits only in the shared store: still served.
	old := pngOf(t, 77)
	key, _ := blob.Key(tid, shaHex(old))
	if err := (blob.Dir{Root: e.blobs}).Put(context.Background(), key, old); err != nil {
		t.Fatal(err)
	}
	ri := rootItem(t, e, tid, doc, as)
	attrs := `{"assets":{"own.assets/01-a.png":"` + shaHex(one) + `","own.assets/02-b.png":"` + shaHex(two) +
		`","own.assets/03-c.png":"` + shaHex(one) + `","own.assets/04-old.png":"` + shaHex(old) + `"}}`
	mustCall(t, e, tid, http.MethodPatch, doc+"/items/"+dtStr(ri, "id"), as, map[string]any{"field": "attrs", "value": attrs, "rev": int(ri["rev"].(float64))}, 200)
	if code, got, _ := rawCall(t, e, tid, http.MethodGet, doc+"/assets/own.assets/04-old.png", as, "", nil); code != 200 || !bytes.Equal(got, old) {
		t.Fatalf("the 050 fallback: %d, %d bytes, want 200 and %d", code, len(got), len(old))
	}
	// Another workspace's own store stays empty and its reader gets 404.
	other, _ := e.tenant()
	if code, _, _ := rawCall(t, e, other, http.MethodGet, doc+"/assets/own.assets/01-a.png", seat(t, e, other, "developer"), "", nil); code != 404 {
		t.Errorf("another tenant reads the picture: %d, want 404", code)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(mustLoc(t, d, tid)), other, "qto-assets")); err == nil {
		t.Errorf("another tenant's store holds qto-assets/")
	}
	t.Logf("own bucket: 2 pictures + 1 duplicate in qto-assets/, 0 in the shared store, the 050 picture served, another tenant 404")
}

// mustLoc is tenant's store location.
func mustLoc(t *testing.T, d *hub.WorkspaceDocs, tid string) string {
	t.Helper()
	loc, err := d.Location(tid)
	if err != nil {
		t.Fatal(err)
	}
	return loc
}

// TestWorkspaceDocAssetQuota: the file quota counts the pictures in the
// workspace's own store when it lists the tenant again (fileusage load).
// CONTROL: the first picture fits; the second one is over only when the
// listing counts the first one's bytes in qto-assets/.
func TestWorkspaceDocAssetQuota(t *testing.T) {
	one, two := pngOf(t, 12), pngOf(t, 202)
	d := wsDocs(t, t.TempDir())
	e := rbacEnv(t, func(o *hub.Options) {
		o.WorkspaceDocs = d
		o.QuotaFileBytes = int64(len(one) + len(two) - 1)
		o.FileUsageTTL = time.Nanosecond // every reserve lists afresh
	})
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	as := seat(t, e, tid, "developer")
	doc := docTreeAPI + "/" + dtStr(mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "quota"}, 200), "id")
	if code, out, _ := rawCall(t, e, tid, http.MethodPut, doc+"/assets/quota.assets/01-a.png", as, "image/png", one); code != 200 {
		t.Fatalf("CONTROL: the first picture: %d %s, want 200", code, out)
	}
	if code, out, _ := rawCall(t, e, tid, http.MethodPut, doc+"/assets/quota.assets/02-b.png", as, "image/png", two); code == 200 {
		t.Fatalf("the second picture passed the quota: %d %s, the own store's bytes were not counted", code, out)
	}
	t.Logf("quota: 1 picture fits, the 2nd is refused once qto-assets/ is counted")
}

// TestWorkspaceDocAssetSystem: tenant "system" (?fs=repo) has no 052 bucket
// and keeps the shared store at t/system/files/<sha256>.
func TestWorkspaceDocAssetSystem(t *testing.T) {
	op := newTenantID("op")
	d := wsDocs(t, t.TempDir())
	e := rbacEnv(t, func(o *hub.Options) { o.OperatorTenant = op; o.WorkspaceDocs = d })
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	admin := seat(t, e, op, rbac.Admin)
	id := dtStr(mustCall(t, e, op, http.MethodPost, docTreeAPI+"?fs=repo", admin, map[string]any{"title": "Repo pic " + op}, 200), "id")
	pic := pngOf(t, 33)
	if code, out, _ := rawCall(t, e, op, http.MethodPut, docTreeAPI+"/"+id+"/assets/pic.assets/01-x.png?fs=repo", admin, "image/png", pic); code != 200 {
		t.Fatalf("put fs=repo: %d %s", code, out)
	}
	key, _ := blob.Key(store.SystemTenant, shaHex(pic))
	if _, err := os.Stat(filepath.Join(e.blobs, filepath.FromSlash(key))); err != nil {
		t.Fatalf("the system picture is not in the shared store at %s: %v", key, err)
	}
	if code, got, _ := rawCall(t, e, op, http.MethodGet, docTreeAPI+"/"+id+"/assets/pic.assets/01-x.png?fs=repo", admin, "", nil); code != 200 || !bytes.Equal(got, pic) {
		t.Fatalf("get fs=repo: %d, %d bytes", code, len(got))
	}
	t.Logf("system: the picture stays in the shared store and is served")
}
