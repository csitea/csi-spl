package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// dtHub is the doctree contract the verbs call (internal/hub/wsdoc_tree.go),
// in memory: one tenant, items kept as parent + ord, outline derived.
type dtHub struct {
	*docsHub
	mu    sync.Mutex
	docs  map[string]*dtDocRec
	n     int
	calls []string
	fs    []string // each request's ?fs=
	// assets: "<doc>/<path>" -> the picture's Content-Type and bytes (SPL-2201)
	assets map[string][2]string
}

type dtDocRec struct {
	title string
	rev   int64
	root  string
	items map[string]*dtItem
}

const dtDocID = "11111111-1111-4111-8111-111111111111"

func newDTHub(t *testing.T) *dtHub {
	t.Helper()
	h := &dtHub{docsHub: &docsHub{token: "tok", docs: map[string]docRec{}}, docs: map[string]*dtDocRec{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", h.wsHello)
	mux.HandleFunc("/v1/workspace/doctree", h.serve)
	mux.HandleFunc("/v1/workspace/doctree/", h.serve)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	h.url = srv.URL
	docEnv(t, srv.URL)
	return h
}

func (h *dtHub) id() string {
	h.n++
	return fmt.Sprintf("00000000-0000-4000-8000-%012d", h.n)
}

// children are parent's children by ord.
func (d *dtDocRec) children(parent string) []*dtItem {
	var out []*dtItem
	for _, it := range d.items {
		if it.Parent == parent {
			out = append(out, it)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Ord < out[j].Ord })
	return out
}

func (d *dtDocRec) renumber(parent string) {
	for i, it := range d.children(parent) {
		it.Ord = i + 1
	}
}

// walk is item's subtree in document order with outline and depth set.
func (d *dtDocRec) walk(id, outline string, depth int, out *[]dtItem) {
	it := d.items[id]
	it.Outline, it.Depth = outline, depth
	*out = append(*out, *it)
	for i, c := range d.children(id) {
		o := strconv.Itoa(i + 1)
		if outline != "" {
			o = outline + "." + o
		}
		d.walk(c.ID, o, depth+1, out)
	}
}

func (d *dtDocRec) all() []dtItem {
	var out []dtItem
	d.walk(d.root, "", 0, &out)
	return out
}

func (h *dtHub) serve(w http.ResponseWriter, r *http.Request) {
	b, _ := io.ReadAll(r.Body)
	h.mu.Lock()
	defer h.mu.Unlock()
	h.calls = append(h.calls, r.Method+" "+r.URL.Path)
	h.fs = append(h.fs, r.URL.Query().Get("fs"))
	if r.Header.Get("Authorization") != "Bearer tok" || r.Header.Get("X-Spool-Tenant") != "t1" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "door", "detail": "a valid upload token is required"})
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/v1/workspace/doctree"), "/"), "/")
	if len(parts) > 2 && parts[1] == "assets" {
		h.serveAsset(w, r, parts[0]+"/"+strings.Join(parts[2:], "/"), b)
		return
	}
	var in map[string]any
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		_ = json.Unmarshal(b, &in)
	}
	str := func(k string) string { s, _ := in[k].(string); return s }
	num := func(k string) int64 { f, _ := in[k].(float64); return int64(f) }
	if parts[0] == "" {
		switch r.Method {
		case http.MethodGet:
			out := []map[string]any{}
			for id, d := range h.docs {
				out = append(out, map[string]any{"id": id, "title": d.title, "rev": d.rev})
			}
			writeJSON(w, http.StatusOK, map[string]any{"docs": out})
		case http.MethodPost:
			root := h.id()
			id := dtDocID
			if _, taken := h.docs[id]; taken {
				id = h.id()
			}
			h.docs[id] = &dtDocRec{title: str("title"), rev: 1, root: root,
				items: map[string]*dtItem{root: {ID: root, Attrs: map[string]any{}, Rev: 1}}}
			writeJSON(w, http.StatusOK, map[string]any{"id": id, "root": root, "rev": 1, "parent": str("parent")})
		}
		return
	}
	if parts[0] == "nodes" || parts[0] == "folders" {
		writeJSON(w, http.StatusOK, map[string]any{"route": parts[0], "parent": r.URL.Query().Get("parent"), "in": in})
		return
	}
	d, ok := h.docs[parts[0]]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found", "detail": "no such document or item"})
		return
	}
	stale := func(rev int64) bool {
		if rev != 0 && rev != d.rev {
			writeJSON(w, http.StatusPreconditionFailed, map[string]string{"error": "stale_rev", "detail": "reload"})
			return true
		}
		return false
	}
	switch {
	case len(parts) == 1 && r.Method == http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{"id": parts[0], "title": d.title, "rev": d.rev, "root": d.root})
	case len(parts) == 1 && r.Method == http.MethodPatch:
		if !stale(num("rev")) {
			d.title, d.rev = str("title"), d.rev+1
			writeJSON(w, http.StatusOK, map[string]any{"rev": d.rev, "title": d.title})
		}
	case len(parts) == 1 && r.Method == http.MethodDelete:
		rev, _ := strconv.ParseInt(r.URL.Query().Get("rev"), 10, 64)
		if !stale(rev) {
			delete(h.docs, parts[0])
			writeJSON(w, http.StatusOK, map[string]any{"rev": d.rev, "doc": parts[0], "deleted": true})
		}
	case parts[1] == "subtree":
		items := d.all()
		if q := r.URL.Query().Get("item"); q != "" {
			if d.items[q] == nil {
				writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found", "detail": "no such document or item"})
				return
			}
			var sub []dtItem
			d.walk(q, d.items[q].Outline, d.items[q].Depth, &sub)
			items = sub
		} else {
			items = items[1:]
		}
		writeJSON(w, http.StatusOK, map[string]any{"doc": parts[0], "rev": d.rev, "items": items})
	case parts[1] == "images":
		sum := strings.Repeat("ab", 32)
		writeJSON(w, http.StatusOK, map[string]any{"name": sum + ".png", "bytes": len(b), "ctype": r.Header.Get("Content-Type"),
			"img_http_path": "/v1/workspace/doctree/" + parts[0] + "/images/" + sum + ".png"})
	case parts[1] == "items" && len(parts) == 2:
		if stale(num("rev")) {
			return
		}
		anchor := str("anchor")
		if anchor == "" {
			anchor = d.root
		}
		a, ok := d.items[anchor]
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		attrs, _ := in["attrs"].(map[string]any)
		if attrs == nil {
			attrs = map[string]any{}
		}
		it := &dtItem{ID: h.id(), Title: str("title"), Body: str("body"), Attrs: attrs, Rev: 1}
		if str("where") == "sibling" {
			for _, s := range d.children(a.Parent) {
				if s.Ord > a.Ord {
					s.Ord++
				}
			}
			it.Parent, it.Ord = a.Parent, a.Ord+1
		} else {
			it.Parent, it.Ord = anchor, len(d.children(anchor))+1
		}
		d.items[it.ID] = it
		d.rev++
		writeJSON(w, http.StatusOK, map[string]any{"rev": d.rev, "item": it.ID})
	case parts[1] == "items" && len(parts) == 4 && parts[3] == "move":
		it := d.items[parts[2]]
		if stale(num("rev")) {
			return
		}
		old, parent := it.Parent, str("parent")
		if parent == "" {
			parent = d.root
		}
		it.Parent, it.Ord = parent, 1<<20
		d.renumber(old)
		d.renumber(parent)
		d.rev++
		writeJSON(w, http.StatusOK, map[string]any{"rev": d.rev, "item": it.ID})
	case parts[1] == "items" && r.Method == http.MethodDelete:
		var sub []dtItem
		d.walk(parts[2], "", 0, &sub)
		parent := d.items[parts[2]].Parent
		for _, x := range sub {
			delete(d.items, x.ID)
		}
		d.renumber(parent)
		d.rev++
		writeJSON(w, http.StatusOK, map[string]any{"rev": d.rev, "item": parts[2]})
	case parts[1] == "items" && r.Method == http.MethodPatch:
		it, ok := d.items[parts[2]]
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		if num("rev") != it.Rev {
			writeJSON(w, http.StatusPreconditionFailed, map[string]string{"error": "stale_rev", "detail": "reload"})
			return
		}
		switch str("field") {
		case "title":
			it.Title = str("value")
		case "body":
			it.Body = str("value")
		case "attrs":
			it.Attrs = map[string]any{}
			_ = json.Unmarshal([]byte(str("value")), &it.Attrs)
		}
		it.Rev++
		writeJSON(w, http.StatusOK, map[string]any{"item_rev": it.Rev})
	default:
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
	}
}

