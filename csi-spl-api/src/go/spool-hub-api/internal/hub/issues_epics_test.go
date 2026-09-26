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
	// ...and back, under an epic; kind issue without one is refused.
	if code, out := patch("SPL-6", map[string]any{"kind": "issue"}); code != 400 || out["error"] != "epic_required" {
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
