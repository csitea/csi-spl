package main

import (
	"net/http"
	"strings"
	"testing"
)

// Folder ids the stub hub answers DELETE /folders/{id} with an error for.
const (
	dtFolderMissing  = "f404"
	dtFolderNotEmpty = "f409"
)

// serveFolderDelete is the hub's DELETE /v1/workspace/doctree/folders/{id}
// (internal/hub/wsdoc_nodes.go handleDocTreeFolderDelete): 404 for no such
// folder, 409 folder_not_empty for a folder with children unless
// ?recursive=1, else the deleted counts.
func (h *dtHub) serveFolderDelete(w http.ResponseWriter, r *http.Request, id string) {
	switch {
	case id == dtFolderMissing:
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "not_found", "detail": "no such document or item"})
	case id == dtFolderNotEmpty && r.URL.Query().Get("recursive") != "1":
		writeJSON(w, http.StatusConflict, map[string]any{"error": "folder_not_empty",
			"detail": "the folder is not empty: delete it with recursive=1", "folders": 1, "documents": 2})
	default:
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "deleted": true, "folders": 1, "documents": 0,
			"recursive": r.URL.Query().Get("recursive")})
	}
}

// TestDocTreeFolderDelete: folder-delete sends DELETE to the folder's route,
// never ?recursive=1, prints the hub's JSON, and shows the hub's 404 / 409
// refusal as is (SPL-5256; the empty folders of SPL-5245).
func TestDocTreeFolderDelete(t *testing.T) {
	h := newDTHub(t)
	got := dtOK(t, "folder-delete", "f1")
	if got["id"] != "f1" || got["deleted"] != true || got["recursive"] != "" {
		t.Fatalf("folder-delete answer: %v", got)
	}
	if last := h.calls[len(h.calls)-1]; last != "DELETE /v1/workspace/doctree/folders/f1" {
		t.Fatalf("folder-delete called %q", last)
	}
	if last := h.fs[len(h.fs)-1]; last != "" {
		t.Fatalf("folder-delete fs = %q, want none (the workspace)", last)
	}

	t.Setenv("SPOOL_DOCTREE_FS", "repo")
	dtOK(t, "folder-delete", "f2")
	if last := h.fs[len(h.fs)-1]; last != "repo" {
		t.Fatalf("folder-delete under SPOOL_DOCTREE_FS=repo: fs = %q", last)
	}
	t.Setenv("SPOOL_DOCTREE_FS", "")

	for _, c := range []struct {
		id, want string
	}{
		{dtFolderMissing, "no such document or item"},
		{dtFolderNotEmpty, "409: folder_not_empty (the folder is not empty"},
	} {
		rc, out, errOut := captureRun(t, []string{"doctree", "folder-delete", c.id})
		if rc == 0 || out != "" || !strings.Contains(errOut, c.want) {
			t.Errorf("folder-delete %s: rc %d, stdout %q, stderr %q; want non-zero with %q", c.id, rc, out, errOut, c.want)
		}
	}

	n := len(h.calls)
	for _, args := range [][]string{
		{"folder-delete"},
		{"folder-delete", "f1", "f2"},
		{"folder-delete", "f1", "--recursive"},
		{"folder-delete", "f1", "--force"},
	} {
		if rc, _, errOut := captureRun(t, append([]string{"doctree"}, args...)); rc == 0 {
			t.Errorf("%v: rc 0, want a refusal (stderr %q)", args, errOut)
		}
	}
	if rc, _, errOut := captureRun(t, []string{"doctree", "folder-delete"}); !strings.Contains(errOut, "usage: spool doctree folder-delete <folder-id>") {
		t.Errorf("folder-delete with no id: rc %d, stderr %q, want the usage", rc, errOut)
	}
	if rc, out, errOut := captureRun(t, []string{"doctree", "--check", "folder-delete", "f1"}); rc != 0 || out != "" {
		t.Errorf("--check folder-delete f1: rc %d, stdout %q, stderr %q", rc, out, errOut)
	}
	if len(h.calls) != n {
		t.Errorf("a refused or --check folder-delete reached the hub: %v", h.calls[n:])
	}
}
