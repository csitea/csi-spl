package hub_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Gap G6 (SPL-2201, spec 137 unified-fs.md section 7): a doc's pictures
// under their md-relative path <doc>.assets/NN-name.ext, the bytes in the
// object store at t/<tenant>/files/<sha256>, the path -> sha256 map in the
// root's attrs.assets, and retention keeping what a doc names. The tests use
// only the wire and SweepFiles, so on the old code they run and go red (the
// asset route is a 404, and the sweep deletes the picture's blob).
//
//	go test ./internal/hub -run 'WorkspaceDocAsset' -v

// docAssetEnv is a Postgres hub with one developer seat.
func docAssetEnv(t *testing.T) (*env, string, string) {
	t.Helper()
	e := rbacEnv(t)
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	return e, tid, seat(t, e, tid, "developer")
}

// pngOf is a 2x2 png of one grey level: a distinct byte string per level.
func pngOf(t *testing.T, level uint8) []byte {
	t.Helper()
	img := image.NewGray(image.Rect(0, 0, 2, 2))
	for i := range img.Pix {
		img.Pix[i] = level
	}
	img.SetGray(0, 0, color.Gray{Y: level})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func shaHex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// rootItem is the doc's hidden root as the read answers it.
func rootItem(t *testing.T, e *env, tid, doc, as string) map[string]any {
	t.Helper()
	root := dtStr(mustCall(t, e, tid, http.MethodGet, doc, as, nil, 200), "root")
	items := dtList(mustCall(t, e, tid, http.MethodGet, doc+"/subtree?item="+root, as, nil, 200), "items")
	if len(items) == 0 || dtStr(items[0], "id") != root {
		t.Fatalf("subtree of the root %s: %v", root, items)
	}
	return items[0]
}

// rootAssets is the root's attrs.assets as the read answers it.
func rootAssets(t *testing.T, e *env, tid, doc, as string) map[string]any {
	t.Helper()
	a, _ := rootItem(t, e, tid, doc, as)["attrs"].(map[string]any)
	m, _ := a["assets"].(map[string]any)
	return m
}

// TestWorkspaceDocAsset: two pictures go up under their relative paths and
// come back byte for byte; the root maps each path to its sha256 and the
// bytes sit at the tenant's content key; a path uploaded again serves the
// new bytes; a path off the layout, a type mismatch, an svg, an empty body,
// an unknown path, another tenant and a malformed attrs.assets are refused.
func TestWorkspaceDocAsset(t *testing.T) {
	e, tid, as := docAssetEnv(t)
	d := mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "guide"}, 200)
	doc := docTreeAPI + "/" + dtStr(d, "id")
	one, two := pngOf(t, 10), pngOf(t, 200)
	for p, b := range map[string][]byte{"guide.assets/01-flow-map.png": one, "guide.assets/02-arch.png": two} {
		code, out, _ := rawCall(t, e, tid, http.MethodPut, doc+"/assets/"+p, as, "image/png", b)
		var up struct {
			Path, SHA256 string
			Bytes        int
		}
		_ = json.Unmarshal(out, &up)
		if code != 200 || up.Path != p || up.SHA256 != shaHex(b) || up.Bytes != len(b) {
			t.Fatalf("put %s: %d %s", p, code, out)
		}
	}
	for p, b := range map[string][]byte{"guide.assets/01-flow-map.png": one, "guide.assets/02-arch.png": two} {
		code, got, h := rawCall(t, e, tid, http.MethodGet, doc+"/assets/"+p, as, "", nil)
		if code != 200 || !bytes.Equal(got, b) || h.Get("Content-Type") != "image/png" || h.Get("X-Content-Type-Options") != "nosniff" {
			t.Fatalf("get %s: %d, %d bytes, %q %q", p, code, len(got), h.Get("Content-Type"), h.Get("X-Content-Type-Options"))
		}
		key, _ := blob.Key(tid, shaHex(b))
		if _, err := os.Stat(filepath.Join(e.blobs, filepath.FromSlash(key))); err != nil {
			t.Fatalf("%s: no blob at the tenant's content key %s: %v", p, key, err)
		}
	}
	m := rootAssets(t, e, tid, doc, as)
	if len(m) != 2 || m["guide.assets/01-flow-map.png"] != shaHex(one) || m["guide.assets/02-arch.png"] != shaHex(two) {
		t.Fatalf("root attrs.assets: %v", m)
	}
	three := pngOf(t, 99)
	if code, out, _ := rawCall(t, e, tid, http.MethodPut, doc+"/assets/guide.assets/02-arch.png", as, "image/png", three); code != 200 {
		t.Fatalf("put again: %d %s", code, out)
	}
	if _, got, _ := rawCall(t, e, tid, http.MethodGet, doc+"/assets/guide.assets/02-arch.png", as, "", nil); !bytes.Equal(got, three) {
		t.Fatalf("a path uploaded again serves the old bytes")
	}
	refusals := []struct {
		what, method, path, ctype string
		body                      []byte
		want                      int
	}{
		{"upper-case name", http.MethodPut, "guide.assets/01-Flow.png", "image/png", one, 400},
		{"no number", http.MethodPut, "guide.assets/flow.png", "image/png", one, 400},
		{"not under .assets", http.MethodPut, "img/01-flow.png", "image/png", one, 400},
		{"svg path", http.MethodPut, "guide.assets/01-x.svg", "image/svg+xml", []byte(`<svg xmlns="http://www.w3.org/2000/svg"/>`), 400},
		{"png at a .jpg path", http.MethodPut, "guide.assets/03-x.jpg", "image/jpeg", one, 415},
		{"png sent as jpeg", http.MethodPut, "guide.assets/03-x.png", "image/jpeg", one, 415},
		{"empty", http.MethodPut, "guide.assets/03-x.png", "image/png", nil, 400},
		{"unknown path", http.MethodGet, "guide.assets/09-none.png", "", nil, 404},
	}
	for _, c := range refusals {
		if code, out, _ := rawCall(t, e, tid, c.method, doc+"/assets/"+c.path, as, c.ctype, c.body); code != c.want {
			t.Errorf("%s: %d %s, want %d", c.what, code, out, c.want)
		}
	}
	other, _ := e.tenant()
	if code, _, _ := rawCall(t, e, other, http.MethodGet, doc+"/assets/guide.assets/01-flow-map.png", seat(t, e, other, "developer"), "", nil); code != 404 {
		t.Errorf("another tenant reads the picture: %d, want 404", code)
	}
	ri := rootItem(t, e, tid, doc, as)
	root, rev := dtStr(ri, "id"), int(ri["rev"].(float64))
	for _, bad := range []string{`{"assets":{"../x.png":"` + shaHex(one) + `"}}`, `{"assets":{"guide.assets/01-a.png":"nope"}}`, `{"assets":"x"}`} {
		mustCall(t, e, tid, http.MethodPatch, doc+"/items/"+root, as, map[string]any{"field": "attrs", "value": bad, "rev": rev}, 422)
	}
	if len(rootAssets(t, e, tid, doc, as)) != 2 {
		t.Fatalf("a refused attrs edit changed attrs.assets")
	}
	t.Logf("assets: 2 pictures up and back, mapped in attrs.assets, re-upload served; 8 bad requests, another tenant and 3 bad attrs refused")
}

