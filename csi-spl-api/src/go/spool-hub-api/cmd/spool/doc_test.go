package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// docsHub is the workspace-docs contract the verbs call: a role=cli hello
// mints an upload token, and the four routes answer with that bearer.
type docsHub struct {
	url   string
	token string

	mu     sync.Mutex
	docs   map[string]docRec
	hits   []docHit
	ws     int
	role   string
	off    bool
	forbid bool
	unauth bool
	boom   bool
}

type docRec struct {
	body string
}

type docHit struct {
	method, path, body, auth, tenant, ctype, ifMatch string
}

func newDocsHub(t *testing.T) *docsHub {
	t.Helper()
	h := &docsHub{token: "tok", docs: map[string]docRec{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", h.wsHello)
	mux.HandleFunc("GET /v1/workspace/docs/tree.json", h.tree)
	mux.HandleFunc("GET /v1/workspace/docs/{path...}", h.get)
	mux.HandleFunc("PUT /v1/workspace/docs/{path...}", h.put)
	mux.HandleFunc("DELETE /v1/workspace/docs/{path...}", h.del)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	h.url = srv.URL
	docEnv(t, srv.URL)
	return h
}

func docEnv(t *testing.T, hub string) {
	t.Helper()
	root, keys := t.TempDir(), t.TempDir()
	if _, err := sign.GenerateKey(keys, "box-a", false); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPOOL_ROOT", root)
	t.Setenv("SPOOL_KEYS_DIR", keys)
	t.Setenv("SPOOL_BOX_ID", "box-a")
	t.Setenv("SPOOL_HUB_URL", hub)
	t.Setenv("SPOOL_TENANT", "t1")
	t.Setenv("SPOOL_MIRROR_LOCAL", "0")
	t.Setenv("SPOOL_MSG_VERSION", "1")
	t.Setenv("SPOOL_SUBMIT_SOCKET", "off")
}

func (h *docsHub) reset(mode string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.docs = map[string]docRec{}
	h.hits = nil
	h.ws = 0
	h.role = ""
	h.off = mode == "off"
	h.forbid = mode == "forbid"
	h.unauth = mode == "unauth"
	h.boom = mode == "boom"
}

func (h *docsHub) seed(path, body string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.docs[path] = docRec{body: body}
}

func (h *docsHub) wsHello(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer conn.CloseNow() //nolint:errcheck
	ctx := r.Context()
	if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}) != nil {
		return
	}
	var hello wire.Frame
	if wsjson.Read(ctx, conn, &hello) != nil {
		return
	}
	h.mu.Lock()
	h.ws++
	h.role = hello.Role
	h.mu.Unlock()
	if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, UploadToken: h.token, UploadTokenExpiresAt: "2030-01-01T00:00:00Z"}) != nil {
		return
	}
	for {
		if _, _, err := conn.Read(ctx); err != nil {
			return
		}
	}
}

func (h *docsHub) tree(w http.ResponseWriter, r *http.Request) {
	h.record(r, nil)
	if !h.allow(w, r) {
		return
	}
	h.mu.Lock()
	files := make([]map[string]string, 0, len(h.docs))
	for p := range h.docs {
		files = append(files, map[string]string{"path": p, "updated": "2026-10-04T00:00:00Z"})
	}
	h.mu.Unlock()
	sort.Slice(files, func(i, j int) bool { return files[i]["path"] < files[j]["path"] })
	writeJSON(w, http.StatusOK, map[string]any{"v": 1, "sha": "abc", "files": files})
}

func (h *docsHub) get(w http.ResponseWriter, r *http.Request) {
	h.record(r, nil)
	if !h.allow(w, r) {
		return
	}
	p := r.PathValue("path")
	h.mu.Lock()
	d, ok := h.docs[p]
	h.mu.Unlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found", "detail": "no such doc"})
		return
	}
	w.Header().Set("Content-Type", docMarkdownType)
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, d.body)
}

func (h *docsHub) put(w http.ResponseWriter, r *http.Request) {
	b, _ := io.ReadAll(io.LimitReader(r.Body, docMaxBytes+1))
	h.record(r, b)
	if !h.allow(w, r) {
		return
	}
	p := r.PathValue("path")
	h.mu.Lock()
	h.docs[p] = docRec{body: string(b)}
	h.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"path": p, "history": ".history/" + p + "/test--put.md"})
}

func (h *docsHub) del(w http.ResponseWriter, r *http.Request) {
	h.record(r, nil)
	if !h.allow(w, r) {
		return
	}
	p := r.PathValue("path")
	h.mu.Lock()
	_, ok := h.docs[p]
	delete(h.docs, p)
	h.mu.Unlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found", "detail": "no such doc"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"path": p, "history": ".history/" + p + "/test--del.md"})
}

