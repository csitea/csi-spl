package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-4788 (HUM-10, topic d60646d9 msg 9030e104): the issue list says
// the highest number the workspace handed out, so the WUI links SPL-4778 only
// where that issue can exist. A deleted top issue keeps it: numbers are never
// reused.
func TestIssueListLastNumber(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)

	list := func() map[string]any {
		t.Helper()
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues?limit=1", dev, nil)
		if code != http.StatusOK {
			t.Fatalf("list: %d %v", code, out)
		}
		return out
	}
	if n, ok := list()["last_number"]; !ok || n != float64(0) {
		t.Fatalf("no issue yet: last_number %v (present %v)", n, ok)
	}
	for _, title := range []string{"one", "two", "three"} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": title}); code != http.StatusCreated {
			t.Fatalf("create %s: %d %v", title, code, out)
		}
	}
	if n := list()["last_number"]; n != float64(3) {
		t.Fatalf("three issues: last_number %v", n)
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/issues/SPL-3", dev, nil); code != http.StatusOK {
		t.Fatalf("delete SPL-3: %d %v", code, out)
	}
	if out := list(); out["last_number"] != float64(3) || out["total"] != float64(2) {
		t.Fatalf("deleted top issue: last_number %v total %v", out["last_number"], out["total"])
	}
}
