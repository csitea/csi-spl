package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-18: epics are first-class. The list carries an epic summary (Linear
// project progress) over every issue, `epic=` filters the list to one epic's
// issues, `kind` turns an issue into an epic and back under the rule, and an
// epic with issues cannot stop being one.
func TestIssueEpics(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	post := func(body map[string]any) map[string]any {
		t.Helper()
		code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, body)
		if code != http.StatusCreated {
			t.Fatalf("create %v: %d %v", body, code, out)
		}
		return issueOf(t, out)
	}
	post(map[string]any{"title": "Auth", "kind": "epic"})                       // SPL-1
	post(map[string]any{"title": "Billing", "kind": "epic", "status": "done"})  // SPL-2
	post(map[string]any{"title": "login", "epic": "SPL-1", "status": "done"})   // SPL-3
	post(map[string]any{"title": "logout", "epic": "SPL-1", "status": "todo"})  // SPL-4
	post(map[string]any{"title": "sso", "epic": "SPL-1", "status": "canceled"}) // SPL-5
	post(map[string]any{"title": "invoice", "epic": "SPL-2"})                   // SPL-6

	code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues?status=todo", dev, nil)
	if code != http.StatusOK {
		t.Fatalf("list %d %v", code, out)
	}
	eps, _ := out["epics"].([]any)
	if len(eps) != 2 {
		t.Fatalf("epics %v", eps)
	}
	// Open epics first; the summary ignores the list's own filter.
	a, b := eps[0].(map[string]any), eps[1].(map[string]any)
	if a["key"] != "SPL-1" || a["total"] != float64(3) || a["done"] != float64(1) || a["canceled"] != float64(1) ||
		a["counts"].(map[string]any)["todo"] != float64(1) || b["key"] != "SPL-2" || b["total"] != float64(1) {
		t.Fatalf("summary %v", eps)
	}
	for q, want := range map[string][]string{
		"?epic=SPL-1":                   {"SPL-5", "SPL-4", "SPL-3"}, // all priority 0: newest first
		"?epic=spl-2":                   {"SPL-6"},
		"?epic=SPL-1,SPL-2&sort=number": {"SPL-6", "SPL-5", "SPL-4", "SPL-3"},
		"?kind=epic":                    {"SPL-2", "SPL-1"},
		"?epic=SPL-1&status=todo":       {"SPL-4"},
	} {
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues"+q, dev, nil)
		if code != http.StatusOK || !sameKeys(issueKeys(out), want...) {
			t.Fatalf("%s: %d %v want %v", q, code, issueKeys(out), want)
		}
	}
	for _, q := range []string{"?epic=nope", "?kind=story"} {
		if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/issues"+q, dev, nil); code != http.StatusBadRequest {
			t.Fatalf("%s: %d", q, code)
		}
	}
	patch := func(key string, body map[string]any) (int, map[string]any) {
		return call(t, e, tid, http.MethodPatch, "/v1/issues/"+key, dev, body)
	}
	// Move an issue to the other epic; an epic with issues stays one.
	if code, out := patch("SPL-4", map[string]any{"epic": "SPL-2"}); code != 200 || issueOf(t, out)["epic"] != "SPL-2" {
		t.Fatalf("move: %d %v", code, out)
	}
	if code, out := patch("SPL-2", map[string]any{"kind": "issue", "epic": "SPL-1"}); code != http.StatusConflict || out["error"] != "epic_has_issues" {
		t.Fatalf("epic with issues -> issue: %d %v", code, out)
	}
	// An issue becomes an epic: the label is added and its epic dropped.
	code, out = patch("SPL-6", map[string]any{"kind": "epic"})
	if up := issueOf(t, out); code != 200 || up["kind"] != "epic" || up["parent"] != "" || up["epic"] != "" {
		t.Fatalf("issue -> epic: %d %v", code, out)
	}
	// ...and back: kind issue without an epic stands alone at level 2
	// (W16, spec 047), then moves under an epic.
	code, out = patch("SPL-6", map[string]any{"kind": "issue"})
	if up := issueOf(t, out); code != 200 || up["kind"] != "issue" || up["epic"] != "" || up["level"] != float64(2) {
		t.Fatalf("epic -> issue without an epic: %d %v", code, out)
	}
	code, out = patch("SPL-6", map[string]any{"kind": "issue", "epic": "SPL-1"})
	if up := issueOf(t, out); code != 200 || up["kind"] != "issue" || up["epic"] != "SPL-1" {
		t.Fatalf("epic -> issue: %d %v", code, out)
	}
	for _, l := range issueOf(t, out)["labels"].([]any) {
		if l == "epic" {
			t.Fatalf("kind issue kept the epic label: %v", out)
		}
	}
}

// SPL-18 (rdb 0053, owner 09:08): level 1 = epics and features (the panel's
// rows, with their kind), level 2 = issues, level 3 = subtasks listed with
// parent=, and `epic` names only a level-1 row.
func TestIssueThreeLevels(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	post := func(body map[string]any) (int, map[string]any) {
		return call(t, e, tid, http.MethodPost, "/v1/issues", dev, body)
	}
	for _, b := range []map[string]any{
		{"title": "Platform", "kind": "epic"},                    // SPL-1
		{"title": "Search", "kind": "feature"},                   // SPL-2
		{"title": "index", "epic": "SPL-2"},                      // SPL-3 level 2
		{"title": "tokenizer", "parent": "SPL-3"},                // SPL-4 subtask
		{"title": "ranker", "parent": "SPL-3", "status": "done"}, // SPL-5 subtask
	} {
		if code, out := post(b); code != http.StatusCreated {
			t.Fatalf("%v: %d %v", b, code, out)
		}
	}
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues/SPL-4", dev, nil)
	if sub := issueOf(t, out); code != 200 || sub["kind"] != "subtask" || sub["epic"] != "SPL-2" || sub["parent"] != "SPL-3" {
		t.Fatalf("subtask JSON: %d %v", code, out)
	}
	if code, out := post(map[string]any{"title": "x", "parent": "SPL-4"}); code != 400 || out["error"] != "bad_epic" {
		t.Fatalf("fourth level: %d %v", code, out)
	}
	if code, out := post(map[string]any{"title": "x", "epic": "SPL-3"}); code != 400 || out["error"] != "bad_epic" {
		t.Fatalf("epic names a level-2 issue: %d %v", code, out)
	}
	for q, want := range map[string][]string{
		"?kind=issue":               {"SPL-3"},
		"?kind=subtask&sort=number": {"SPL-5", "SPL-4"},
		"?parent=SPL-3&sort=number": {"SPL-5", "SPL-4"},
		"?epic=SPL-2&sort=number":   {"SPL-5", "SPL-4", "SPL-3"},
		"?kind=epic,feature":        {"SPL-2", "SPL-1"},
	} {
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues"+q, dev, nil)
		if code != http.StatusOK || !sameKeys(issueKeys(out), want...) {
			t.Fatalf("%s: %d %v want %v", q, code, issueKeys(out), want)
		}
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues", dev, nil)
	eps, _ := out["epics"].([]any)
	if len(eps) != 2 || eps[1].(map[string]any)["kind"] != "feature" || eps[1].(map[string]any)["total"] != float64(1) {
		t.Fatalf("summary: %d %v", code, eps)
	}
}
