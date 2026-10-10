package hub_test

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 113 T004: the hub API of the workspace documents (wsdoc_tree.go) on
// testkit Postgres (SPOOL_TEST_PG_DSN, PRE_PUSH_TIER=full); the memory store
// has no tree and answers workspace_doc_tree_off.
//
//	go test ./internal/hub -run WorkspaceDoc -v

const docTreeAPI = "/v1/workspace/doctree"

// docTreeEnv is a Postgres hub, one tenant and a developer seated in it.
func docTreeEnv(t *testing.T) (*env, string, string) {
	t.Helper()
	e := rbacEnv(t)
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	return e, tid, seat(t, e, tid, "developer")
}

// mustCall is call that requires want.
func mustCall(t *testing.T, e *env, tid, method, path, as string, body any, want int) map[string]any {
	t.Helper()
	code, out := call(t, e, tid, method, path, as, body)
	if code != want {
		t.Fatalf("%s %s: %d %v, want %d", method, path, code, out, want)
	}
	return out
}

func dtNum(m map[string]any, k string) int64 { f, _ := m[k].(float64); return int64(f) }

func dtStr(m map[string]any, k string) string { s, _ := m[k].(string); return s }

func dtList(m map[string]any, k string) []map[string]any {
	xs, _ := m[k].([]any)
	out := make([]map[string]any, 0, len(xs))
	for _, x := range xs {
		out = append(out, x.(map[string]any))
	}
	return out
}

// outlines is "outline title" of each item, in the answer's order.
func outlines(m map[string]any) string {
	var out []string
	for _, it := range dtList(m, "items") {
		out = append(out, dtStr(it, "outline")+" "+dtStr(it, "title"))
	}
	return strings.Join(out, ", ")
}

// docTree builds a doc: A, B (B.1 (B.1.1)), C, returns doc and the ids.
func docTree(t *testing.T, e *env, tid, as string) (string, map[string]string) {
	t.Helper()
	d := mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "spec"}, 200)
	doc, rev := dtStr(d, "id"), dtNum(d, "rev")
	ids := map[string]string{"root": dtStr(d, "root")}
	add := func(name, anchor, where string) {
		out := mustCall(t, e, tid, http.MethodPost, docTreeAPI+"/"+doc+"/items", as,
			map[string]any{"rev": rev, "anchor": anchor, "where": where, "title": name, "body": "body of " + name}, 200)
		rev, ids[name] = dtNum(out, "rev"), dtStr(out, "item")
	}
	add("A", "", "child")
	add("C", ids["A"], "sibling")
	add("B", ids["A"], "sibling")
	add("B.1", ids["B"], "child")
	add("B.1.1", ids["B.1"], "child")
	return doc, ids
}

// TestWorkspaceDocLazyChildren: the lazy route returns one node's children
// plus the ancestors' ord path, and the doc rev read before them.
func TestWorkspaceDocLazyChildren(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	doc, ids := docTree(t, e, tid, as)
	top := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc+"/children", as, nil, 200)
	if got := outlines(top); got != "1 A, 2 B, 3 C" {
		t.Fatalf("top level = %q", got)
	}
	if dtNum(top, "rev") != 6 || dtStr(top, "parent") != ids["root"] {
		t.Fatalf("top rev/parent = %v %v, want 6 (create + 5 adds) and the root", top["rev"], top["parent"])
	}
	in := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc+"/children?parent="+ids["B.1"], as, nil, 200)
	if got := outlines(in); got != "2.1.1 B.1.1" {
		t.Fatalf("children of B.1 = %q", got)
	}
	if p := fmt.Sprint(in["path"]); p != "[2 1]" || dtStr(in, "outline") != "2.1" {
		t.Fatalf("path = %s outline = %q, want [2 1] and 2.1", p, dtStr(in, "outline"))
	}
	t.Logf("lazy: top=%q, children of 2.1=%q path=%v", outlines(top), outlines(in), in["path"])
}

