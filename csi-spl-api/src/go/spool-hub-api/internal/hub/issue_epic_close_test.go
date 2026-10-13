package hub_test

import (
	"context"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-1643 (owner HUM-10, t1 1ccf3a20): closing an epic asks for the
// confirmation while it has open issues, then closes them with its status,
// archives it and all of its issues, comments on each issue it closed, and
// unarchiving the epic brings them back with a comment. A forced cascade
// failure files a bug assigned to whoever closed the epic. Controls: a plain
// issue closes alone; an issue already done gets no comment; a clean cascade
// files no bug.
func TestEpicCloseArchivesIssues(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	admin := seat(t, e, tid, rbac.Admin)
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
	patch := func(key string, body map[string]any) (int, map[string]any) {
		t.Helper()
		return call(t, e, tid, http.MethodPatch, "/v1/issues/"+key, dev, body)
	}
	live := func() map[string]map[string]any {
		t.Helper()
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues", dev, nil)
		if code != http.StatusOK {
			t.Fatalf("list: %d %v", code, out)
		}
		m := map[string]map[string]any{}
		list, _ := out["issues"].([]any)
		for _, x := range list {
			i := x.(map[string]any)
			m[i["key"].(string)] = i
		}
		return m
	}
	note := func(task string) (string, bool) {
		t.Helper()
		n, ok, err := e.st.(store.BlockerIssues).FirstPostAfter(context.Background(), tid, task, hub.PublicNoticeFrom, since)
		if err != nil {
			t.Fatal(err)
		}
		return n.Body, ok
	}
	bugs := func() []map[string]any {
		var out []map[string]any
		for _, i := range live() {
			for _, l := range i["labels"].([]any) {
				if l == "bug" {
					out = append(out, i)
				}
			}
		}
		return out
	}
	strs := func(v any) []string {
		var out []string
		for _, x := range v.([]any) {
			out = append(out, x.(string))
		}
		return out
	}

	ep := mk(map[string]any{"title": "Epic", "kind": "epic"})
	a := mk(map[string]any{"title": "Open", "epic": ep.key, "status": "wip"})
	a1 := mk(map[string]any{"title": "Open subtask", "parent": a.key})
	b := mk(map[string]any{"title": "Done", "epic": ep.key, "status": "done"})
	x := mk(map[string]any{"title": "Plain"})

	// Control: a plain issue closes alone, nothing archived.
	if code, out := patch(x.key, map[string]any{"status": "done"}); code != http.StatusOK || out["archived"] != nil {
		t.Fatalf("plain close: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	if len(live()) != 5 {
		t.Fatalf("plain close moved others: %v", live())
	}

	// No confirmation: refused, naming the count; nothing changed.
	code, out := patch(ep.key, map[string]any{"status": "done"})
	if code != http.StatusConflict || out["error"] != "epic_close_confirm" || !strings.Contains(fmt.Sprint(out["detail"]), "2 open issues") {
		t.Fatalf("unconfirmed epic close: %d %v", code, out)
	}
	if live()[ep.key]["status"] == "done" {
		t.Fatal("the refused close changed the epic")
	}

	// Confirmed: the open issues close, all four leave the list.
	code, out = patch(ep.key, map[string]any{"status": "done", "cascade": true})
	if code != http.StatusOK || out["archived"] != true || !reflect.DeepEqual(strs(out["closed"]), []string{a.key, a1.key}) ||
		!reflect.DeepEqual(strs(out["descendants"]), []string{a.key, a1.key, b.key}) {
		t.Fatalf("confirmed epic close: %d %v", code, out)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "archive" || len(descFrame(f)) != 3 {
		t.Fatalf("epic close frame %v", f)
	}
	l := live()
	for _, k := range []string{ep.key, a.key, a1.key, b.key} {
		if l[k] != nil {
			t.Fatalf("%s still listed", k)
		}
	}
	for _, r := range []row{a, a1} {
		if body, ok := note(r.task); !ok || body != "Closed because its epic "+ep.key+" was closed by "+dev+" at "+body[len(body)-21:] ||
			!strings.HasSuffix(body, "Z.") {
			t.Fatalf("comment on %s: %v %q", r.key, ok, body)
		}
	}
	if _, ok := note(b.task); ok {
		t.Fatal("CONTROL: the issue already done got a comment")
	}
	if n := len(bugs()); n != 0 {
		t.Fatalf("CONTROL: a clean cascade filed %d bugs", n)
	}

	// Unarchive the epic (no cascade flag): its issues come back, done, with a comment.
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues/"+ep.key+"/unarchive", admin, nil); code != http.StatusOK || len(descOf(t, out)) != 3 {
		t.Fatalf("unarchive: %d %v", code, out)
	}
	readType(t, watcher, "issue")
	l = live()
	for _, k := range []string{ep.key, a.key, a1.key, b.key} {
		if l[k] == nil || l[k]["status"] != "done" {
			t.Fatalf("after unarchive %s: %v", k, l[k])
		}
	}
	if body, ok := note(b.task); !ok || !strings.HasPrefix(body, "Restored from the archive because its epic "+ep.key+" was restored by "+admin) ||
		!strings.HasSuffix(body, "its status stays done.") {
		t.Fatalf("unarchive comment: %v %q", ok, body)
	}

	// An epic with no open issue closes without the confirmation.
	f := mk(map[string]any{"title": "Finished", "kind": "feature"})
	mk(map[string]any{"title": "Finished issue", "epic": f.key, "status": "done"})
	if code, out := patch(f.key, map[string]any{"status": "diss"}); code != http.StatusOK || out["archived"] != true || len(strs(out["closed"])) != 0 {
		t.Fatalf("epic with no open issue: %d %v", code, out)
	}

	// Forced failure: the epic closes, its issue stays open, a bug is filed.
	h := mk(map[string]any{"title": "Failing", "kind": "epic"})
	hi := mk(map[string]any{"title": "Failing issue", "epic": h.key})
	store.SetEpicCloseFault(func(tenant string, _ int) error {
		if tenant == tid {
			return fmt.Errorf("forced")
		}
		return nil
	})
	t.Cleanup(func() { store.SetEpicCloseFault(nil) })
	code, out = patch(h.key, map[string]any{"status": "done", "cascade": true})
	if code != http.StatusOK || out["archived"] != false || out["cascade_error"] != "forced" {
		t.Fatalf("failing epic close: %d %v", code, out)
	}
	l = live()
	if l[h.key]["status"] != "done" || l[hi.key]["status"] == "done" {
		t.Fatalf("failing close: epic %v issue %v", l[h.key], l[hi.key])
	}
	bs := bugs()
	if len(bs) != 1 {
		t.Fatalf("bugs after a failed cascade: %v", bs)
	}
	desc := bs[0]["description"].(string)
	if bs[0]["assignee"] != dev || !strings.Contains(desc, "/issues?issue="+h.key) || !strings.Contains(desc, hi.key) ||
		!strings.Contains(desc, "forced") {
		t.Fatalf("the bug: %v", bs[0])
	}
}