func (h *docsHub) allow(w http.ResponseWriter, r *http.Request) bool {
	h.mu.Lock()
	unauth, off, forbid, boom := h.unauth, h.off, h.forbid, h.boom
	token := h.token
	h.mu.Unlock()
	if unauth || r.Header.Get("Authorization") != "Bearer "+token {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "door", "detail": "a valid upload token is required"})
		return false
	}
	if boom {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal", "detail": "docs store unavailable"})
		return false
	}
	if off {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "workspace_docs_off", "detail": "this hub has no workspace docs store"})
		return false
	}
	if forbid && (r.Method == http.MethodPut || r.Method == http.MethodDelete) {
		writeJSON(w, http.StatusForbidden, map[string]string{
			"error": "forbidden", "detail": "your role in this tenant does not grant docs.write", "permission": "docs.write",
		})
		return false
	}
	return true
}

func (h *docsHub) record(r *http.Request, body []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.hits = append(h.hits, docHit{
		method: r.Method, path: r.URL.EscapedPath(), body: string(body),
		auth: r.Header.Get("Authorization"), tenant: r.Header.Get("X-Spool-Tenant"),
		ctype: r.Header.Get("Content-Type"), ifMatch: r.Header.Get("If-Match"),
	})
}

func (h *docsHub) snapshot() (hits []docHit, ws int, role string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]docHit(nil), h.hits...), h.ws, h.role
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func captureRun(t *testing.T, args []string) (int, string, string) {
	t.Helper()
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = outW, errW
	rc := run(args)
	_ = outW.Close()
	_ = errW.Close()
	os.Stdout, os.Stderr = oldOut, oldErr
	ob, _ := io.ReadAll(outR)
	eb, _ := io.ReadAll(errR)
	return rc, string(ob), string(eb)
}

func treePaths(t *testing.T, out string) []string {
	t.Helper()
	var cat struct {
		Files []struct {
			Path string `json:"path"`
		} `json:"files"`
	}
	if err := json.Unmarshal([]byte(out), &cat); err != nil {
		t.Fatalf("tree: %v\n%s", err, out)
	}
	ps := make([]string, 0, len(cat.Files))
	for _, f := range cat.Files {
		ps = append(ps, f.Path)
	}
	return ps
}