// TestWorkspaceDocOutcomes: committed + rev, 412 stale rev, 404 gone,
// refused, on the structural ops and on a text edit.
func TestWorkspaceDocOutcomes(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	doc, ids := docTree(t, e, tid, as)
	items := docTreeAPI + "/" + doc + "/items/"
	counts := map[int]int{}
	try := func(method, path string, body any, want int) map[string]any {
		t.Helper()
		out := mustCall(t, e, tid, method, path, as, body, want)
		counts[want]++
		return out
	}
	try(http.MethodPost, docTreeAPI+"/"+doc+"/items", map[string]any{"rev": 5, "anchor": ids["A"], "where": "sibling", "title": "x"}, 412)
	mv := try(http.MethodPost, items+ids["C"]+"/move", map[string]any{"rev": 6, "parent": "", "ord": 1}, 200)
	if dtNum(mv, "rev") != 7 {
		t.Fatalf("move rev = %v, want 7", mv["rev"])
	}
	try(http.MethodPost, items+ids["B"]+"/move", map[string]any{"rev": 7, "parent": ids["B.1.1"]}, 422)
	try(http.MethodDelete, items+ids["root"]+"?rev=7", nil, 422)
	ed := try(http.MethodPatch, items+ids["A"], map[string]any{"field": "title", "value": "A2", "rev": 1}, 200)
	try(http.MethodPatch, items+ids["A"], map[string]any{"field": "title", "value": "A3", "rev": 1}, 412)
	try(http.MethodPatch, items+ids["A"], map[string]any{"field": "owner", "value": "x", "rev": dtNum(ed, "item_rev")}, 422)
	try(http.MethodDelete, items+ids["B"]+"?rev=7", nil, 200)
	try(http.MethodPatch, items+ids["B.1"], map[string]any{"field": "body", "value": "gone", "rev": 1}, 404)
	try(http.MethodPost, items+ids["B.1"]+"/move", map[string]any{"rev": 8, "parent": ""}, 404)
	try(http.MethodDelete, items+ids["B"]+"?rev=8", nil, 404)
	sub := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc+"/subtree", as, nil, 200)
	if got := outlines(sub); got != "1 C, 2 A2" || dtNum(sub, "rev") != 8 {
		t.Fatalf("after the ops: %q rev %v, want \"1 C, 2 A2\" rev 8", got, sub["rev"])
	}
	t.Logf("outcomes: committed=%d 412=%d 404=%d refused=%d; final %q rev %v",
		counts[200], counts[412], counts[404], counts[422], outlines(sub), sub["rev"])
}

// TestWorkspaceDocDeleteDoc: DELETE /v1/workspace/doctree/{doc}. A bad rev
// is 400, a stale one 412, another tenant's member 404 (CONTROL: each leaves
// the doc readable); the delete at its rev is 200, then the doc, its items
// and its listing are gone (404) and a second delete is 404.
func TestWorkspaceDocDeleteDoc(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	doc, _ := docTree(t, e, tid, as)
	keep, _ := docTree(t, e, tid, as)
	path := docTreeAPI + "/" + doc
	other, _ := e.tenant()
	bs := seat(t, e, other, "developer")
	mustCall(t, e, tid, http.MethodDelete, path+"?rev=x", as, nil, 400)
	mustCall(t, e, tid, http.MethodDelete, path+"?rev=5", as, nil, 412)
	mustCall(t, e, other, http.MethodDelete, path+"?rev=6", bs, nil, 404)
	if got := outlines(mustCall(t, e, tid, http.MethodGet, path+"/subtree", as, nil, 200)); got == "" {
		t.Fatalf("after the refusals the doc reads empty, want it whole")
	}
	out := mustCall(t, e, tid, http.MethodDelete, path+"?rev=6", as, nil, 200)
	if dtNum(out, "rev") != 6 || dtStr(out, "doc") != doc || out["deleted"] != true {
		t.Fatalf("delete answer = %v, want rev 6, the doc, deleted", out)
	}
	for _, p := range []string{"", "/children", "/subtree", "/grid"} {
		mustCall(t, e, tid, http.MethodGet, path+p, as, nil, 404)
	}
	var ids []string
	for _, d := range dtList(mustCall(t, e, tid, http.MethodGet, docTreeAPI, as, nil, 200), "docs") {
		ids = append(ids, dtStr(d, "id"))
	}
	if strings.Contains(strings.Join(ids, ","), doc) || !strings.Contains(strings.Join(ids, ","), keep) {
		t.Fatalf("list after the delete = %v, want %s gone and %s kept", ids, doc, keep)
	}
	mustCall(t, e, tid, http.MethodDelete, path, as, nil, 404)
	t.Logf("delete doc: 400 bad rev, 412 stale, 404 foreign (doc whole), 200 at rev 6, then 404 and listed docs %v", ids)
}