func (h *dtHub) doc(t *testing.T) *dtDocRec {
	t.Helper()
	h.mu.Lock()
	defer h.mu.Unlock()
	d := h.docs[dtDocID]
	if d == nil {
		t.Fatal("no document")
	}
	return d
}

func dtOK(t *testing.T, args ...string) map[string]any {
	t.Helper()
	rc, out, errOut := captureRun(t, append([]string{"doctree"}, args...))
	if rc != 0 {
		t.Fatalf("spool doctree %v: rc %d, stderr %s", args, rc, errOut)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("spool doctree %v: not JSON: %q", args, out)
	}
	return m
}

// TestDocTreeGuideFlow is the guide seat's path: create a doc, add the five
// item kinds, export it as the WUI would, then delete it.
func TestDocTreeGuideFlow(t *testing.T) {
	h := newDTHub(t)
	if got := dtOK(t, "create", "--title", "Rebuild guide", "--folder", "f1"); got["id"] != dtDocID || got["parent"] != "f1" {
		t.Fatalf("create: %v", got)
	}
	h1 := dtOK(t, "add", dtDocID, "--kind", "heading", "--level", "1", "--title", "Install")["item"].(string)
	dtOK(t, "add", dtDocID, "--kind", "para", "--text", "Run the installer.")
	dtOK(t, "add", dtDocID, "--kind", "heading", "--level", "2", "--title", "Commands")
	dtOK(t, "add", dtDocID, "--kind", "code", "--lang", "bash", "--text", "./run -a do_install\n")
	tbl := "| a | b |\n|---|:-:|\n| 1 | 2 |"
	dtOK(t, "add", dtDocID, "--kind", "table", "--text", tbl, "--item", h1)
	img := filepath.Join(t.TempDir(), "arch.png")
	if err := os.WriteFile(img, []byte("\x89PNG\r\n\x1a\nfake"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := dtOK(t, "add", dtDocID, "--kind", "picture", "--path", img, "--caption", "The [box] layout"); got["caption"] != "The box layout" {
		t.Fatalf("picture: %v", got)
	}
	dtOK(t, "add", dtDocID, "--kind", "heading", "--level", "1", "--title", "Next")
	items := h.doc(t).all()[1:]
	if len(items) != 3 || items[0].Depth != 1 || items[1].Depth != 2 || items[2].Depth != 1 {
		t.Fatalf("tree: %+v", items)
	}
	if items[0].Body != "Run the installer.\n\n"+tbl {
		t.Fatalf("para + table body: %q", items[0].Body)
	}
	if items[1].attr("src") != "./run -a do_install" || items[1].attr("lang") != "bash" {
		t.Fatalf("code attrs: %v", items[1].Attrs)
	}
	pic := "/v1/workspace/doctree/" + dtDocID + "/images/" + strings.Repeat("ab", 32) + ".png"
	if items[1].Body != "![The box layout]("+pic+")" {
		t.Fatalf("picture body: %q", items[1].Body)
	}
	rc, md, errOut := captureRun(t, []string{"doctree", "export", dtDocID})
	if rc != 0 {
		t.Fatalf("export: %s", errOut)
	}
	want := "# 1 Install\n\nRun the installer.\n\n" + tbl + "\n\n" +
		"## 1.1 Commands\n\n![The box layout](" + pic + ")\n\n*Figure 1: The box layout*\n\n```bash\n./run -a do_install\n```\n\n" +
		"# 2 Next\n"
	if md != want {
		t.Fatalf("export:\n got %q\nwant %q", md, want)
	}
	if got := dtOK(t, "delete", dtDocID); got["deleted"] != true {
		t.Fatalf("delete: %v", got)
	}
	if rc, _, errOut := captureRun(t, []string{"doctree", "head", dtDocID}); rc == 0 || !strings.Contains(errOut, "404") {
		t.Fatalf("head after delete: rc %d %s", rc, errOut)
	}
}

func TestDocTreeEditMoveRename(t *testing.T) {
	h := newDTHub(t)
	dtOK(t, "create", "--title", "T")
	a := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "A")["item"].(string)
	b := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "B", "--text", "b body")["item"].(string)
	c := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "C", "--after", a)["item"].(string)
	dtOK(t, "edit", dtDocID, b, "--field", "title", "--value", "B2")
	dtOK(t, "move", dtDocID, b, "--parent", a)
	dtOK(t, "rename", dtDocID, "--title", "T2")
	got := []string{}
	for _, it := range h.doc(t).all()[1:] {
		got = append(got, it.Outline+" "+it.Title)
	}
	if want := "1 A,1.1 B2,2 C"; strings.Join(got, ",") != want {
		t.Fatalf("tree %v, want %s", got, want)
	}
	if h.doc(t).title != "T2" {
		t.Fatalf("rename: %q", h.doc(t).title)
	}
	dtOK(t, "delete", dtDocID, c)
	if n := len(h.doc(t).all()); n != 3 {
		t.Fatalf("after item delete: %d items with the root", n)
	}
	rc, md, _ := captureRun(t, []string{"doctree", "export", dtDocID, "--item", b})
	if rc != 0 || md != "# 1.1 B2\n\nb body\n" {
		t.Fatalf("branch export: %q", md)
	}
}

