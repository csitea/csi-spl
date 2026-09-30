package hub_test

import (
	"context"
	"fmt"
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
		"epic": "SPL-1", "title": "Login breaks", "description": "## steps", "priority": 2, "level": 2, "assignee": "CLE-07",
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
		"assignee": dev, "status": "todo", "parent": "SPL-1"})
	if code != http.StatusCreated || issueOf(t, out)["parent"] != "SPL-1" || issueOf(t, out)["epic"] != "SPL-1" || issueOf(t, out)["kind"] != "issue" {
		t.Fatalf("create 2: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", tester, map[string]any{"title": "Someday", "epic": "SPL-1"})
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
		{map[string]any{"title": "x", "epic": "SPL-1", "level": 4}, 400, "bad_issue"},
		{map[string]any{"title": "x", "epic": "SPL-1", "level": 3}, 400, "bad_issue"}, // the tree says 2 (rdb 0056)
		{map[string]any{"title": "x", "status": "doing"}, 400, "bad_issue"},
		{map[string]any{"title": "x", "deadline": "tomorrow"}, 400, "bad_issue"},
		{map[string]any{"title": "x", "labels": []string{"nope"}}, 400, "unknown_label"},
		{map[string]any{"title": "x", "assignee": "HUM-999999"}, 400, "bad_assignee"},
		{map[string]any{"title": "x", "assignee": "GRK-404"}, 400, "bad_assignee"},
		{map[string]any{"title": "x", "parent": "SPL-99"}, 400, "unknown_parent"},
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
	// rdb 0061 (SPL-966): 05-blocked and 06-onhold sit between 03-diss and 07-qas.
	if st := fmt.Sprint(out["statuses"]); st != "[eval todo wip diss blocked onhold qas done]" {
		t.Fatalf("statuses %s", st)
	}
	if c := out["counts"].(map[string]any); c["blocked"] != float64(0) || c["onhold"] != float64(0) {
		t.Fatalf("counts carry the new statuses %v", c)
	}
	if ls := out["labels"].([]any); len(ls) != 1 { // bug; kind is a column (rdb 0053), not a label
		t.Fatalf("labels %v", ls)
	}
	for q, want := range map[string][]string{
		"?sort=level":                           {"SPL-4", "SPL-3", "SPL-2"}, // all level 2: newest first
		"?sort=deadline":                        {"SPL-2", "SPL-4", "SPL-3"},
		"?status=todo":                          {"SPL-3"},
		"?priority=5":                           {"SPL-4"},
		"?level=2":                              {"SPL-3", "SPL-2", "SPL-4"},
		"?level=1,3":                            {},
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

	for _, st := range []string{"blocked", "onhold"} {
		code, out := call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-4", tester, map[string]any{"status": st})
		if code != http.StatusOK || issueOf(t, out)["status"] != st || issueOf(t, out)["completed_at"] != "" {
			t.Fatalf("status %s: %d %v", st, code, out)
		}
		readType(t, watcher, "issue")
		code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues?kind=issue&status="+st, dev, nil)
		if code != http.StatusOK || !sameKeys(issueKeys(out), "SPL-4") {
			t.Fatalf("?status=%s: %d %v", st, code, issueKeys(out))
		}
	}
	if code, _ := call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-4", tester, map[string]any{"status": "eval"}); code != http.StatusOK {
		t.Fatalf("back to eval %d", code)
	}
	readType(t, watcher, "issue")

	// Patch: status into done stamps completed_at; clears; the frame follows.
	code, out = call(t, e, tid, http.MethodPatch, "/v1/issues/spl-2", tester, map[string]any{
		"status": "done", "assignee": "", "deadline": "", "labels": []string{}})
	up := issueOf(t, out)
	if code != http.StatusOK || up["status"] != "done" || up["completed_at"] == "" || up["assignee"] != "" || up["deadline"] != "" ||
		up["updated_by"] != tester || up["title"] != "Login breaks" || up["level"] != float64(2) {
		t.Fatalf("patch: %d %v", code, out)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "update" || f["issue"].(map[string]any)["status"] != "done" {
		t.Fatalf("update frame %v", f)
	}
	// SPL-18 (rdb 0053): a leaf issue under another issue is a subtask.
	code, out = call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-2", dev, map[string]any{"parent": "SPL-3"})
	if sub := issueOf(t, out); code != 200 || sub["kind"] != "subtask" || sub["epic"] != "SPL-1" || sub["parent"] != "SPL-3" || sub["level"] != float64(3) {
		t.Fatalf("subtask: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	if code, out := call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-2", dev, map[string]any{"epic": "SPL-3"}); code != 400 || out["error"] != "bad_epic" {
		t.Fatalf("epic names a level-2 issue: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-2", dev, map[string]any{"epic": "SPL-1"}); code != 200 || issueOf(t, out)["kind"] != "issue" || issueOf(t, out)["level"] != float64(2) {
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
		if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Methods") != "POST, PATCH, DELETE" {
			t.Fatalf("%s preflight %d %v", p, resp.StatusCode, resp.Header)
		}
	}
}

// SPL-1027 (spec 039 FR-009): DELETE is a soft delete by the creator or a
// tenant.settings role; a parent with live children is refused; the frame
// says op delete; the deleted issue is a 404, off the list, and never a parent.
func TestIssuesDelete(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	tester := seat(t, e, tid, rbac.Tester)
	admin := seat(t, e, tid, rbac.Admin)
	watcher := dialMember(t, e, tid, "Tess", tester)
	mk := func(who string, body map[string]any) string {
		t.Helper()
		code, out := call(t, e, tid, http.MethodPost, "/v1/issues", who, body)
		if code != http.StatusCreated {
			t.Fatalf("create %v: %d %v", body, code, out)
		}
		readType(t, watcher, "issue")
		return issueOf(t, out)["key"].(string)
	}
	epic := mk(dev, map[string]any{"title": "Epic", "kind": "epic"})
	parent := mk(dev, map[string]any{"title": "Parent", "epic": epic})
	sub := mk(tester, map[string]any{"title": "Sub", "parent": parent})
	other := mk(dev, map[string]any{"title": "Other", "epic": epic})

	del := func(who, key string) (int, map[string]any) {
		t.Helper()
		return call(t, e, tid, http.MethodDelete, "/v1/issues/"+key, who, nil)
	}
	// someone else's issue: a developer may not, an admin may
	if code, out := del(tester, other); code != http.StatusForbidden || out["error"] != "forbidden" {
		t.Fatalf("tester deletes dev's issue: %d %v", code, out)
	}
	// a parent with a live subtask is refused, whoever asks
	if code, out := del(dev, parent); code != http.StatusConflict || out["error"] != "issue_has_children" {
		t.Fatalf("parent with a child: %d %v", code, out)
	}
	if code, out := del(dev, "SPL-99"); code != http.StatusNotFound {
		t.Fatalf("unknown: %d %v", code, out)
	}
	// the creator deletes the subtask; the frame names it
	code, out := del(tester, sub)
	if code != http.StatusOK || issueOf(t, out)["key"] != sub {
		t.Fatalf("creator delete: %d %v", code, out)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "delete" || f["issue"].(map[string]any)["key"] != sub {
		t.Fatalf("delete frame %v", f)
	}
	// gone: 404 on read, patch and a second delete, off the list, not a parent
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/issues/"+sub, tester, nil); code != http.StatusNotFound {
		t.Fatalf("read deleted: %d", code)
	}
	if code, _ := call(t, e, tid, http.MethodPatch, "/v1/issues/"+sub, tester, map[string]any{"title": "back"}); code != http.StatusNotFound {
		t.Fatalf("patch deleted: %d", code)
	}
	if code, _ := del(tester, sub); code != http.StatusNotFound {
		t.Fatalf("delete twice: %d", code)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues", tester, nil)
	if code != http.StatusOK {
		t.Fatalf("list: %d %v", code, out)
	}
	for _, k := range issueKeys(out) {
		if k == sub {
			t.Fatalf("deleted %s still listed: %v", sub, issueKeys(out))
		}
	}
	// the parent has no live child now: an admin deletes it (not the creator)
	if code, out := del(admin, parent); code != http.StatusOK {
		t.Fatalf("admin delete: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "x", "parent": parent}); code != http.StatusBadRequest || out["error"] != "unknown_parent" {
		t.Fatalf("child of a deleted parent: %d %v", code, out)
	}
	// a non-member: the tenant door refuses
	if code, _ := del("HUM-999999", other); code != http.StatusForbidden {
		t.Fatalf("non-member delete: %d", code)
	}
}

// TestIssuesCascade: archiving / deleting a whole epic with ?cascade=1 takes
// its descendants with it and the frame names them; the control is that without
// cascade a parent with a live child is still refused (SPL-1226, rdb 0084).
func TestIssuesCascade(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	admin := seat(t, e, tid, rbac.Admin)
	watcher := dialMember(t, e, tid, "Cass", dev)
	mk := func(who string, body map[string]any) string {
		t.Helper()
		code, out := call(t, e, tid, http.MethodPost, "/v1/issues", who, body)
		if code != http.StatusCreated {
			t.Fatalf("create %v: %d %v", body, code, out)
		}
		readType(t, watcher, "issue")
		return issueOf(t, out)["key"].(string)
	}
	epic := mk(dev, map[string]any{"title": "Epic", "kind": "epic"})
	parent := mk(dev, map[string]any{"title": "Parent", "epic": epic})
	sub := mk(dev, map[string]any{"title": "Sub", "parent": parent})

	live := func() []string {
		t.Helper()
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues", dev, nil)
		if code != http.StatusOK {
			t.Fatalf("list: %d %v", code, out)
		}
		return issueKeys(out)
	}

	// Control: archiving the epic without cascade is refused while it has a
	// child - the subtree stays, exactly as a non-cascade delete does.
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues/"+epic+"/archive", dev, nil); code != http.StatusConflict || out["error"] != "issue_has_children" {
		t.Fatalf("non-cascade archive of a parent: %d %v", code, out)
	}
	if len(live()) != 3 {
		t.Fatalf("after the refused archive: want 3 live, got %v", live())
	}

	// Cascade archive: 200, the frame names the two descendants, and all three
	// leave the list.
	code, out := call(t, e, tid, http.MethodPost, "/v1/issues/"+epic+"/archive?cascade=1", dev, nil)
	if code != http.StatusOK {
		t.Fatalf("cascade archive: %d %v", code, out)
	}
	if got := descOf(t, out); len(got) != 2 {
		t.Fatalf("archive descendants: %v", got)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "archive" || len(descFrame(f)) != 2 {
		t.Fatalf("archive frame %v", f)
	}
	if got := live(); len(got) != 0 {
		t.Fatalf("after cascade archive: want none live, got %v", got)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/issues/"+sub, dev, nil); code != http.StatusNotFound {
		t.Fatalf("archived sub still readable: %d", code)
	}

	// Unarchive (admin only) with cascade restores the subtree.
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues/"+epic+"/unarchive", dev, nil); code != http.StatusForbidden {
		t.Fatalf("dev unarchive: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues/"+epic+"/unarchive?cascade=1", admin, nil); code != http.StatusOK {
		t.Fatalf("admin cascade unarchive: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	if got := live(); len(got) != 3 {
		t.Fatalf("after unarchive: want 3 live, got %v", got)
	}

	// Cascade delete: 200, the frame names the descendants, all gone for good.
	code, out = call(t, e, tid, http.MethodDelete, "/v1/issues/"+epic+"?cascade=1", admin, nil)
	if code != http.StatusOK {
		t.Fatalf("cascade delete: %d %v", code, out)
	}
	if got := descOf(t, out); len(got) != 2 {
		t.Fatalf("delete descendants: %v", got)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "delete" || len(descFrame(f)) != 2 {
		t.Fatalf("delete frame %v", f)
	}
	if got := live(); len(got) != 0 {
		t.Fatalf("after cascade delete: want none live, got %v", got)
	}
	for _, k := range []string{epic, parent, sub} {
		if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/issues/"+k, admin, nil); code != http.StatusNotFound {
			t.Fatalf("deleted %s still readable: %d", k, code)
		}
	}
}

// descOf reads the "descendants" array of a {issue, descendants} response.
func descOf(t *testing.T, out map[string]any) []string {
	t.Helper()
	raw, _ := out["descendants"].([]any)
	keys := make([]string, 0, len(raw))
	for _, v := range raw {
		keys = append(keys, v.(string))
	}
	return keys
}

// descFrame reads the "descendants" array off a fanout frame.
func descFrame(f map[string]any) []string {
	raw, _ := f["descendants"].([]any)
	keys := make([]string, 0, len(raw))
	for _, v := range raw {
		if s, ok := v.(string); ok {
			keys = append(keys, s)
		}
	}
	return keys
}
