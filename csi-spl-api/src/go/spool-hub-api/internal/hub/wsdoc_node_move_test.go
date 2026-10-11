package hub_test

import (
	"net/http"
	"testing"
)

// TestWorkspaceDocNodeMove (spec 120 section 7 POST nodes/{node}/move; gap
// topic t1 b67d5dc7: no route moved a document into a folder): a top-level
// document moves into a folder and /nodes lists it there; the refusals
// answer their own codes, another workspace gets 404. The bounds after each
// move are the store test's (workspace_doc_node_move_test.go).
func TestWorkspaceDocNodeMove(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	folder := dtStr(mustCall(t, e, tid, http.MethodPost, docTreeAPI+"/folders", as, map[string]any{"name": "sys"}, 201), "id")
	mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "ops guide"}, 200)
	var node string
	for _, n := range dtList(mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/nodes", as, nil, 200), "nodes") {
		if dtStr(n, "kind") == "doc" {
			node = dtStr(n, "id")
		}
	}
	if node == "" {
		t.Fatal("the new document has no node id in /nodes")
	}
	moved := mustCall(t, e, tid, http.MethodPost, docTreeAPI+"/nodes/"+node+"/move", as, map[string]any{"parent": folder}, 200)
	if dtStr(moved, "id") != node || dtStr(moved, "parent") != folder {
		t.Fatalf("move answer = %v", moved)
	}
	top := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/nodes", as, nil, 200)
	in := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/nodes?parent="+folder, as, nil, 200)
	if got, want := nodeRows(top)+" | "+nodeRows(in), "folder:sys(1) | doc:ops guide(0)"; got != want {
		t.Fatalf("after the move: %q, want %q", got, want)
	}
	other, _ := e.tenant()
	bs := seat(t, e, other, "developer")
	for _, c := range []struct {
		what, tid, as, node string
		body                map[string]any
		code                int
		err                 string
	}{
		{"into itself", tid, as, folder, map[string]any{"parent": folder}, 409, "move_into_own_subtree"},
		{"under a document", tid, as, folder, map[string]any{"parent": node}, 400, "parent_is_document"},
		{"unknown field", tid, as, node, map[string]any{"parent": "", "ord": 1}, 400, ""},
		{"no such node", tid, as, "00000000-0000-0000-0000-000000000000", map[string]any{"parent": ""}, 404, "not_found"},
		{"another workspace's node", other, bs, node, map[string]any{"parent": ""}, 404, "not_found"},
	} {
		out := mustCall(t, e, c.tid, http.MethodPost, docTreeAPI+"/nodes/"+c.node+"/move", c.as, c.body, c.code)
		if c.err != "" && dtStr(out, "error") != c.err {
			t.Fatalf("%s: error = %v, want %s", c.what, out, c.err)
		}
	}
	mustCall(t, e, tid, http.MethodPost, docTreeAPI+"/nodes/"+node+"/move", as, map[string]any{"parent": ""}, 200)
	if got := nodeRows(mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/nodes", as, nil, 200)); got != "folder:sys(0), doc:ops guide(0)" {
		t.Fatalf("back at the top: %q", got)
	}
	t.Logf("moved in and back out; 5 refusals with their codes")
}