func TestDocTreeRefusals(t *testing.T) {
	h := newDTHub(t)
	dtOK(t, "create", "--title", "T")
	_ = h
	cases := []struct {
		args []string
		want string
	}{
		{[]string{"add", dtDocID, "--kind", "para", "--text", "x"}, "add a heading first"},
		{[]string{"add", dtDocID, "--kind", "heading", "--level", "2", "--title", "x"}, "no item at level 1"},
		{[]string{"add", dtDocID, "--kind", "heading"}, "--title is required"},
		{[]string{"add", dtDocID, "--kind", "table", "--text", "| a |\n| b |"}, "separator row"},
		{[]string{"add", dtDocID, "--kind", "picture", "--path", "x.svg"}, ".png, .jpg"},
		{[]string{"add", dtDocID, "--kind", "nope"}, "--kind is heading"},
		{[]string{"edit", dtDocID, "x", "--field", "attrs", "--value", "{}"}, "--field is title, body or attrs.<key>"},
		{[]string{"edit", dtDocID, "x", "--field", "attrs.src", "--value", "x"}, "set by add --kind code"},
		{[]string{"edit", dtDocID, "x", "--field", "attrs.kind", "--value", "x"}, "set by add --kind code"},
		{[]string{"edit", dtDocID, "x", "--field", "attrs.img_http_path", "--value", "x"}, "set by add --kind code"},
		{[]string{"edit", dtDocID, "x", "--field", "attrs.img_name", "--value", "x"}, "set by add --kind code"},
		{[]string{"edit", dtDocID, "x", "--field", "attrs.Bad-Key", "--value", "x"}, "lower case letters"},
		{[]string{"edit", dtDocID, "x", "--field", "attrs.numbered", "--value", "nope", "--json"}, "not JSON"},
		{[]string{"rename", dtDocID, "--title", "x", "--rev", "9"}, "412"},
		{[]string{"frob"}, "unknown doctree verb"},
	}
	for _, c := range cases {
		rc, _, errOut := captureRun(t, append([]string{"doctree"}, c.args...))
		if rc == 0 || !strings.Contains(errOut, c.want) {
			t.Errorf("%v: rc %d, stderr %q, want %q", c.args, rc, errOut, c.want)
		}
	}
	dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "H")
	dtOK(t, "add", dtDocID, "--kind", "code", "--text", "one")
	if rc, _, errOut := captureRun(t, []string{"doctree", "add", dtDocID, "--kind", "code", "--text", "two"}); rc == 0 ||
		!strings.Contains(errOut, "already has a code block") {
		t.Errorf("second code block: rc %d %q", rc, errOut)
	}
	dtOK(t, "add", dtDocID, "--kind", "code", "--text", "two", "--replace")
}

