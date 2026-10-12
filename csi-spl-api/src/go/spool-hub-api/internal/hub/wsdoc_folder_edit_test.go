package hub_test

import (
	"net/http"
	"testing"
)

// TestWorkspaceDocFolderEditDelete (spec 120 section 7 PATCH / DELETE
// folders/{folder}; the folder row's right-click menu, owner t1 ed2e3583):
// a rename shows in /nodes, a non-empty folder's delete answers 409
// folder_not_empty with its counts, recursive=1 takes the subtree; the
// refusals answer their own codes, another workspace gets 404. The bounds
// after each op are the store test's (workspace_doc_node_edit_test.go).
func TestWorkspaceDocFolderEditDelete(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	folder := dtStr(mustCall(t, e, tid, http.MethodPost, docTreeAPI+"/folders", as, map[string]any{"name": "plans"}, 201), "id")
	mustCall(t, e, tid, http.MethodPost, docTreeAPI+"/folders", as, map[string]any{"name": "notes"}, 201)
	mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "roadmap", "parent": folder}, 200)
	renamed := mustCall(t, e, tid, http.MethodPatch, docTreeAPI+"/folders/"+folder, as, map[string]any{"name": " 2026 "}, 200)
	if dtStr(renamed, "id") != folder || dtStr(renamed, "name") != "2026" {
		t.Fatalf("rename answer = %v", renamed)
	}
	if got := nodeRows(mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/nodes", as, nil, 200)); got != "folder:2026(1), folder:notes(0)" {
		t.Fatalf("after the rename: %q", got)
	}
	other, _ := e.tenant()
	bs := seat(t, e, other, "developer")
	for _, c := range []struct {
		what, tid, as, method, path string
		body                        map[string]any
		code                        int
		err                         string
	}{
		{"a sibling's name", tid, as, http.MethodPatch, "/folders/" + folder, map[string]any{"name": "Notes"}, 409, "name_taken"},
		{"an empty name", tid, as, http.MethodPatch, "/folders/" + folder, map[string]any{"name": " "}, 400, "bad_request"},
		{"an unknown field", tid, as, http.MethodPatch, "/folders/" + folder, map[string]any{"parent": ""}, 400, ""},
		{"another workspace's rename", other, bs, http.MethodPatch, "/folders/" + folder, map[string]any{"name": "x"}, 404, "not_found"},
		{"another workspace's delete", other, bs, http.MethodDelete, "/folders/" + folder + "?recursive=1", nil, 404, "not_found"},
		{"no such folder", tid, as, http.MethodDelete, "/folders/00000000-0000-0000-0000-000000000000", nil, 404, "not_found"},
	} {
		out := mustCall(t, e, c.tid, c.method, docTreeAPI+c.path, c.as, c.body, c.code)
		if c.err != "" && dtStr(out, "error") != c.err {
			t.Fatalf("%s: error = %v, want %s", c.what, out, c.err)
		}
	}
	full := mustCall(t, e, tid, http.MethodDelete, docTreeAPI+"/folders/"+folder, as, nil, 409)
	if dtStr(full, "error") != "folder_not_empty" || dtNum(full, "folders") != 0 || dtNum(full, "documents") != 1 {
		t.Fatalf("non-empty delete = %v, want folder_not_empty {0, 1}", full)
	}
	gone := mustCall(t, e, tid, http.MethodDelete, docTreeAPI+"/folders/"+folder+"?recursive=1", as, nil, 200)
	if gone["deleted"] != true || dtNum(gone, "folders") != 1 || dtNum(gone, "documents") != 1 {
		t.Fatalf("recursive delete = %v", gone)
	}
	if got := nodeRows(mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/nodes", as, nil, 200)); got != "folder:notes(0)" {
		t.Fatalf("after the delete: %q", got)
	}
	if n := len(dtList(mustCall(t, e, tid, http.MethodGet, docTreeAPI, as, nil, 200), "docs")); n != 0 {
		t.Fatalf("the folder's document is still listed: %d docs", n)
	}
	t.Logf("renamed, 409 {0 folders, 1 document}, recursive delete; 6 refusals with their codes")
}