func TestDocVerbs(t *testing.T) {
	h := newDocsHub(t)

	t.Run("list read write delete", func(t *testing.T) {
		h.reset("")
		body := filepath.Join(t.TempDir(), "a.md")
		if err := os.WriteFile(body, []byte("# Alpha\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		rc, out, errOut := captureRun(t, []string{"doc-write", "notes/a.md", "--file", body})
		if rc != 0 || !strings.Contains(out, `"history"`) || !strings.Contains(out, "notes/a.md") || errOut != "" {
			t.Fatalf("write: rc %d out %q err %q", rc, out, errOut)
		}
		rc, out, errOut = captureRun(t, []string{"doc-write", "notes/a.md", "--file", body})
		if rc != 0 || !strings.Contains(out, `"history"`) || !strings.Contains(out, "notes/a.md") {
			t.Fatalf("second write: rc %d out %q err %q", rc, out, errOut)
		}
		// last write wins, and the verb does not send If-Match
		alt := filepath.Join(t.TempDir(), "b.md")
		if err := os.WriteFile(alt, []byte("# Beta\nsecond\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		rc, _, errOut = captureRun(t, []string{"doc-write", "notes/a.md", "--file", alt})
		if rc != 0 {
			t.Fatalf("third write: %d %s", rc, errOut)
		}
		rc, out, errOut = captureRun(t, []string{"doc-read", "notes/a.md"})
		if rc != 0 || out != "# Beta\nsecond\n" || errOut != "" {
			t.Fatalf("read: rc %d out %q err %q", rc, out, errOut)
		}
		h.seed("a.md", "# Root\n")
		h.seed("notes-old.md", "# Old\n")
		rc, out, errOut = captureRun(t, []string{"doc-list"})
		if rc != 0 || errOut != "" {
			t.Fatalf("list: rc %d err %q out %q", rc, errOut, out)
		}
		if got, want := treePaths(t, out), []string{"a.md", "notes-old.md", "notes/a.md"}; !reflect.DeepEqual(got, want) {
			t.Fatalf("list paths %v", got)
		}
		rc, out, errOut = captureRun(t, []string{"doc-list", "notes"})
		if rc != 0 {
			t.Fatalf("prefix: rc %d err %q", rc, errOut)
		}
		if got, want := treePaths(t, out), []string{"notes/a.md"}; !reflect.DeepEqual(got, want) {
			t.Fatalf("prefix notes: %v", got)
		}
		rc, out, errOut = captureRun(t, []string{"doc-list", "notes/"})
		if rc != 0 {
			t.Fatalf("prefix slash: rc %d err %q", rc, errOut)
		}
		if got := treePaths(t, out); !reflect.DeepEqual(got, []string{"notes/a.md"}) {
			t.Fatalf("prefix notes/: %v", got)
		}
		rc, out, errOut = captureRun(t, []string{"doc-delete", "notes/a.md"})
		if rc != 0 || !strings.Contains(out, `"history"`) || !strings.Contains(out, "notes/a.md") {
			t.Fatalf("delete: rc %d out %q err %q", rc, out, errOut)
		}
		rc, _, errOut = captureRun(t, []string{"doc-read", "notes/a.md"})
		if rc != 1 || !strings.Contains(errOut, "404: no doc") {
			t.Fatalf("read after delete: rc %d err %q", rc, errOut)
		}
		hits, ws, role := h.snapshot()
		if ws < 1 || role != wire.RoleCLI {
			t.Fatalf("hello: ws %d role %q", ws, role)
		}
		var puts int
		for _, hit := range hits {
			if hit.auth != "Bearer tok" || hit.tenant != "t1" || hit.ifMatch != "" {
				t.Fatalf("hit auth: %+v", hit)
			}
			if hit.method == http.MethodPut {
				puts++
				if hit.ctype != docMarkdownType || hit.path != "/v1/workspace/docs/notes/a.md" {
					t.Fatalf("put: %+v", hit)
				}
			}
			if hit.method == http.MethodGet && strings.HasSuffix(hit.path, "/tree.json") && hit.ctype != "" {
				t.Fatalf("list content-type %q", hit.ctype)
			}
		}
		if puts != 3 {
			t.Fatalf("puts %d", puts)
		}
		var last string
		for _, hit := range hits {
			if hit.method == http.MethodPut {
				last = hit.body
			}
		}
		if last != "# Beta\nsecond\n" {
			t.Fatalf("last put body %q", last)
		}
	})

	t.Run("stdin", func(t *testing.T) {
		h.reset("")
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		old := os.Stdin
		os.Stdin = r
		defer func() { os.Stdin = old }()
		go func() {
			_, _ = io.WriteString(w, "# piped\n")
			_ = w.Close()
		}()
		rc, out, errOut := captureRun(t, []string{"doc-write", "notes/my-doc.md"})
		if rc != 0 {
			t.Fatalf("stdin write: rc %d out %q err %q", rc, out, errOut)
		}
		hits, _, _ := h.snapshot()
		if len(hits) != 1 || hits[0].path != "/v1/workspace/docs/notes/my-doc.md" || hits[0].body != "# piped\n" {
			t.Fatalf("stdin hit: %+v", hits)
		}
		rc, out, errOut = captureRun(t, []string{"doc-read", "notes/my-doc.md"})
		if rc != 0 || out != "# piped\n" {
			t.Fatalf("read space: rc %d out %q err %q", rc, out, errOut)
		}
	})

	t.Run("403", func(t *testing.T) {
		h.reset("forbid")
		body := filepath.Join(t.TempDir(), "a.md")
		if err := os.WriteFile(body, []byte("# No\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		rc, out, errOut := captureRun(t, []string{"doc-write", "notes/a.md", "--file", body})
		if rc != 1 || out != "" || !strings.Contains(errOut, "403: no docs.write") {
			t.Fatalf("403: rc %d out %q err %q", rc, out, errOut)
		}
		hits, _, _ := h.snapshot()
		if len(hits) != 1 || hits[0].method != http.MethodPut {
			t.Fatalf("403 hit: %+v", hits)
		}
	})

	t.Run("401", func(t *testing.T) {
		h.reset("unauth")
		rc, _, errOut := captureRun(t, []string{"doc-list"})
		if rc != 1 || !strings.Contains(errOut, "401: not signed in") {
			t.Fatalf("401: rc %d err %q", rc, errOut)
		}
	})

	t.Run("404 route off and missing", func(t *testing.T) {
		h.reset("off")
		rc, _, errOut := captureRun(t, []string{"doc-list"})
		if rc != 1 || !strings.Contains(errOut, "404: route off") {
			t.Fatalf("off: rc %d err %q", rc, errOut)
		}
		h.reset("")
		rc, _, errOut = captureRun(t, []string{"doc-read", "missing.md"})
		if rc != 1 || !strings.Contains(errOut, "404: no doc") {
			t.Fatalf("missing: rc %d err %q", rc, errOut)
		}
		rc, _, errOut = captureRun(t, []string{"doc-delete", "missing.md"})
		if rc != 1 || !strings.Contains(errOut, "404: no doc") {
			t.Fatalf("delete missing: rc %d err %q", rc, errOut)
		}
	})

	t.Run("500", func(t *testing.T) {
		h.reset("boom")
		rc, _, errOut := captureRun(t, []string{"doc-read", "a.md"})
		if rc != 1 || !strings.Contains(errOut, "hub answered 500") {
			t.Fatalf("500: rc %d err %q", rc, errOut)
		}
	})
}

func TestFilterDocTree(t *testing.T) {
	raw := []byte(`[{"path":"a.md","title":"A"},{"path":"notes/a.md","title":"N"},{"path":"notes-old.md","title":"O"}]`)
	got, err := filterDocTree(raw, "notes")
	if err != nil {
		t.Fatal(err)
	}
	var arr []struct {
		Path string `json:"path"`
	}
	if err := json.Unmarshal(got, &arr); err != nil {
		t.Fatal(err)
	}
	if len(arr) != 1 || arr[0].Path != "notes/a.md" {
		t.Fatalf("array filter: %+v", arr)
	}
	same, err := filterDocTree(raw, "")
	if err != nil || string(same) != string(raw) {
		t.Fatalf("empty prefix changed the bytes: %v %s", err, same)
	}
	obj := []byte(`{"v":1,"sha":"s"}`)
	if _, err := filterDocTree(obj, "notes"); err == nil {
		t.Fatal("object without files was filtered")
	}
	if _, err := filterDocTree([]byte(`not-json`), "notes"); err == nil {
		t.Fatal("non-json was filtered")
	}
}

func TestWorkspaceDocPath(t *testing.T) {
	got, err := workspaceDocPath("notes/a.md")
	if err != nil || got != "/v1/workspace/docs/notes/a.md" {
		t.Fatalf("%s %v", got, err)
	}
	got, err = workspaceDocPath("notes/my-doc.md")
	if err != nil || got != "/v1/workspace/docs/notes/my-doc.md" {
		t.Fatalf("hyphen: %s %v", got, err)
	}
	for _, bad := range []string{"", "/", "../a.md", "a/../../b.md", "/etc/passwd", "a/./b.md", ".hidden.md", "a/.git/b.md", `a\b.md`, "a//b.md", "notes/a.md?x=1", "notes/my doc.md", "notes/a", "tree.json"} {
		if _, err := workspaceDocPath(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	if _, err := cleanPrefix("../x"); err == nil {
		t.Error("prefix .. accepted")
	}
	if p, err := cleanPrefix("notes/"); err != nil || p != "notes/" {
		t.Fatalf("prefix slash: %q %v", p, err)
	}
}

func TestDocNeedsHub(t *testing.T) {
	t.Setenv("SPOOL_ROOT", t.TempDir())
	t.Setenv("SPOOL_HUB_URL", "")
	t.Setenv("SPOOL_MIRROR_LOCAL", "0")
	t.Setenv("SPOOL_MSG_VERSION", "1")
	rc, _, errOut := captureRun(t, []string{"doc-read", "a.md"})
	if rc != 1 || !strings.Contains(errOut, "SPOOL_HUB_URL") {
		t.Fatalf("rc %d err %q", rc, errOut)
	}
	rc, _, errOut = captureRun(t, []string{"doc-read", "../a.md"})
	if rc != 1 || !strings.Contains(errOut, "not a workspace doc path") {
		t.Fatalf("bad path: rc %d err %q", rc, errOut)
	}
	rc, _, errOut = captureRun(t, []string{"doc-list", "../x"})
	if rc != 1 || !strings.Contains(errOut, "prefix") {
		t.Fatalf("bad prefix: rc %d err %q", rc, errOut)
	}
	rc, _, errOut = captureRun(t, []string{"doc-write"})
	if rc != 1 || !strings.Contains(errOut, "usage: spool doc-write") {
		t.Fatalf("usage: rc %d err %q", rc, errOut)
	}
}

func TestDocNeedsTenant(t *testing.T) {
	root, keys := t.TempDir(), t.TempDir()
	if _, err := sign.GenerateKey(keys, "box-a", false); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPOOL_ROOT", root)
	t.Setenv("SPOOL_KEYS_DIR", keys)
	t.Setenv("SPOOL_BOX_ID", "box-a")
	t.Setenv("SPOOL_HUB_URL", "http://127.0.0.1:1")
	t.Setenv("SPOOL_TENANT", "")
	t.Setenv("SPOOL_MIRROR_LOCAL", "0")
	t.Setenv("SPOOL_MSG_VERSION", "1")
	rc, _, errOut := captureRun(t, []string{"doc-read", "a.md"})
	if rc != 1 || !strings.Contains(errOut, "SPOOL_TENANT") {
		t.Fatalf("rc %d err %q", rc, errOut)
	}
}
