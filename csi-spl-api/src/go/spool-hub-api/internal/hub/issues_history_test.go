package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// rdb 0181 (owner HUM-10 t1 62e48cef): GET /v1/view/issues/{ref}/history is
// the issue's History tab, oldest first, the epic as a key; an unknown issue
// is 404.
func TestIssueHistoryView(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	for _, title := range []string{"Auth", "Billing"} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": title, "kind": "epic"}); code != http.StatusCreated {
			t.Fatalf("epic: %d %v", code, out)
		}
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"epic": "SPL-1", "title": "Login breaks"}); code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPatch, "/v1/issues/SPL-3", dev, map[string]any{"status": "blocked", "epic": "SPL-2"}); code != http.StatusOK {
		t.Fatalf("patch: %d %v", code, out)
	}
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues/SPL-3/history", dev, nil)
	if code != http.StatusOK || out["key"] != "SPL-3" {
		t.Fatalf("history: %d %v", code, out)
	}
	evs, _ := out["events"].([]any)
	var got []string
	for _, x := range evs {
		ev := x.(map[string]any)
		l := ev["event"].(string)
		if f, _ := ev["field"].(string); f != "" {
			o, _ := ev["old"].(string)
			n, _ := ev["new"].(string)
			l += " " + f + " " + o + "->" + n
		}
		if ev["actor"] == "" || ev["at"] == "" {
			t.Fatalf("event without actor or time: %v", ev)
		}
		got = append(got, l)
	}
	if !sameKeys(got, "created", "changed status eval->blocked", "changed parent SPL-1->SPL-2") {
		t.Fatalf("events: %v", got)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues/SPL-99/history", dev, nil); code != http.StatusNotFound {
		t.Fatalf("unknown: %d %v", code, out)
	}
}
