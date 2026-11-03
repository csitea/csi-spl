package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 125 row B8 (case C-NVS-8; owner HUM-10 C7, C8, C9; SPL-4723): a Qto
// document locked to one human (rdb 0256, wsdoc_lock.go) on testkit
// Postgres. Its owner reads it on every read path; another admin of the same
// workspace, an act-as clone of the owner and an agent token get 404 on a
// direct read and 0 rows in every list, tree and search, and cannot write,
// re-lock or delete it. Each of them still reads an OPEN document holding
// the same word, so a 0 is the lock, not a missing grant.
//
// CONTROLS (commit body): on a database where rdb 0256's human_lock on
// workspace_doc_item is dropped, the doctree search (GET .../doctree/search,
// which reads items without joining the document) finds the locked sections
// for the other admin and this test fails; dropping it on workspace_doc
// fails the list, the head reads and the global search.
//
//	go test ./internal/hub -run WorkspaceDocRestrictedToHuman -v   (SPOOL_TEST_PG_DSN)

// docLockViewer is one caller: a member (hum) or an agent (bearer).
type docLockViewer struct {
	name, hum, bearer string
	sees              bool // the owner: the locked document is theirs
}

// do calls path as v; out is the JSON answer.
func (v docLockViewer) do(t *testing.T, e *env, tid, method, path string, body any) (int, map[string]any) {
	t.Helper()
	if v.bearer == "" {
		return call(t, e, tid, method, path, v.hum, body)
	}
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, e.url(tid)+path, rd)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+v.bearer)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

// docLockRig is the workspace: the owner's locked document and an open one,
// both holding word, and the four callers.
type docLockRig struct {
	e                  *env
	tid, word          string
	locked, open, item string
	viewers            []docLockViewer
}

