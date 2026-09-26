package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/039 issues-v1: create, read, patch, labels, filters and sort under
// the real role table, and the live frame another tab sees without a reload.

func issueOf(t *testing.T, body map[string]any) map[string]any {
	t.Helper()
	i, ok := body["issue"].(map[string]any)
	if !ok {
		t.Fatalf("no issue in %v", body)
	}
	return i
}

func issueKeys(body map[string]any) []string {
	var out []string
	list, _ := body["issues"].([]any)
	for _, x := range list {
		out = append(out, x.(map[string]any)["key"].(string))
	}
	return out
}

func sameKeys(got []string, want ...string) bool {
	if len(got) != len(want) {
		return false
	}
	for k := range got {
		if got[k] != want[k] {
			return false
		}
	}
	return true
}

func TestIssuesCreateReadPatchLive(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	tester := seat(t, e, tid, rbac.Tester)
	if err := e.st.SetRoster(context.Background(), tid, "box-a", []string{"CLE-07"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	watcher := dialMember(t, e, tid, "Tess", tester)

	// A label first; a tester may write issues (notes.send, like Linear's
	// "anyone on the team files a bug").
	code, out := call(t, e, tid, http.MethodPost, "/v1/issue-labels", tester, map[string]string{"name": "Bug", "color": "#ff0000"})
	if code != http.StatusCreated || out["label"].(map[string]any)["id"] != "bug" {
		t.Fatalf("label: %d %v", code, out)
	}
	if f := readType(t, watcher, "issue_label"); f["label"].(map[string]any)["name"] != "Bug" {
		t.Fatalf("label frame %v", f)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issue-labels", tester, map[string]string{"name": "bug"}); code != http.StatusConflict {
		t.Fatalf("dup label: %d %v", code, out)
	}

	// SPL-18: every issue has one parent epic; the epic comes first.
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "Auth", "kind": "epic"})
	if ep := issueOf(t, out); code != http.StatusCreated || ep["key"] != "SPL-1" || ep["kind"] != "epic" || ep["epic"] != "" {
		t.Fatalf("epic: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{
		"epic": "SPL-1", "title": "Login breaks", "description": "## steps", "priority": 2, "level": 3, "assignee": "CLE-07",
		"labels": []string{"bug"}, "deadline": "2026-10-01T15:30:00+03:00"})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	one := issueOf(t, out)
	if one["key"] != "SPL-2" || one["status"] != "eval" || one["deadline"] != "2026-10-01T12:30:00Z" || one["created_by"] != dev ||
		one["channel"] != store.ChannelIssues || one["task_id"] == "" || one["assignee"] != "CLE-07" {
		t.Fatalf("created %v", one)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "create" || f["issue"].(map[string]any)["key"] != "SPL-2" {
		t.Fatalf("create frame %v", f)
	}
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", tester, map[string]any{"title": "Urgent thing", "priority": 1,
		"level": 1, "assignee": dev, "status": "todo", "parent": "SPL-1"})
	if code != http.StatusCreated || issueOf(t, out)["parent"] != "SPL-1" || issueOf(t, out)["epic"] != "SPL-1" || issueOf(t, out)["kind"] != "issue" {
		t.Fatalf("create 2: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", tester, map[string]any{"title": "Someday", "level": 5, "epic": "SPL-1"})
	if code != http.StatusCreated {
		t.Fatalf("create 3: %d %v", code, out)
	}
	readType(t, watcher, "issue")

	// Refusals: shape, range, unknown label, assignee nobody can act on.
	for _, bad := range []struct {
		body map[string]any
		code int
		tok  string
	}{
		{map[string]any{"description": "no title"}, 400, "bad_issue"},
		{map[string]any{"title": "x", "priority": 9}, 400, "bad_issue"},
		{map[string]any{"title": "x", "level": -1}, 400, "bad_issue"},
		{map[string]any{"title": "x", "status": "doing"}, 400, "bad_issue"},
		{map[string]any{"title": "x", "deadline": "tomorrow"}, 400, "bad_issue"},
		{map[string]any{"title": "x", "labels": []string{"nope"}}, 400, "unknown_label"},
		{map[string]any{"title": "x", "assignee": "HUM-999999"}, 400, "bad_assignee"},
		{map[string]any{"title": "x", "assignee": "GRK-404"}, 400, "bad_assignee"},
		{map[string]any{"title": "x", "parent": "SPL-99"}, 400, "unknown_parent"},
		{map[string]any{"title": "x"}, 400, "epic_required"},
		{map[string]any{"title": "x", "epic": "SPL-2"}, 400, "bad_epic"},
		{map[string]any{"title": "x", "epic": "SPL-1", "parent": "SPL-2"}, 400, "bad_issue"},
		{map[string]any{"title": "x", "epic": "SPL-1", "kind": "story"}, 400, "bad_issue"},
		{map[string]any{"title": "x", "sneaky": 1}, 400, "bad_json"},
	} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, bad.body); code != bad.code || out["error"] != bad.tok {
			t.Fatalf("%v: %d %v", bad.body, code, out)
		}
	}
	// A non-member neither reads nor writes.
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/issues", "HUM-999999", map[string]any{"title": "x"}); code != http.StatusForbidden {
		t.Fatalf("non-member write %d", code)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/issues", "HUM-999999", nil); code != http.StatusForbidden {
		t.Fatalf("non-member read %d", code)
	}

	// Default sort is Linear's priority: urgent, high, then no priority.
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues?kind=issue", dev, nil)
	if code != http.StatusOK || !sameKeys(issueKeys(out), "SPL-3", "SPL-2", "SPL-4") || out["prefix"] != "SPL" {
		t.Fatalf("list: %d %v", code, issueKeys(out))
	}
	if c := out["counts"].(map[string]any); c["eval"] != float64(2) || c["todo"] != float64(1) || c["done"] != float64(0) {
		t.Fatalf("counts %v", c)
	}
	if ls := out["labels"].([]any); len(ls) != 1 { // bug; kind is a column (rdb 0053), not a label
		t.Fatalf("labels %v", ls)
	}
	for q, want := range map[string][]string{
		"?sort=level":                           {"SPL-4", "SPL-2", "SPL-3"},
		"?sort=deadline":                        {"SPL-2", "SPL-4", "SPL-3"},
		"?status=todo":                          {"SPL-3"},
		"?priority=5":                           {"SPL-4"},
		"?level=1,3&sort=level":                 {"SPL-2", "SPL-3"},
		"?assignee=none":                        {"SPL-4"},
		"?assignee=me":                          {"SPL-3"},
		"?assignee=CLE-07":                      {"SPL-2"},
		"?label=bug":                            {"SPL-2"},
		"?deadline_before=2026-10-02T00:00:00Z": {"SPL-2"},
		"?deadline_after=2026-10-02T00:00:00Z":  {},
	} {
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues?kind=issue&"+q[1:], dev, nil)
		if code != http.StatusOK || !sameKeys(issueKeys(out), want...) {
			t.Fatalf("%s: %d %v want %v", q, code, issueKeys(out), want)
		}
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/issues?sort=chaos", dev, nil); code != http.StatusBadRequest {
		t.Fatalf("bad sort %d", code)
	}

	// Patch: status into done stamps completed_at; clears; the frame follows.
	code, out = call(t, e, tid, http.MethodPatch, "/v1/issues/spl-2", tester, map[string]any{
		"status": "done", "assignee": "", "deadline": "", "labels": []string{}})
	up := issueOf(t, out)
	if code != http.StatusOK || up["status"] != "done" || up["completed_at"] == "" || up["assignee"] != "" || up["deadline"] != "" ||
		up["updated_by"] != tester || up["title"] != "Login breaks" || up["level"] != float64(3) {
		t.Fatalf("patch: %d %v", code, out)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "update" || f["issue"].(map[string]any)["status"] != "done" {
		t.Fatalf("update frame %v", f)
	}
	// SPL-18 (rdb 0053): a leaf issue under another issue is a subtask.
	code, out = call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-2", dev, map[string]any{"parent": "SPL-3"})
	if sub := issueOf(t, out); code != 200 || sub["kind"] != "subtask" || sub["epic"] != "SPL-1" || sub["parent"] != "SPL-3" {
		t.Fatalf("subtask: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	if code, out := call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-2", dev, map[string]any{"epic": "SPL-3"}); code != 400 || out["error"] != "bad_epic" {
		t.Fatalf("epic names a level-2 issue: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-2", dev, map[string]any{"epic": "SPL-1"}); code != 200 || issueOf(t, out)["kind"] != "issue" {
		t.Fatalf("back to level 2: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	if code, _ := call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-2", dev, map[string]any{}); code != 400 {
		t.Fatalf("empty patch %d", code)
	}
	if code, _ := call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-77", dev, map[string]any{"title": "x"}); code != 404 {
		t.Fatalf("missing patch %d", code)
	}

	// Read one; a reload (a fresh GET) keeps every change.
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues/SPL-2", dev, nil)
	if code != http.StatusOK || issueOf(t, out)["status"] != "done" || issueOf(t, out)["description"] != "## steps" {
		t.Fatalf("get: %d %v", code, out)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/issues/SPL-404", dev, nil); code != 404 {
		t.Fatalf("missing get %d", code)
	}

	// Another tenant: its own numbering, none of these rows, no frame here.
	t2, _ := e.tenant()
	dev2 := seat(t, e, t2, rbac.Developer)
	code, out = call(t, e, t2, http.MethodGet, "/v1/view/issues", dev2, nil)
	if code != http.StatusOK || len(issueKeys(out)) != 0 {
		t.Fatalf("t2 list: %d %v", code, out)
	}
	if code, _ := call(t, e, t2, http.MethodGet, "/v1/view/issues/SPL-2", dev2, nil); code != 404 {
		t.Fatalf("t2 reads t1's issue: %d", code)
	}
	if code, _ := call(t, e, t2, http.MethodPost, "/v1/issues", dev2, map[string]any{"title": "t2 epic", "kind": "epic"}); code != http.StatusCreated {
		t.Fatalf("t2 epic %d", code)
	}
	code, out = call(t, e, t2, http.MethodPost, "/v1/issues", dev2, map[string]any{"title": "t2's", "epic": "SPL-1"})
	if code != http.StatusCreated || issueOf(t, out)["key"] != "SPL-2" {
		t.Fatalf("t2 create: %d %v", code, out)
	}
	quiet(t, watcher, "t2's issue reached t1's socket")
}

func TestIssuesPreflight(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	for _, p := range []string{"/v1/issues", "/v1/issues/SPL-1", "/v1/issue-labels"} {
		req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+p, nil)
		req.Header.Set("Origin", wuiOrigin)
		req.Header.Set("Access-Control-Request-Method", "PATCH")
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Methods") != "POST, PATCH" {
			t.Fatalf("%s preflight %d %v", p, resp.StatusCode, resp.Header)
		}
	}
}