// TestWorkspaceDocGrid: the whole document in document order, a filter, a
// sort, and 413 above hub.DocTreeMaxItems (the boundary itself is served).
func TestWorkspaceDocGrid(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	doc, ids := docTree(t, e, tid, as)
	grid := docTreeAPI + "/" + doc + "/grid"
	g := mustCall(t, e, tid, http.MethodGet, grid, as, nil, 200)
	if got := outlines(g); got != "1 A, 2 B, 2.1 B.1, 2.1.1 B.1.1, 3 C" {
		t.Fatalf("grid = %q", got)
	}
	if got := outlines(mustCall(t, e, tid, http.MethodGet, grid+"?q=b.1", as, nil, 200)); got != "2.1 B.1, 2.1.1 B.1.1" {
		t.Fatalf("grid q=b.1 = %q", got)
	}
	if got := outlines(mustCall(t, e, tid, http.MethodGet, grid+"?sort=title&desc=1", as, nil, 200)); got != "3 C, 2.1.1 B.1.1, 2.1 B.1, 2 B, 1 A" {
		t.Fatalf("grid sort=title desc = %q", got)
	}
	mustCall(t, e, tid, http.MethodGet, grid+"?sort=nope", as, nil, 400)

	// 20,000 items (5 above + 19,995 flat under C) is served; one more is 413.
	bulk(t, e, tid, doc, ids["C"], hub.DocTreeMaxItems-5)
	g = mustCall(t, e, tid, http.MethodGet, grid, as, nil, 200)
	first, last := dtList(g, "items")[0], dtList(g, "items")[hub.DocTreeMaxItems-1]
	if dtNum(g, "total") != hub.DocTreeMaxItems || dtStr(first, "outline") != "1" || dtStr(last, "outline") != fmt.Sprintf("3.%d", hub.DocTreeMaxItems-5) {
		t.Fatalf("grid at the limit: total %v, first %v, last %v", g["total"], first["outline"], last["outline"])
	}
	bulk(t, e, tid, doc, ids["C"], 1)
	out := mustCall(t, e, tid, http.MethodGet, grid, as, nil, 413)
	mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc+"/subtree", as, nil, 413)
	sec := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc+"/subtree?item="+ids["B"], as, nil, 200)
	t.Logf("grid: %d items served in document order (last %v); %d items: %v; a section still reads: %q",
		hub.DocTreeMaxItems, last["outline"], hub.DocTreeMaxItems+1, out["error"], outlines(sec))
}