func newDocLockRig(t *testing.T) *docLockRig {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) { o.SearchRatePerMin = 1000 })
	pg, ok := e.st.(*store.Postgres)
	if !ok {
		t.Skip("the document lock is rdb 0256 RLS: Postgres only (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	owner, admin := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Admin)
	now := time.Now().UTC().Truncate(time.Microsecond)
	cl, err := pg.StartClone(context.Background(), store.CloneStart{TenantID: tid, TargetHum: owner, AdminName: "Admin",
		CreatedBy: admin, ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	b := e.box(tid, "box-lock", "CLE-07")
	e.pin(tid, b)
	r := &docLockRig{e: e, tid: tid, word: "zq" + strings.ReplaceAll(uuidV4()[:8], "-", "")}
	r.viewers = []docLockViewer{{name: "owner", hum: owner, sees: true}, {name: "another admin", hum: admin},
		{name: "act-as clone of the owner", hum: cl.CloneHum}, {name: "agent token", bearer: e.uploadToken(tid, b)}}
	r.locked, r.item = r.mkDoc(t, true, "Balance")
	r.open, _ = r.mkDoc(t, false, "Open")
	return r
}

// mkDoc creates a document as the owner with one section holding the word.
func (r *docLockRig) mkDoc(t *testing.T, restricted bool, title string) (string, string) {
	t.Helper()
	owner := r.viewers[0].hum
	d := mustCall(t, r.e, r.tid, http.MethodPost, docTreeAPI, owner,
		map[string]any{"title": title + " " + r.word, "restricted": restricted}, 200)
	it := mustCall(t, r.e, r.tid, http.MethodPost, docTreeAPI+"/"+dtStr(d, "id")+"/items", owner,
		map[string]any{"rev": dtNum(d, "rev"), "anchor": "", "where": "child", "title": "Assets " + r.word, "body": "the " + r.word + " lines"}, 200)
	return dtStr(d, "id"), dtStr(it, "item")
}

// ids is the set of k of each row of list in out.
func ids(out map[string]any, list, k string) map[string]bool {
	got := map[string]bool{}
	for _, row := range dtList(out, list) {
		got[dtStr(row, k)] = true
	}
	return got
}

func TestWorkspaceDocRestrictedToHuman(t *testing.T) {
	r := newDocLockRig(t)
	if h := mustCall(t, r.e, r.tid, http.MethodGet, docTreeAPI+"/"+r.locked, r.viewers[0].hum, nil, 200); dtStr(h, "restricted_to_human") != r.viewers[0].hum {
		t.Fatalf("the locked head names %q, want the owner %s", dtStr(h, "restricted_to_human"), r.viewers[0].hum)
	}
	for _, v := range r.viewers {
		t.Run(v.name, func(t *testing.T) {
			r.reads(t, v)
			r.lists(t, v)
			if !v.sees {
				r.writes(t, v)
			}
		})
	}
	r.whoMaySet(t)
}

// reads: a direct read of the locked doc is 200 for the owner, 404 for
// anyone else; the open doc is 200 for all.
func (r *docLockRig) reads(t *testing.T, v docLockViewer) {
	t.Helper()
	want := map[bool]int{true: 200, false: 404}[v.sees]
	for _, p := range []string{"", "/children", "/subtree", "/grid", "/children?parent=" + r.item} {
		if code, out := v.do(t, r.e, r.tid, http.MethodGet, docTreeAPI+"/"+r.locked+p, nil); code != want {
			t.Fatalf("GET locked%s: %d %v, want %d", p, code, out, want)
		}
		if p == "/children?parent="+r.item {
			continue
		}
		if code, out := v.do(t, r.e, r.tid, http.MethodGet, docTreeAPI+"/"+r.open+p, nil); code != 200 {
			t.Fatalf("CONTROL GET open%s: %d %v", p, code, out)
		}
	}
}

// lists: the locked doc is in the list, the folder tree, the doctree search
// and the global search for the owner only; the open doc for everyone.
func (r *docLockRig) lists(t *testing.T, v docLockViewer) {
	t.Helper()
	get := func(p string) map[string]any {
		code, out := v.do(t, r.e, r.tid, http.MethodGet, p, nil)
		if code != 200 {
			t.Fatalf("GET %s: %d %v", p, code, out)
		}
		return out
	}
	views := map[string]map[string]bool{
		"list":           ids(get(docTreeAPI), "docs", "id"),
		"tree":           ids(get(docTreeAPI+"/nodes"), "nodes", "doc"),
		"doctree search": ids(get(docTreeAPI+"/search?q="+url.QueryEscape(r.word)), "hits", "doc"),
	}
	if v.bearer == "" {
		code, _, s, _ := searchGet(t, r.e, r.tid, r.word, "", memberHeader, v.hum)
		if code != 200 {
			t.Fatalf("global search: %d", code)
		}
		got := map[string]bool{}
		for _, row := range s.Groups["docs"].Results {
			got[row["doc_id"].(string)] = true
		}
		views["global search"] = got
	}
	for name, got := range views {
		if got[r.locked] != v.sees || !got[r.open] {
			t.Fatalf("%s: locked shown=%v (want %v), open shown=%v (want true)", name, got[r.locked], v.sees, got[r.open])
		}
	}
}

// writes: another caller cannot edit, rename, re-lock, unlock or delete it.
func (r *docLockRig) writes(t *testing.T, v docLockViewer) {
	t.Helper()
	d := docTreeAPI + "/" + r.locked
	for _, w := range []struct {
		method, path string
		body         any
	}{
		{http.MethodPatch, d + "/items/" + r.item, map[string]any{"field": "body", "value": "x", "rev": 1}},
		{http.MethodPost, d + "/items", map[string]any{"anchor": "", "where": "child", "title": "x"}},
		{http.MethodPatch, d, map[string]any{"title": "x"}},
		{http.MethodPut, d + "/lock", map[string]any{"restricted": false}},
		{http.MethodDelete, d, nil},
	} {
		code, out := v.do(t, r.e, r.tid, w.method, w.path, w.body)
		if code != 404 && code != 403 {
			t.Fatalf("%s %s: %d %v, want 404 (or 403 for a caller who may not lock)", w.method, w.path, code, out)
		}
	}
}

// whoMaySet: an agent or a clone may not lock (403 restricted_needs_human);
// the owner lifts the lock and every member reads the doc again.
func (r *docLockRig) whoMaySet(t *testing.T) {
	t.Helper()
	for _, v := range r.viewers[2:] {
		code, out := v.do(t, r.e, r.tid, http.MethodPost, docTreeAPI, map[string]any{"title": "mine", "restricted": true})
		if code != 403 || out["error"] != "restricted_needs_human" {
			t.Fatalf("%s creating a locked doc: %d %v, want 403 restricted_needs_human", v.name, code, out)
		}
	}
	owner, admin := r.viewers[0].hum, r.viewers[1].hum
	mustCall(t, r.e, r.tid, http.MethodPut, docTreeAPI+"/"+r.locked+"/lock", owner, map[string]any{"restricted": false}, 200)
	if h := mustCall(t, r.e, r.tid, http.MethodGet, docTreeAPI+"/"+r.locked, admin, nil, 200); dtStr(h, "restricted_to_human") != "" {
		t.Fatalf("after the unlock: %v", h)
	}
	mustCall(t, r.e, r.tid, http.MethodPut, docTreeAPI+"/"+r.open+"/lock", admin, map[string]any{"restricted": true}, 200)
	mustCall(t, r.e, r.tid, http.MethodGet, docTreeAPI+"/"+r.open, owner, nil, 404)
}
