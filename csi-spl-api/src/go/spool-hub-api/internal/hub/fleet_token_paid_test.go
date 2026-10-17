package hub_test

import (
	"net/http"
	"testing"
)

const fleetPaidPath = "/v1/operator/fleet-tokens/paid"

// SPL-2342: the paid items and the effective-price read are the operator
// admin's (the fleet-tokens door): a developer of the operator workspace,
// another workspace's admin and an anonymous caller are refused on every
// route. The admin creates, lists, changes and deletes an item; a bad item
// and a currency the hub holds no rate for are refused; the effective read
// shows a paid vendor with no tokens as not metered. CONTROL: the admin's
// own list read answers 200.
func TestFleetPaidRoutes(t *testing.T) {
	r := newFleetTokensRig(t)
	item := map[string]any{"vendor": "agy", "kind": "subscription", "plan_label": "agy monthly", "amount": 20, "currency": "USD",
		"period_start": "2020-03-01", "period_end": "2020-03-31", "note": "test fixture"}
	for name, who := range map[string][2]string{"operator developer": {r.op, r.dev}, "other workspace admin": {r.other, r.otherA}, "anonymous": {r.op, ""}} {
		for _, rt := range [][2]string{{http.MethodGet, fleetPaidPath}, {http.MethodPost, fleetPaidPath},
			{http.MethodPatch, fleetPaidPath + "/00000000-0000-4000-8000-000000000000"}, {http.MethodDelete, fleetPaidPath + "/00000000-0000-4000-8000-000000000000"},
			{http.MethodGet, "/v1/operator/fleet-tokens/effective"}} {
			var body any
			if rt[0] == http.MethodPost || rt[0] == http.MethodPatch {
				body = item
			}
			if code, got := call(t, r.e, who[0], rt[0], rt[1], who[1], body); code != http.StatusForbidden || got["permission"] != "operator.workspaces" {
				t.Errorf("%s %s %s: %d %v, want 403 operator.workspaces", name, rt[0], rt[1], code, got)
			}
		}
	}
	if code, got := call(t, r.e, r.op, http.MethodGet, fleetPaidPath, r.admin, nil); code != http.StatusOK || got["items"] == nil {
		t.Fatalf("CONTROL admin list: %d %v", code, got)
	}
	code, got := call(t, r.e, r.op, http.MethodPost, fleetPaidPath, r.admin, item)
	id, _ := got["id"].(string)
	if code != http.StatusCreated || id == "" || got["created_by"] != r.admin || got["quantity"] != float64(1) {
		t.Fatalf("create: %d %v", code, got)
	}
	t.Cleanup(func() { call(t, r.e, r.op, http.MethodDelete, fleetPaidPath+"/"+id, r.admin, nil) })
	for name, bad := range map[string]map[string]any{
		"end before start": {"period_end": "2020-02-01"}, "zero amount": {"amount": 0}, "unknown currency": {"currency": "XYZ"},
		"unknown field": {"price": 1},
	} {
		if code, got := call(t, r.e, r.op, http.MethodPatch, fleetPaidPath+"/"+id, r.admin, bad); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v, want 400", name, code, got)
		}
	}
	if code, got := call(t, r.e, r.op, http.MethodPatch, fleetPaidPath+"/"+id, r.admin, map[string]any{"quantity": 2}); code != http.StatusOK ||
		got["quantity"] != float64(2) || got["amount"] != float64(20) || got["plan_label"] != "agy monthly" {
		t.Fatalf("patch: %d %v", code, got)
	}
	code, got = call(t, r.e, r.op, http.MethodGet, "/v1/operator/fleet-tokens/effective?from=2020-03-01&to=2020-03-31", r.admin, nil)
	if code != http.StatusOK || got["days"] != float64(30) {
		t.Fatalf("effective: %d %v", code, got)
	}
	vs, _ := got["vendors"].([]any)
	var agy map[string]any
	for _, v := range vs {
		if m := v.(map[string]any); m["vendor"] == "agy" {
			agy = m
		}
	}
	if agy == nil || agy["status"] != "not_metered" || agy["paid_usd"] != float64(40) || agy["paid_per_day_usd"] != 1.3333 || agy["effective_usd_per_mtok"] != nil {
		t.Fatalf("agy effective row %v", agy)
	}
	if code, _ := call(t, r.e, r.op, http.MethodGet, "/v1/operator/fleet-tokens/effective?from=2020-03-01&to=2022-03-31", r.admin, nil); code != http.StatusBadRequest {
		t.Errorf("a two-year range: %d, want 400", code)
	}
	if code, _ := call(t, r.e, r.op, http.MethodDelete, fleetPaidPath+"/"+id, r.admin, nil); code != http.StatusNoContent {
		t.Fatalf("delete: %d", code)
	}
	if code, _ := call(t, r.e, r.op, http.MethodDelete, fleetPaidPath+"/"+id, r.admin, nil); code != http.StatusNotFound {
		t.Fatalf("second delete: %d, want 404", code)
	}
	if code, _ := call(t, r.e, r.op, http.MethodPatch, fleetPaidPath+"/"+id, r.admin, map[string]any{"quantity": 1}); code != http.StatusNotFound {
		t.Fatalf("patch of a deleted item: %d, want 404", code)
	}
}