// TestDocTreeEditAttrsSrcLang tests that attrs.src and attrs.lang can be edited
// on an item that already has attrs.src, and are refused on an item that does not.
func TestDocTreeEditAttrsSrcLang(t *testing.T) {
	h := newDTHub(t)
	dtOK(t, "create", "--title", "T")
	// Add a heading (no attrs.src).
	h1 := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "H1")["item"].(string)
	// A second heading with a code block (add --kind code sets attrs.src on an existing item).
	code := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "H2")["item"].(string)
	dtOK(t, "add", dtDocID, "--kind", "code", "--item", code, "--text", "echo hi", "--lang", "bash")

	// Red control: edit attrs.src on an item without attrs.src (should fail).
	rc, _, errOut := captureRun(t, []string{"doctree", "edit", dtDocID, h1, "--field", "attrs.src", "--value", "new src"})
	if rc == 0 || !strings.Contains(errOut, "set by add --kind code") {
		t.Errorf("edit attrs.src on an item without attrs.src: rc %d, stderr %q", rc, errOut)
	}

	// Red control: edit attrs.lang on an item without attrs.src (should fail).
	rc, _, errOut = captureRun(t, []string{"doctree", "edit", dtDocID, h1, "--field", "attrs.lang", "--value", "python"})
	if rc == 0 || !strings.Contains(errOut, "set by add --kind code") {
		t.Errorf("edit attrs.lang on an item without attrs.src: rc %d, stderr %q", rc, errOut)
	}

	// Green test: edit attrs.src on an item with attrs.src (should succeed).
	dtOK(t, "edit", dtDocID, code, "--field", "attrs.src", "--value", "echo hello")
	it, ok := h.doc(t).items[code]
	if !ok || it.attr("src") != "echo hello" || it.attr("lang") != "bash" {
		t.Errorf("edit attrs.src on an item with attrs.src: got src %q lang %q, want %q %q", it.attr("src"), it.attr("lang"), "echo hello", "bash")
	}

	// Green test: edit attrs.lang on an item with attrs.src (should succeed).
	dtOK(t, "edit", dtDocID, code, "--field", "attrs.lang", "--value", "sh")
	it, ok = h.doc(t).items[code]
	if !ok || it.attr("lang") != "sh" {
		t.Errorf("edit attrs.lang on an item with attrs.src: got %q, want %q", it.attr("lang"), "sh")
	}

	// The other typed keys stay refused on an item with attrs.src too.
	for _, k := range []string{"kind", "img_http_path", "img_name"} {
		rc, _, errOut = captureRun(t, []string{"doctree", "edit", dtDocID, code, "--field", "attrs." + k, "--value", "x"})
		if rc == 0 || !strings.Contains(errOut, "set by add --kind code or picture") {
			t.Errorf("edit attrs.%s on an item with attrs.src: rc %d, stderr %q", k, rc, errOut)
		}
	}
}

