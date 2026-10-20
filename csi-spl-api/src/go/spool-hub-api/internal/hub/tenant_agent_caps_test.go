package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 147 6.2 (FR-003, P3): every member of a workspace reads its caps
// (every vendor, null = uncapped) and live counts, can_edit false; a write
// to the tenant route is 405; a box reads the same over the lane
// (agent_caps_get, spool caps).
func TestTenantAgentCaps(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	ctx := context.Background()
	if code, body := call(t, e, op, http.MethodPut, opPath+"/"+other+"/agent-caps", who[rbac.Admin],
		map[string]any{"caps": map[string]any{"claude": 1, "agy": 2}}); code != http.StatusOK {
		t.Fatalf("operator PUT = %d %v", code, body)
	}
	b := e.box(other, "box-a", "c-004", "a-004", "q-004")
	e.pin(other, b)
	if err := e.st.TouchBox(ctx, other, "box-a", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := e.st.SetRoster(ctx, other, "box-a", []string{"c-004", "a-004", "q-004"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	check := func(name string, body map[string]any) {
		t.Helper()
		caps, _ := body["caps"].(map[string]any)
		live, _ := body["live"].(map[string]any)
		if body["workspace_id"] != other || len(caps) != 5 || caps["claude"] != float64(1) || caps["agy"] != float64(2) ||
			caps["qwen"] != nil || len(live) != 5 || live["claude"] != float64(1) || live["qwen"] != float64(1) || live["grok"] != float64(0) {
			t.Fatalf("%s: %v", name, body)
		}
	}
	for _, r := range rbac.RoleIDs {
		code, body := call(t, e, other, http.MethodGet, "/v1/tenant/agent-caps", whoOther[r], nil)
		if code != http.StatusOK || body["can_edit"] != false {
			t.Fatalf("%s GET = %d %v", r, code, body)
		}
		check(r, body)
	}
	// P3: no write through the workspace door.
	for _, m := range []string{http.MethodPut, http.MethodPost, http.MethodDelete, http.MethodPatch} {
		if code, _ := call(t, e, other, m, "/v1/tenant/agent-caps", whoOther[rbac.Admin], map[string]any{"caps": map[string]any{"claude": 9}}); code != http.StatusMethodNotAllowed {
			t.Errorf("%s /v1/tenant/agent-caps = %d, want 405", m, code)
		}
	}
	// can_edit: the operator workspace's own admin, on its own workspace.
	if code, body := call(t, e, op, http.MethodGet, "/v1/tenant/agent-caps", who[rbac.Admin], nil); code != http.StatusOK || body["can_edit"] != true {
		t.Fatalf("operator admin can_edit = %d %v", code, body)
	}
	raw, err := b.c.Lane(ctx, "agent_caps_get", "", nil)
	if err != nil {
		t.Fatalf("lane agent_caps_get: %v", err)
	}
	var lane map[string]any
	if err := json.Unmarshal(raw, &lane); err != nil {
		t.Fatal(err)
	}
	check("lane", lane)
	if _, err := b.c.Lane(ctx, "agent_caps_set", "", json.RawMessage(`{"claude":9}`)); err == nil {
		t.Fatal("lane agent_caps_set accepted")
	}
}
