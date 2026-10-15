package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-2034: a deadline item carries its issue's status and assignee, so the
// calendar's read-only pop-over paints without reading the issue; an event
// carries neither key, and a closed issue stays off the range (SPL-37).
func TestCalendarDeadlineCarriesStatusAndAssignee(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "Auth", "kind": "epic"}); code != http.StatusCreated {
		t.Fatalf("epic: %d %v", code, out)
	}
	for _, b := range []map[string]any{
		{"title": "Due", "status": "wip", "assignee": dev, "deadline": "2026-10-07T15:00:00Z"},
		{"title": "Closed", "status": "done", "assignee": dev, "deadline": "2026-10-08T15:00:00Z"},
	} {
		b["epic"] = "SPL-1"
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, b); code != http.StatusCreated {
			t.Fatalf("issue %v: %d %v", b["title"], code, out)
		}
	}
	calCreate(t, e, tid, dev, calBody("Ship", map[string]any{"kind": "release"}))
	code, out := call(t, e, tid, http.MethodGet, calWeekQuery, dev, nil)
	if code != http.StatusOK || calTitles(out, "events") != "Ship,Due" {
		t.Fatalf("range: %d %v", code, out)
	}
	list := out["events"].([]any)
	if d := list[1].(map[string]any); d["id"] != "SPL-2" || d["status"] != "wip" || d["assignee"] != dev {
		t.Fatalf("deadline item: %v", d)
	}
	ev := list[0].(map[string]any)
	if _, ok := ev["status"]; ok {
		t.Fatalf("event carries status: %v", ev)
	}
	if _, ok := ev["assignee"]; ok {
		t.Fatalf("event carries assignee: %v", ev)
	}
}