// TestDocTreeFS: $SPOOL_DOCTREE_FS=repo sends ?fs=repo on every request,
// a read with its own query and a write alike (spec 137 T030a: the import of
// the repo docs); unset sends none; any other value is refused before a call.
func TestDocTreeFS(t *testing.T) {
	h := newDTHub(t)
	dtOK(t, "create", "--title", "T")
	t.Setenv("SPOOL_DOCTREE_FS", "repo")
	dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "H")
	captureRun(t, []string{"doctree", "read", dtDocID, "--item", "x"}) // a path with its own query: ?item=x&fs=repo
	h.mu.Lock()
	if h.fs[0] != "" || len(h.fs) < 3 || strings.Join(h.fs[1:], ",") != strings.TrimSuffix(strings.Repeat("repo,", len(h.fs)-1), ",") {
		t.Errorf("fs per request = %q, want none on the first then repo on every one (%v)", h.fs, h.calls)
	}
	n := len(h.calls)
	h.mu.Unlock()
	t.Setenv("SPOOL_DOCTREE_FS", "git")
	if rc, _, errOut := captureRun(t, []string{"doctree", "head", dtDocID}); rc == 0 || !strings.Contains(errOut, "SPOOL_DOCTREE_FS is workspace or repo") {
		t.Errorf("SPOOL_DOCTREE_FS=git: rc %d %q", rc, errOut)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.calls) != n {
		t.Errorf("a bad SPOOL_DOCTREE_FS still called the hub: %v", h.calls[n:])
	}
}

