package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

const fleetLoadPath = "/v1/operator/fleet-load"

// rdb 0118 (owner HUM-10 t1 c13e8023 msg 5fa43972: "configurable from the
// spool-hub instance only"): only the ADMIN of the operator workspace reads
// or changes the fleet load target. Every other role there, the admin of
// another workspace and the anonymous caller get 403, and nothing they sent
// is applied. CONTROL: the operator admin's PATCH lands.
func TestFleetLoadAdminOnly(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	patch := map[string]any{"low": 10, "high": 20}
	type caller struct{ name, tenant, hum string }
	var denied []caller
	for _, r := range rbac.RoleIDs {
		if r != rbac.Admin {
			denied = append(denied, caller{"operator " + r, op, who[r]})
		}
		denied = append(denied, caller{"other-workspace " + r, other, whoOther[r]})
	}
	denied = append(denied, caller{"anonymous", op, ""})
	for _, c := range denied {
		for _, m := range []string{http.MethodGet, http.MethodPatch} {
			code, body := call(t, e, c.tenant, m, fleetLoadPath, c.hum, patch)
			if code != http.StatusForbidden || body["permission"] != "operator.workspaces" {
				t.Errorf("%s: %s = %d %v, want 403 operator.workspaces", c.name, m, code, body)
			}
		}
	}
	admin := who[rbac.Admin]
	code, body := call(t, e, op, http.MethodGet, fleetLoadPath, admin, nil)
	if code != http.StatusOK || body["low"] != 50.0 || body["high"] != 75.0 || body["source"] != "hub" {
		t.Fatalf("CONTROL: a denied PATCH applied, or the default is not 50/75: %d %v", code, body)
	}
	code, body = call(t, e, op, http.MethodPatch, fleetLoadPath, admin,
		map[string]any{"low": 40, "high": 70, "box_order": []string{"box-a", "box-b"}})
	if code != http.StatusOK || body["low"] != 40.0 || body["high"] != 70.0 {
		t.Fatalf("admin PATCH = %d %v", code, body)
	}
	if o, _ := body["box_order"].([]any); len(o) != 2 || o[0] != "box-a" {
		t.Fatalf("box_order = %v", body["box_order"])
	}
	// A bad value is a 400 and leaves the row; null resets one to the default.
	for _, bad := range []map[string]any{{"low": 70}, {"high": 101}, {"box_order": []string{"Box"}}, {"low": "x"}} {
		if code, _ := call(t, e, op, http.MethodPatch, fleetLoadPath, admin, bad); code != http.StatusBadRequest {
			t.Errorf("PATCH %v = %d, want 400", bad, code)
		}
	}
	code, body = call(t, e, op, http.MethodPatch, fleetLoadPath, admin, map[string]any{"low": nil, "box_order": nil})
	if code != http.StatusOK || body["low"] != 50.0 || body["high"] != 70.0 || len(body["box_order"].([]any)) != 0 {
		t.Fatalf("reset = %d %v", code, body)
	}
}

// A box of the instance reads the target in force over its hello (the
// spawn gate's read), whatever its own workspace; a hub that names no
// operator workspace answers the defaults with source "default".
func TestFleetLoadBox(t *testing.T) {
	e, op, other, who, _ := operatorEnv(t, func(op, _ string) string { return op })
	call(t, e, op, http.MethodPatch, fleetLoadPath, who[rbac.Admin], map[string]any{"high": 60, "box_order": []string{"box-a"}})
	b := e.box(other, "box-b", "CLE-08")
	e.pin(other, b)
	ctx := context.Background()
	raw, err := b.c.Lane(ctx, "fleet_load_get", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Low      int      `json:"low"`
		High     int      `json:"high"`
		BoxOrder []string `json:"box_order"`
		Source   string   `json:"source"`
	}
	if json.Unmarshal(raw, &got) != nil || got.Low != 50 || got.High != 60 || len(got.BoxOrder) != 1 || got.Source != "hub" {
		t.Fatalf("box read %s", raw)
	}
	if _, err := b.c.Lane(ctx, "fleet_load_set", "", nil); err == nil {
		t.Error("a box wrote through an unknown fleet_load op")
	}

	e2, _, other2, _, _ := operatorEnv(t, func(string, string) string { return "" })
	b2 := e2.box(other2, "box-c", "CLE-09")
	e2.pin(other2, b2)
	raw, err = b2.c.Lane(ctx, "fleet_load_get", "", nil)
	if err != nil || json.Unmarshal(raw, &got) != nil || got.Low != 50 || got.High != 75 || got.Source != "default" {
		t.Fatalf("no operator workspace: %s %v", raw, err)
	}
}

// rdb 0134 (owner HUM-10 t1 29b19f85: "target hw load per box"): the
// operator admin sets a band per box; it is admin-only like the rest, a bad
// entry is a 400 that leaves the row, null resets the map, and a box reads
// the per-box bands next to the fleet band.
func TestFleetLoadBoxBands(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	bands := map[string]any{"box-s": map[string]any{"low": 60, "high": 90}}
	if code, _ := call(t, e, other, http.MethodPatch, fleetLoadPath, whoOther[rbac.Admin], map[string]any{"boxes": bands}); code != http.StatusForbidden {
		t.Fatalf("another workspace's admin set a box band: %d", code)
	}
	admin := who[rbac.Admin]
	code, body := call(t, e, op, http.MethodPatch, fleetLoadPath, admin, map[string]any{"boxes": bands})
	bs, _ := body["boxes"].(map[string]any)["box-s"].(map[string]any)
	if code != http.StatusOK || bs["low"] != 60.0 || bs["high"] != 90.0 || body["low"] != 50.0 {
		t.Fatalf("admin PATCH boxes = %d %v", code, body)
	}
	for _, bad := range []map[string]any{
		{"boxes": map[string]any{"Box-s": map[string]any{"low": 1, "high": 2}}},
		{"boxes": map[string]any{"box-s": map[string]any{"low": 80, "high": 70}}},
		{"boxes": map[string]any{"box-s": map[string]any{"low": 10}}},
		{"boxes": map[string]any{"box-s": map[string]any{"low": 10, "high": 20, "hi": 30}}},
		{"boxes": []string{"box-s"}},
	} {
		if code, _ := call(t, e, op, http.MethodPatch, fleetLoadPath, admin, bad); code != http.StatusBadRequest {
			t.Errorf("PATCH %v = %d, want 400", bad, code)
		}
	}
	b := e.box(other, "box-b", "CLE-08")
	e.pin(other, b)
	raw, err := b.c.Lane(context.Background(), "fleet_load_get", "", nil)
	var got struct {
		Low   int                       `json:"low"`
		Boxes map[string]map[string]int `json:"boxes"`
	}
	if err != nil || json.Unmarshal(raw, &got) != nil || got.Low != 50 || got.Boxes["box-s"]["high"] != 90 {
		t.Fatalf("box read %s %v", raw, err)
	}
	code, body = call(t, e, op, http.MethodPatch, fleetLoadPath, admin, map[string]any{"boxes": nil})
	if code != http.StatusOK || len(body["boxes"].(map[string]any)) != 0 {
		t.Fatalf("reset = %d %v", code, body)
	}
}
