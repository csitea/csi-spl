package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// CLE-77816 (owner, topic 4365c545): "there is no edit epic/feature on the
// issues interface … it should allow the edition of the epic / feature type of
// issues the same way the issues modal dialog is done". The dialog PATCHes one
// field at a time, so a level-1 row (an epic or a feature, even one with issues
// under it) must take the same edits an issue does — none dropped — and its
// kind must toggle between epic and feature without touching the tree.
func TestIssueEpicEdit(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	tester := seat(t, e, tid, rbac.Tester)
	// a label to edit onto the epic (id "bug"), like TestIssuesCreateReadPatchLive
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issue-labels", tester, map[string]string{"name": "Bug", "color": "#ff0000"}); code != http.StatusCreated {
		t.Fatalf("label: %d %v", code, out)
	}
	post := func(body map[string]any) map[string]any {
		t.Helper()
		code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, body)
		if code != http.StatusCreated {
			t.Fatalf("create %v: %d %v", body, code, out)
		}
		return issueOf(t, out)
	}
	patch := func(key string, body map[string]any) (int, map[string]any) {
		t.Helper()
		return call(t, e, tid, http.MethodPatch, "/v1/issues/"+key, dev, body)
	}

	post(map[string]any{"title": "Auth", "kind": "epic"})   // SPL-1
	post(map[string]any{"title": "login", "epic": "SPL-1"}) // SPL-2, so the epic has a child

	// Every field the dialog edits lands on the level-1 row — nothing is
	// dropped for level 1, and the epic keeps its child (no move).
	code, out := patch("SPL-1", map[string]any{
		"title": "Authentication", "description": "## the epic\nwhat and why",
		"status": "eval", "priority": 1, "assignee": dev,
		"deadline": "2026-10-01T15:30:00+03:00", "labels": []string{"bug"},
	})
	up := issueOf(t, out)
	if code != 200 || up["title"] != "Authentication" || up["description"] != "## the epic\nwhat and why" ||
		up["status"] != "eval" || up["priority"] != float64(1) || up["assignee"] != dev ||
		up["deadline"] != "2026-10-01T12:30:00Z" || up["kind"] != "epic" || up["level"] != float64(1) {
		t.Fatalf("edit epic fields: %d %v", code, out)
	}
	if labels, _ := up["labels"].([]any); len(labels) != 1 || labels[0] != "bug" {
		t.Fatalf("epic labels: %v", up["labels"])
	}
	// The child still resolves under the epic after the edit.
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues?epic=SPL-1", dev, nil); code != 200 || !sameKeys(issueKeys(out), "SPL-2") {
		t.Fatalf("epic keeps its child: %d %v", code, out)
	}

	// Kind toggles epic -> feature: both are level 1, so the row stays at
	// level 1 with no parent and its issues are untouched.
	code, out = patch("SPL-1", map[string]any{"kind": "feature"})
	if up := issueOf(t, out); code != 200 || up["kind"] != "feature" || up["level"] != float64(1) || up["parent"] != "" || up["epic"] != "" {
		t.Fatalf("epic -> feature: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues?epic=SPL-1", dev, nil); code != 200 || !sameKeys(issueKeys(out), "SPL-2") {
		t.Fatalf("feature keeps the child: %d %v", code, out)
	}
	// ...and back to epic, still level 1.
	code, out = patch("SPL-1", map[string]any{"kind": "epic"})
	if up := issueOf(t, out); code != 200 || up["kind"] != "epic" || up["level"] != float64(1) {
		t.Fatalf("feature -> epic: %d %v", code, out)
	}
}