// bulk appends n items under parent in one statement, under the tenant's
// RLS scope (the deferred tree trigger checks the result at commit).
func bulk(t *testing.T, e *env, tid, doc, parent string, n int) {
	t.Helper()
	ctx := context.Background()
	err := pgx.BeginFunc(ctx, e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tid); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title)
			SELECT $1, $2, $3, m.top + g, 'row ' || g
			FROM generate_series(1, $4::int) g,
				(SELECT coalesce(max(ord), 0) AS top FROM workspace_doc_item WHERE doc_id = $2 AND parent_id = $3) m`,
			tid, doc, parent, n)
		return err
	})
	if err != nil {
		t.Fatalf("bulk %d: %v", n, err)
	}
}

// TestWorkspaceDocCrossTenant (9e): another tenant's member lists 0 docs,
// finds 0 hits, and every read and structural op on the doc is a 404.
// CONTROL: the same requests in the doc's own tenant return the rows / 200.
func TestWorkspaceDocCrossTenant(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	doc, ids := docTree(t, e, tid, as)
	other, _ := e.tenant()
	bs := seat(t, e, other, "developer")
	in, out := 0, 0
	for _, side := range []struct {
		tid, as string
		n       *int
		code    int
	}{{tid, as, &in, 200}, {other, bs, &out, 404}} {
		*side.n += len(dtList(mustCall(t, e, side.tid, http.MethodGet, docTreeAPI, side.as, nil, 200), "docs"))
		*side.n += len(dtList(mustCall(t, e, side.tid, http.MethodGet, docTreeAPI+"/search?q=body", side.as, nil, 200), "hits"))
		for _, p := range []string{"", "/children", "/grid", "/subtree"} {
			out := mustCall(t, e, side.tid, http.MethodGet, docTreeAPI+"/"+doc+p, side.as, nil, side.code)
			*side.n += len(dtList(out, "items"))
		}
		mustCall(t, e, side.tid, http.MethodPost, docTreeAPI+"/"+doc+"/items/"+ids["C"]+"/move", side.as,
			map[string]any{"parent": ids["A"]}, side.code)
	}
	if in == 0 || out != 0 {
		t.Fatalf("items seen: own tenant %d (want > 0), other tenant %d (want 0)", in, out)
	}
	mustCall(t, e, other, http.MethodPost, docTreeAPI+"/"+doc+"/items", bs, map[string]any{"anchor": ids["A"], "where": "child", "title": "x"}, 404)
	mustCall(t, e, other, http.MethodDelete, docTreeAPI+"/"+doc+"/items/"+ids["A"], bs, nil, 404)
	mustCall(t, e, other, http.MethodPatch, docTreeAPI+"/"+doc+"/items/"+ids["A"], bs, map[string]any{"field": "title", "value": "x", "rev": 1}, 404)
	t.Logf("9e: own tenant saw %d rows (control), other tenant %d rows, its structural ops 404", in, out)
}

// TestWorkspaceDocSearchAndTopic: spec 100's words find an item, and the
// topic link reads back both ways (doc -> topic, topic -> docs).
func TestWorkspaceDocSearchAndTopic(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	doc, ids := docTree(t, e, tid, as)
	mustCall(t, e, tid, http.MethodPatch, docTreeAPI+"/"+doc+"/items/"+ids["B.1"], as,
		map[string]any{"field": "body", "value": "the zebrafish section", "rev": 1}, 200)
	hits := dtList(mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/search?q=Zebrafish&doc="+doc, as, nil, 200), "hits")
	if len(hits) != 1 || dtStr(hits[0], "item") != ids["B.1"] {
		t.Fatalf("search zebrafish = %v, want B.1 only", hits)
	}
	topic := uuidV4()
	mustCall(t, e, tid, http.MethodPut, docTreeAPI+"/"+doc+"/topic", as, map[string]any{"topic_id": topic}, 200)
	if h := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc, as, nil, 200); dtStr(h, "topic_id") != topic {
		t.Fatalf("head topic_id = %v, want %s", h["topic_id"], topic)
	}
	docs := dtList(mustCall(t, e, tid, http.MethodGet, docTreeAPI+"?topic="+topic, as, nil, 200), "docs")
	if len(docs) != 1 || dtStr(docs[0], "id") != doc {
		t.Fatalf("docs of the topic = %v", docs)
	}
	mustCall(t, e, tid, http.MethodPut, docTreeAPI+"/"+doc+"/topic", as, map[string]any{"topic_id": ""}, 200)
	if n := len(dtList(mustCall(t, e, tid, http.MethodGet, docTreeAPI+"?topic="+topic, as, nil, 200), "docs")); n != 0 {
		t.Fatalf("after unlink the topic lists %d docs", n)
	}
}

// TestWorkspaceDocOffOnMemory: the memory store has no tree: 404 off.
func TestWorkspaceDocOffOnMemory(t *testing.T) {
	mem := store.NewMemory()
	e := rbacEnv(t, func(o *hub.Options) { o.Store = mem })
	e.st = mem
	tid, _ := e.tenant()
	_, out := call(t, e, tid, http.MethodGet, docTreeAPI, seat(t, e, tid, "developer"), nil)
	if dtStr(out, "error") != "workspace_doc_tree_off" {
		t.Fatalf("memory store: %v, want workspace_doc_tree_off", out)
	}
}

// TestWorkspaceDocDescription: create stores the meta description (rdb 0164,
// trimmed, "" = none) and the head and the list return it; over 1000
// characters is a 400.
func TestWorkspaceDocDescription(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	d := mustCall(t, e, tid, http.MethodPost, docTreeAPI, as,
		map[string]any{"title": "plan", "description": "  the quarter's three outcomes  "}, 200)
	doc := dtStr(d, "id")
	if got := dtStr(mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc, as, nil, 200), "description"); got != "the quarter's three outcomes" {
		t.Fatalf("head description = %q", got)
	}
	bare := dtStr(mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "bare"}, 200), "id")
	want := map[string]string{doc: "the quarter's three outcomes", bare: ""}
	seen := 0
	for _, h := range dtList(mustCall(t, e, tid, http.MethodGet, docTreeAPI, as, nil, 200), "docs") {
		if w, ok := want[dtStr(h, "id")]; ok {
			seen++
			if got, has := h["description"]; !has || got != w {
				t.Fatalf("list description of %s = %v (present %v), want %q", dtStr(h, "title"), got, has, w)
			}
		}
	}
	if seen != 2 {
		t.Fatalf("list showed %d of the 2 new documents", seen)
	}
	mustCall(t, e, tid, http.MethodPost, docTreeAPI, as,
		map[string]any{"title": "long", "description": strings.Repeat("d", 1001)}, 400)
}
