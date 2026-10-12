package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// unopenedOf is the "unopened" of each listed row by key; a missing field
// reads as "absent".
func unopenedOf(body map[string]any) map[string]any {
	out := map[string]any{}
	list, _ := body["issues"].([]any)
	for _, x := range list {
		row := x.(map[string]any)
		v, ok := row["unopened"]
		if !ok {
			v = "absent"
		}
		out[row["key"].(string)] = v
	}
	return out
}

// SPL-1559 (rdb 0184): an open issue assigned to me that I did not create and
// never opened lists as unopened for me only; POST .../opened clears it for
// me; done rows, epics and my own issues are never new.
func TestIssuesUnopenedUntilOpened(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	tester := seat(t, e, tid, rbac.Tester)
	mk := func(as string, body map[string]any) string {
		t.Helper()
		code, out := call(t, e, tid, http.MethodPost, "/v1/issues", as, body)
		if code != http.StatusCreated {
			t.Fatalf("create %v: %d %v", body, code, out)
		}
		return issueOf(t, out)["key"].(string)
	}
	epic := mk(dev, map[string]any{"title": "Auth", "kind": "epic", "assignee": tester})
	news := mk(dev, map[string]any{"title": "New for tester", "assignee": tester, "parent": epic})
	own := mk(tester, map[string]any{"title": "Tester's own", "assignee": tester})
	done := mk(dev, map[string]any{"title": "Done already", "assignee": tester, "status": "done"})
	devs := mk(tester, map[string]any{"title": "For dev", "assignee": dev})

	list := func(as string) map[string]any {
		t.Helper()
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues", as, nil)
		if code != http.StatusOK {
			t.Fatalf("list: %d %v", code, out)
		}
		return unopenedOf(out)
	}
	got := list(tester)
	want := map[string]any{epic: false, news: true, own: false, done: false, devs: false}
	for k, v := range want {
		if got[k] != v {
			t.Fatalf("tester's list %s unopened = %v, want %v (all %v)", k, got[k], v, got)
		}
	}
	if g := list(dev); g[news] != false || g[devs] != true {
		t.Fatalf("dev's list = %v, want %s opened-for-dev (not his) and %s new", g, news, devs)
	}

	// The single-issue read carries the viewer's mark too.
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues/"+news, tester, nil); code != http.StatusOK || issueOf(t, out)["unopened"] != true {
		t.Fatalf("get %s: %d %v", news, code, out)
	}

	// Opening clears the mark for the tester only, and again is a no-op.
	for range 2 {
		code, out := call(t, e, tid, http.MethodPost, "/v1/issues/"+news+"/opened", tester, nil)
		if code != http.StatusOK || out["key"] != news || out["unopened"] != false {
			t.Fatalf("opened: %d %v", code, out)
		}
	}
	if g := list(tester); g[news] != false {
		t.Fatalf("after open: %s unopened = %v, want false", news, g[news])
	}
	if g := list(dev); g[devs] != true {
		t.Fatalf("dev's %s lost its mark on the tester's open: %v", devs, g)
	}

	// Refusals: no such issue, no member session.
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues/SPL-999/opened", tester, nil); code != http.StatusNotFound {
		t.Fatalf("unknown issue: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues/"+devs+"/opened", "", nil); code == http.StatusOK {
		t.Fatalf("no session: %d %v", code, out)
	}
}
