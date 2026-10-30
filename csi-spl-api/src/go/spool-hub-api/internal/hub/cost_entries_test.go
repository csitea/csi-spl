package hub_test

import (
	"net/http"
	"testing"
)

const costEntryPath = "/v1/operator/cost-entries"

// SPL-4383: the cost entries are the operator admin's (the fleet-tokens
// door): a developer of the operator workspace, another workspace's admin
// and an anonymous caller are refused on every route. The admin creates,
// lists by type and month, and deletes an entry; a bad entry and a bad filter
// are refused. CONTROL: the admin's own list read answers 200.
func TestCostEntryRoutes(t *testing.T) {
	r := newFleetTokensRig(t)
	entry := map[string]any{"type": "cloud", "label": "prd project", "amount": 212.5, "currency": "EUR", "period": "2020-03", "note": "test fixture"}
	for name, who := range map[string][2]string{"operator developer": {r.op, r.dev}, "other workspace admin": {r.other, r.otherA}, "anonymous": {r.op, ""}} {
		for _, rt := range [][2]string{{http.MethodGet, costEntryPath}, {http.MethodPost, costEntryPath},
			{http.MethodDelete, costEntryPath + "/00000000-0000-4000-8000-000000000000"}} {
			var body any
			if rt[0] == http.MethodPost {
				body = entry
			}
			if code, got := call(t, r.e, who[0], rt[0], rt[1], who[1], body); code != http.StatusForbidden || got["permission"] != "operator.workspaces" {
				t.Errorf("%s %s %s: %d %v, want 403 operator.workspaces", name, rt[0], rt[1], code, got)
			}
		}
	}
	if code, got := call(t, r.e, r.op, http.MethodGet, costEntryPath, r.admin, nil); code != http.StatusOK || got["entries"] == nil {
		t.Fatalf("CONTROL admin list: %d %v", code, got)
	}
	code, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, r.admin, entry)
	id, _ := got["id"].(string)
	if code != http.StatusCreated || id == "" || got["created_by"] != r.admin || got["period"] != "2020-03" || got["amount"] != 212.5 {
		t.Fatalf("create: %d %v", code, got)
	}
	t.Cleanup(func() { call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil) })
	for name, bad := range map[string]map[string]any{
		"ai type":       {"type": "ai", "label": "x", "amount": 1, "currency": "USD", "period": "2020-03"},
		"a day":         {"type": "hr", "label": "x", "amount": 1, "currency": "USD", "period": "2020-03-01"},
		"zero amount":   {"type": "hr", "label": "x", "amount": 0, "currency": "USD", "period": "2020-03"},
		"unknown field": {"type": "hr", "label": "x", "amount": 1, "currency": "USD", "period": "2020-03", "price": 1},
	} {
		if code, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, r.admin, bad); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v, want 400", name, code, got)
		}
	}
	for _, q := range []string{"?type=ai", "?month=2020-3", "?month=2020-03-01"} {
		if code, got := call(t, r.e, r.op, http.MethodGet, costEntryPath+q, r.admin, nil); code != http.StatusBadRequest {
			t.Errorf("list %s: %d %v, want 400", q, code, got)
		}
	}
	count := func(q string) int {
		code, got := call(t, r.e, r.op, http.MethodGet, costEntryPath+q, r.admin, nil)
		if code != http.StatusOK {
			t.Fatalf("list %s: %d %v", q, code, got)
		}
		n := 0
		for _, e := range got["entries"].([]any) {
			if e.(map[string]any)["id"] == id {
				n++
			}
		}
		return n
	}
	if count("?type=cloud&month=2020-03") != 1 || count("?type=hr&month=2020-03") != 0 || count("?type=cloud&month=2020-04") != 0 {
		t.Fatal("the type and month filters do not select the entry")
	}
	if code, _ := call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil); code != http.StatusNoContent {
		t.Fatalf("delete: %d", code)
	}
	if code, _ := call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil); code != http.StatusNotFound {
		t.Fatalf("second delete: %d, want 404", code)
	}
}
