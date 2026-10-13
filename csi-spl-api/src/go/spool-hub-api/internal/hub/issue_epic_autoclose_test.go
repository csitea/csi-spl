package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-1729 (owner HUM-10, t1 1ccf3a20, poll 954cd02f: "B — Close it
// automatically"): closing the last open issue of an epic closes the epic,
// archives it with its issues (the SPL-1643 cascade), answers epic_closed,
// tells the tabs and comments on the epic. Control: closing an issue while
// another one is open leaves the epic alone.
func TestEpicAutoClose(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	watcher := dialMember(t, e, tid, "Cass", dev)
	since := time.Now().UTC().Add(-time.Minute)
	type row struct{ key, task string }
	mk := func(body map[string]any) row {
		t.Helper()
		code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, body)
		if code != http.StatusCreated {
			t.Fatalf("create %v: %d %v", body, code, out)
		}
		readType(t, watcher, "issue")
		i := issueOf(t, out)
		return row{i["key"].(string), i["task_id"].(string)}
	}
	closeIt := func(key, status string) map[string]any {
		t.Helper()
		code, out := call(t, e, tid, http.MethodPatch, "/v1/issues/"+key, dev, map[string]any{"status": status})
		if code != http.StatusOK {
			t.Fatalf("close %s: %d %v", key, code, out)
		}
		return out
	}

	ep := mk(map[string]any{"title": "Epic", "kind": "epic"})
	a := mk(map[string]any{"title": "A", "epic": ep.key, "status": "wip"})
	b := mk(map[string]any{"title": "B", "epic": ep.key, "status": "wip"})

	if out := closeIt(a.key, "done"); out["epic_closed"] != nil {
		t.Fatalf("CONTROL: an open issue is left, the epic closed: %v", out)
	}
	readType(t, watcher, "issue")

	out := closeIt(b.key, "diss")
	ec, _ := out["epic_closed"].(map[string]any)
	if ec == nil || ec["key"] != ep.key || ec["status"] != "done" || ec["archived"] != true || len(ec["descendants"].([]any)) != 2 {
		t.Fatalf("auto close answer: %v", out)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "update" {
		t.Fatalf("the issue's frame %v", f)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "archive" || len(descFrame(f)) != 2 {
		t.Fatalf("the epic's frame %v", f)
	}
	n, ok, err := e.st.(store.BlockerIssues).FirstPostAfter(context.Background(), tid, ep.task, hub.PublicNoticeFrom, since)
	if err != nil || !ok || !strings.HasPrefix(n.Body, "Closed as done automatically: its last open issue "+b.key+" was closed by "+dev) {
		t.Fatalf("the epic's comment: %v %v %q", err, ok, n.Body)
	}
}