// TestWorkspaceDocAssetRetention: a doc's picture outlives the orphan grace
// with no message carrying it; the CONTROL, a blob of the same age no doc
// names, is deleted by the same sweep. Once the doc is gone the next sweep
// deletes the picture too.
func TestWorkspaceDocAssetRetention(t *testing.T) {
	e, tid, as := docAssetEnv(t)
	d := mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "kept"}, 200)
	doc := docTreeAPI + "/" + dtStr(d, "id")
	pic := pngOf(t, 42)
	if code, out, _ := rawCall(t, e, tid, http.MethodPut, doc+"/assets/kept.assets/01-pic.png", as, "image/png", pic); code != 200 {
		t.Fatalf("put: %d %s", code, out)
	}
	stray := strings.Repeat("7", 64)
	strayKey, _ := blob.Key(tid, stray)
	if err := (blob.Dir{Root: e.blobs}).Put(context.Background(), strayKey, []byte("stray")); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-48 * time.Hour)
	ageBlob(t, e, tid, shaHex(pic), old)
	ageBlob(t, e, tid, stray, old)
	if _, err := e.srv.SweepFiles(context.Background(), time.Now()); err != nil {
		t.Fatal(err)
	}
	picKey, _ := blob.Key(tid, shaHex(pic))
	exists := func(key string) bool {
		_, err := os.Stat(filepath.Join(e.blobs, filepath.FromSlash(key)))
		return err == nil
	}
	if exists(strayKey) {
		t.Fatalf("CONTROL: the sweep kept a blob nothing names")
	}
	if !exists(picKey) {
		t.Fatalf("the sweep deleted a doc's picture")
	}
	mustCall(t, e, tid, http.MethodDelete, doc, as, nil, 200)
	if _, err := e.srv.SweepFiles(context.Background(), time.Now()); err != nil {
		t.Fatal(err)
	}
	if exists(picKey) {
		t.Fatalf("the picture of a deleted doc outlived the sweep")
	}
	t.Logf("retention: picture kept while its doc names it, deleted after; the unnamed control deleted")
}
