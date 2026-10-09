package hub_test

import (
	"bytes"
	"encoding/json"
	"image"
	"image/png"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 113 T006 follow-up (owner go 33ced864): rename a document, code and
// image items, the image upload, on testkit Postgres. The tests use only the
// wire (no symbol this change added), so on the old code they run and go red
// (measured on 2ad10864d): a create with no title and an add with attrs are
// 400s, the image upload a 405.
//
//	go test ./internal/hub -run 'WorkspaceDoc(Rename|Typed|Image)' -v

// docMediaEnv is docTreeEnv with a workspace docs store (the image bytes).
func docMediaEnv(t *testing.T) (*env, string, string) {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) { o.WorkspaceDocs = wsDocs(t, t.TempDir()) })
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	return e, tid, seat(t, e, tid, "developer")
}

// rawCall sends body as-is with ctype and returns the status, the body and
// the response's Content-Type.
func rawCall(t *testing.T, e *env, tid, method, path, as, ctype string, body []byte) (int, []byte, http.Header) {
	t.Helper()
	req, _ := http.NewRequest(method, e.url(tid)+path, bytes.NewReader(body))
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	req.Header.Set(memberHeader, as)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out, resp.Header
}

// TestWorkspaceDocRename: create with no title, rename, clear the title
// (back to the default), and the four outcomes.
func TestWorkspaceDocRename(t *testing.T) {
	e, tid, as := docMediaEnv(t)
	d := mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "  "}, 200)
	doc := docTreeAPI + "/" + dtStr(d, "id")
	title := func() string { return dtStr(mustCall(t, e, tid, http.MethodGet, doc, as, nil, 200), "title") }
	if got := title(); got != "Untitled document" {
		t.Fatalf("create with no title: %q", got)
	}
	r := mustCall(t, e, tid, http.MethodPatch, doc, as, map[string]any{"title": "Handbook", "rev": 1}, 200)
	if dtNum(r, "rev") != 2 || title() != "Handbook" {
		t.Fatalf("rename: %v, title %q", r, title())
	}
	mustCall(t, e, tid, http.MethodPatch, doc, as, map[string]any{"title": "late", "rev": 1}, 412)
	mustCall(t, e, tid, http.MethodPatch, doc, as, map[string]any{"title": strings.Repeat("x", 501), "rev": 2}, 400)
	r = mustCall(t, e, tid, http.MethodPatch, doc, as, map[string]any{"title": "", "rev": 2}, 200)
	if dtNum(r, "rev") != 3 || title() != "Untitled document" {
		t.Fatalf("clear the title: %v, title %q", r, title())
	}
	other, _ := e.tenant()
	mustCall(t, e, other, http.MethodPatch, doc, seat(t, e, other, "developer"), map[string]any{"title": "theirs"}, 404)
	mustCall(t, e, tid, http.MethodPatch, docTreeAPI+"/"+uuidV4(), as, map[string]any{"title": "x"}, 404)
	if title() != "Untitled document" {
		t.Fatalf("after the refusals: %q", title())
	}
	t.Logf("rename: Untitled -> Handbook -> Untitled (rev 3); stale 412, too long 400, other tenant 404")
}

