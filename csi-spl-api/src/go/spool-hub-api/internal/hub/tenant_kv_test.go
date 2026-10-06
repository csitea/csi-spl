package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 098 (rdb 0136): the generic settings ride GET/PATCH /v1/tenant/settings
// as one "settings" object. These keys exist only in this test binary.
func init() {
	store.RegisterTenantSetting(store.TenantSettingDef{Key: "hubtest.flag", Kind: store.SettingBool, Default: false})
	store.RegisterTenantSetting(store.TenantSettingDef{Key: "hubtest.limit", Kind: store.SettingInt, Default: 3, Min: 1, Max: 10})
}

func TestTenantSettingsGeneric(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)

	// A fresh workspace shows every registered key at its default.
	code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/settings", admin, nil)
	if code != 200 {
		t.Fatalf("fresh: %d %v", code, body)
	}
	assertKV(t, body, false, 3)

	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", admin, map[string]any{
		"settings": map[string]any{"hubtest.flag": true, "hubtest.limit": 7}})
	if code != 200 {
		t.Fatalf("patch: %d %v", code, body)
	}
	assertKV(t, body, true, 7)

	// null resets one key; the other stays.
	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", admin, map[string]any{
		"settings": map[string]any{"hubtest.limit": nil}})
	if code != 200 {
		t.Fatalf("reset: %d %v", code, body)
	}
	assertKV(t, body, true, 3)

	// A refused key or value is 400 bad_setting, and nothing else in the
	// same PATCH is written.
	for name, bad := range map[string]any{
		"unknown": map[string]any{"no.such": 1},
		"range":   map[string]any{"hubtest.limit": 11},
		"float":   map[string]any{"hubtest.limit": 2.5},
		"type":    map[string]any{"hubtest.flag": "yes"},
	} {
		code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", admin, map[string]any{
			"display_name": "should-not-stick", "settings": bad})
		if code != http.StatusBadRequest || body["error"] != "bad_setting" {
			t.Errorf("bad %s: %d %v, want 400 bad_setting", name, code, body)
		}
	}
	code, body = call(t, e, tid, http.MethodGet, "/v1/tenant/settings", admin, nil)
	if code != 200 || body["display_name"] == "should-not-stick" {
		t.Fatalf("a refused PATCH wrote the display name: %d %v", code, body)
	}
	assertKV(t, body, true, 3)

	// The write is behind tenant.settings like every other field.
	dev := seat(t, e, tid, rbac.Developer)
	if code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", dev, map[string]any{
		"settings": map[string]any{"hubtest.flag": false}}); code != http.StatusForbidden {
		t.Fatalf("CONTROL: developer wrote settings: %d %v", code, body)
	}
}

func assertKV(t *testing.T, body map[string]any, flag bool, limit float64) {
	t.Helper()
	kv, ok := body["settings"].(map[string]any)
	if !ok {
		t.Fatalf("no settings object: %v", body)
	}
	if kv["hubtest.flag"] != flag || kv["hubtest.limit"] != limit {
		t.Fatalf("settings = %v, want hubtest.flag=%v hubtest.limit=%v", kv, flag, limit)
	}
}
