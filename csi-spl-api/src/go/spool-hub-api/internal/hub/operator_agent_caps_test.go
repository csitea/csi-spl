package hub_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// TestOperatorAgentCapsRBAC is spec 147's R2 red control (C2, AC-02): the
// admin of a workspace that is not the operator one gets 403
// operator.workspaces on every caps route, its own workspace included, and
// nothing changes; every other role likewise. CONTROL: the operator
// workspace's admin sets, reads and deletes the same caps.
func TestOperatorAgentCapsRBAC(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	caps := map[string]any{"caps": map[string]any{"claude": 1, "grok": 1, "agy": 2, "mistral": 1}}
	path := opPath + "/" + other + "/agent-caps"
	routes := []struct {
		method, path string
		body         any
	}{
		{http.MethodGet, path, nil},
		{http.MethodPut, path, caps},
		{http.MethodDelete, path + "/claude", nil},
	}
	type caller struct{ name, tenant, hum string }
	denied := []caller{{"workspace admin of the target", other, whoOther[rbac.Admin]}, {"anonymous", op, ""}}
	for _, r := range rbac.RoleIDs {
		if r != rbac.Admin {
			denied = append(denied, caller{"operator " + r, op, who[r]}, caller{"other-workspace " + r, other, whoOther[r]})
		}
	}
	for _, c := range denied {
		for _, x := range routes {
			code, body := call(t, e, c.tenant, x.method, x.path, c.hum, x.body)
			if code != http.StatusForbidden || body["permission"] != "operator.workspaces" {
				t.Errorf("%s: %s %s = %d %v, want 403 operator.workspaces", c.name, x.method, x.path, code, body)
			}
		}
	}
	cs := e.st.(store.AgentCapStore)
	if c, err := cs.AgentCaps(context.Background(), other); err != nil || len(c.Caps) != 0 {
		t.Fatalf("a denied call wrote caps: %+v %v", c, err)
	}

	// CONTROL: the operator admin.
	admin := who[rbac.Admin]
	code, body := call(t, e, op, http.MethodPut, path, admin, caps)
	got, _ := body["caps"].(map[string]any)
	if code != http.StatusOK || body["workspace_id"] != other || got["agy"] != float64(2) || len(got) != 4 || body["updated_by"] != admin {
		t.Fatalf("operator admin PUT = %d %v", code, body)
	}
	if code, body = call(t, e, op, http.MethodGet, path, admin, nil); code != http.StatusOK || len(body["caps"].(map[string]any)) != 4 {
		t.Fatalf("operator admin GET = %d %v", code, body)
	}
	if code, body = call(t, e, op, http.MethodPut, path, admin, map[string]any{"caps": map[string]any{"grok": nil}}); code != http.StatusOK {
		t.Fatalf("PUT null = %d %v", code, body)
	} else if _, has := body["caps"].(map[string]any)["grok"]; has {
		t.Fatalf("null left grok capped: %v", body)
	}
	if code, _ = call(t, e, op, http.MethodDelete, path+"/claude", admin, nil); code != http.StatusNoContent {
		t.Fatalf("DELETE = %d", code)
	}
	if c, _ := cs.AgentCaps(context.Background(), other); len(c.Caps) != 2 || c.Caps["agy"] != 2 || c.Caps["mistral"] != 1 {
		t.Fatalf("after null + delete: %+v", c.Caps)
	}
	for _, x := range []struct {
		method, path string
		body         any
		code         int
		token        string
	}{
		{http.MethodPut, path, map[string]any{"caps": map[string]any{"deepseek": 1}}, 400, "bad_vendor"},
		{http.MethodPut, path, map[string]any{"caps": map[string]any{"claude": -1}}, 400, "bad_cap"},
		{http.MethodPut, path, map[string]any{"caps": map[string]any{"claude": 1.5}}, 400, "bad_cap"},
		{http.MethodPut, path, map[string]any{"caps": map[string]any{"claude": "1"}}, 400, "bad_cap"},
		{http.MethodPut, path, map[string]any{"caps": map[string]any{}}, 400, "bad_json"},
		{http.MethodDelete, path + "/deepseek", nil, 400, "bad_vendor"},
		{http.MethodPut, opPath + "/" + newTenantID("no") + "/agent-caps", caps, 404, "not_found"},
	} {
		if code, body := call(t, e, op, x.method, x.path, admin, x.body); code != x.code || body["error"] != x.token {
			t.Errorf("%s %s %v = %d %v, want %d %s", x.method, x.path, x.body, code, body, x.code, x.token)
		}
	}
	// FR-008: one audit row per changed vendor: 4 sets, the grok null, the claude delete.
	trail, err := e.st.(store.OperatorWorkspaces).OperatorAuditOf(context.Background(), other, 50)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, a := range trail {
		if a.Action == store.AuditSetAgentCaps || a.Action == store.AuditDeleteAgentCap {
			n++
			if a.ActorHum != admin || a.ActorTenant != op {
				t.Errorf("audit actor: %+v", a)
			}
		}
	}
	if n != 6 {
		t.Fatalf("agent cap audit rows = %d, want 6: %+v", n, trail)
	}
}