// TestWorkspaceDocTypedItems: a code block and an image are added with
// their attrs and read back; a code edit lands; a bad kind and an image src
// of another scheme are refused (422) and write nothing.
func TestWorkspaceDocTypedItems(t *testing.T) {
	e, tid, as := docMediaEnv(t)
	d := mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "typed"}, 200)
	doc := docTreeAPI + "/" + dtStr(d, "id")
	code := mustCall(t, e, tid, http.MethodPost, doc+"/items", as, map[string]any{"rev": 1, "where": "child", "title": "Deploy",
		"attrs": map[string]any{"kind": "code", "src": "make deploy", "lang": "sh"}}, 200)
	img := mustCall(t, e, tid, http.MethodPost, doc+"/items", as, map[string]any{"rev": 2, "where": "child", "title": "Diagram",
		"attrs": map[string]any{"kind": "image", "img_http_path": "https://example.com/a.png", "img_name": "a diagram"}}, 200)
	for _, a := range []map[string]any{{"kind": "video"}, {"kind": "image", "img_http_path": "javascript:alert(1)"}} {
		mustCall(t, e, tid, http.MethodPost, doc+"/items", as, map[string]any{"rev": 3, "where": "child", "attrs": a}, 422)
	}
	mustCall(t, e, tid, http.MethodPatch, doc+"/items/"+dtStr(img, "item"), as,
		map[string]any{"field": "attrs", "value": `{"kind":"image","img_http_path":"data:image/png;base64,AA"}`, "rev": 1}, 422)
	mustCall(t, e, tid, http.MethodPatch, doc+"/items/"+dtStr(code, "item"), as,
		map[string]any{"field": "attrs", "value": `{"kind":"code","src":"make deploy ENV=dev","lang":"sh"}`, "rev": 1}, 200)
	kids := dtList(mustCall(t, e, tid, http.MethodGet, doc+"/children", as, nil, 200), "items")
	if len(kids) != 2 {
		t.Fatalf("children: %v, want the two typed items only", kids)
	}
	ca, ia := kids[0]["attrs"].(map[string]any), kids[1]["attrs"].(map[string]any)
	if ca["kind"] != "code" || ca["src"] != "make deploy ENV=dev" || ia["kind"] != "image" || ia["img_name"] != "a diagram" {
		t.Fatalf("attrs read back: %v / %v", ca, ia)
	}
	t.Logf("typed: code %v, image %v; video, javascript: and data: refused", ca, ia)
}

// TestWorkspaceDocImage: an uploaded png is served back byte for byte as
// image/png with nosniff, under a content-addressed name an image item can
// point at; a type the bytes do not match, an svg, another tenant and an
// unknown name are refused.
func TestWorkspaceDocImage(t *testing.T) {
	e, tid, as := docMediaEnv(t)
	d := mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "pics"}, 200)
	doc := docTreeAPI + "/" + dtStr(d, "id")
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewGray(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	pic := buf.Bytes()
	code, out, _ := rawCall(t, e, tid, http.MethodPost, doc+"/images", as, "image/png", pic)
	var up struct {
		Path string `json:"img_http_path"`
	}
	_ = json.Unmarshal(out, &up)
	path := up.Path
	if code != 200 || !strings.HasPrefix(path, doc+"/images/") || !strings.HasSuffix(path, ".png") {
		t.Fatalf("upload: %d %s", code, out)
	}
	code, got, h := rawCall(t, e, tid, http.MethodGet, path, as, "", nil)
	if code != 200 || !bytes.Equal(got, pic) || h.Get("Content-Type") != "image/png" || h.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("read back: %d %d bytes %q %q", code, len(got), h.Get("Content-Type"), h.Get("X-Content-Type-Options"))
	}
	mustCall(t, e, tid, http.MethodPost, doc+"/items", as, map[string]any{"rev": 1, "where": "child", "title": "pic",
		"attrs": map[string]any{"kind": "image", "img_http_path": path, "img_name": "pic"}}, 200)
	refusals := []struct {
		what, method, path, ctype string
		body                      []byte
		want                      int
	}{
		{"png sent as jpeg", http.MethodPost, doc + "/images", "image/jpeg", pic, 415},
		{"svg", http.MethodPost, doc + "/images", "image/svg+xml", []byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>x</script></svg>`), 415},
		{"empty", http.MethodPost, doc + "/images", "image/png", nil, 400},
		{"unknown name", http.MethodGet, doc + "/images/" + strings.Repeat("0", 64) + ".png", "", nil, 404},
		{"bad name", http.MethodGet, doc + "/images/..%2Fx.png", "", nil, 404},
	}
	for _, c := range refusals {
		if code, out, _ := rawCall(t, e, tid, c.method, c.path, as, c.ctype, c.body); code != c.want {
			t.Errorf("%s: %d %s, want %d", c.what, code, out, c.want)
		}
	}
	other, _ := e.tenant()
	if code, _, _ := rawCall(t, e, other, http.MethodGet, path, seat(t, e, other, "developer"), "", nil); code != 404 {
		t.Errorf("another tenant reads the image: %d, want 404", code)
	}
	t.Logf("image: %d bytes up and back at %s; jpeg mismatch, svg, empty, unknown, bad name and other tenant refused", len(pic), path)
}