// TestDocTreeMarkdownWUIParity pins branchToMarkdown's output (the WUI's
// -doctree-export.ts, run under node on this fixture): figure numbers run
// through the whole doc, inline pictures first then the item's image, another
// doc's token stays text, a branch export keeps the whole doc's numbers, a
// code item with a lang is fenced ```<lang> (mermaid stays a diagram on GitHub).
func TestDocTreeMarkdownWUIParity(t *testing.T) {
	const doc = "d1"
	pic := func(d, c string) string {
		return "![" + c + "](/v1/workspace/doctree/" + d + "/images/" + strings.Repeat("0", 64) + ".png)"
	}
	items := []dtItem{
		{ID: "a", Outline: "1", Depth: 1, Title: "Intro", Body: "  Hello " + pic(doc, " one ") + " tail\n" + pic("other", "x") + "  ",
			Attrs: map[string]any{"img_http_path": "https://example.com/i.png", "img_name": "Sec [img]"}},
		{ID: "b", Outline: "1.1", Depth: 2, Title: "", Body: "", Attrs: map[string]any{"src": "echo hi", "lang": "bash"}},
		{ID: "c", Outline: "1.1.1", Depth: 3, Title: "Deep", Body: pic(doc, "two")},
		{ID: "d", Outline: "2", Depth: 1, Title: "End", Body: "\n"},
		{ID: "e", Outline: "3", Depth: 1, Title: "Flow", Attrs: map[string]any{"src": "graph TD\n  A --> B", "lang": "mermaid"}},
	}
	whole, _ := docTreeMarkdown(items, doc, "")
	if want := dtWUIWhole; whole != want {
		t.Errorf("whole:\n got %q\nwant %q", whole, want)
	}
	branch, _ := docTreeMarkdown(items, doc, "b")
	if want := dtWUIBranch; branch != want {
		t.Errorf("branch:\n got %q\nwant %q", branch, want)
	}
	if _, err := docTreeMarkdown(items, doc, "zz"); err == nil {
		t.Error("an unknown --item exported")
	}
}

// The goldens: branchToMarkdown (-doctree-export.ts) run under node on the
// fixture of TestDocTreeMarkdownWUIParity, verbatim. Since SPL-1900 a body is
// written as stored: Intro keeps its indent and its trailing spaces, End's
// blank body ("\n") is its one blank line.
var (
	dtZ64       = strings.Repeat("0", 64)
	dtWUIWhole  = "# 1 Intro\n\n  Hello ![one](/v1/workspace/doctree/d1/images/" + dtZ64 + ".png)\n\n*Figure 1: one*\n tail\n![x](/v1/workspace/doctree/other/images/" + dtZ64 + ".png)  \n\n![Sec img](https://example.com/i.png)\n\n*Figure 2: Sec [img]*\n\n## 1.1 Untitled\n\n```bash\necho hi\n```\n\n### 1.1.1 Deep\n\n![two](/v1/workspace/doctree/d1/images/" + dtZ64 + ".png)\n\n*Figure 3: two*\n\n# 2 End\n\n\n# 3 Flow\n\n```mermaid\ngraph TD\n  A --> B\n```\n"
	dtWUIBranch = "# 1.1 Untitled\n\n```bash\necho hi\n```\n\n## 1.1.1 Deep\n\n![two](/v1/workspace/doctree/d1/images/" + dtZ64 + ".png)\n\n*Figure 3: two*\n"
)
