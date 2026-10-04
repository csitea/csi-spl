package hub_test

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The Docs section: GET /v1/docs/{path...} serves the published repo .md and
// tree.json to a signed-in member, nothing else, and is off without a bucket.

func getDoc(t *testing.T, e *env, tid, path, as string) (int, string, http.Header) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/docs/"+path, nil)
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), resp.Header
}

func TestDocsServesPublishedTree(t *testing.T) {
	root := t.TempDir()
	put := func(p, body string) {
		f := filepath.Join(root, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	put("tree.json", `{"files":[]}`)
	put("csi-spl-doc/specs/072-x/spec.md", "# Spec 072\n")
	put("secret.txt", "no")
	e := rbacEnv(t, func(o *hub.Options) { o.Docs = blob.Dir{Root: root} })
	tid, _ := e.tenant()
	hum := seat(t, e, tid, rbac.Tester)

	code, body, h := getDoc(t, e, tid, "csi-spl-doc/specs/072-x/spec.md", hum)
	if code != http.StatusOK || body != "# Spec 072\n" {
		t.Fatalf("doc: %d %q", code, body)
	}
	if ct := h.Get("Content-Type"); ct != "text/markdown; charset=utf-8" || h.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("doc headers: %q %q", ct, h.Get("X-Content-Type-Options"))
	}
	if code, body, h = getDoc(t, e, tid, "tree.json", hum); code != http.StatusOK || body != `{"files":[]}` || h.Get("Content-Type") != "application/json; charset=utf-8" {
		t.Fatalf("tree: %d %q %q", code, body, h.Get("Content-Type"))
	}
	if code, _, _ = getDoc(t, e, tid, "csi-spl-doc/nope.md", hum); code != http.StatusNotFound {
		t.Fatalf("missing doc: %d", code)
	}
	// CONTROLS: no session, a non-.md key and a dot segment never reach the store
	if code, _, _ = getDoc(t, e, tid, "tree.json", ""); code == http.StatusOK {
		t.Fatalf("no session read the tree: %d", code)
	}
	for _, p := range []string{"secret.txt", "csi-spl-doc/../secret.md", ".hidden/x.md", "a//b.md"} {
		if code, _, _ = getDoc(t, e, tid, p, hum); code != http.StatusNotFound {
			t.Fatalf("%s: %d, want 404", p, code)
		}
	}
}

func TestDocsOffWithoutBucket(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	hum := seat(t, e, tid, rbac.Tester)
	if code, body, _ := getDoc(t, e, tid, "tree.json", hum); code != http.StatusNotFound || !strings.Contains(body, "docs_off") {
		t.Fatalf("off: %d %q", code, body)
	}
}

func TestValidDocsPath(t *testing.T) {
	for p, want := range map[string]bool{
		"tree.json": true, "README.md": true, "csi-spl-doc/specs/072-rapid-deployability/spec.md": true,
		"x.txt": false, "../a.md": false, "a/./b.md": false, "/a.md": false, "a/.git/b.md": false, "a b.md": false,
	} {
		if hub.ValidDocsPath(p) != want {
			t.Errorf("ValidDocsPath(%q) != %v", p, want)
		}
	}
}
