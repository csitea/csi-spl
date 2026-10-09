package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// TestRoadmapSwitchRoute (specs/112 HUB-2, spec 12.5): GET and PATCH
// /v1/workspaces/{slug}/roadmap. Any member of the workspace reads the
// switch; only a biz_owner or an admin of THAT workspace flips it. Memory,
// and Postgres under SPOOL_TEST_PG_DSN.
func TestRoadmapSwitchRoute(t *testing.T) {
	e, a := syncEnv(t)
	b := syncWorkspace(t, e)
	owner, admin := seat(t, e, a, rbac.BizOwner), seat(t, e, a, rbac.Admin)
	dev, user := seat(t, e, a, rbac.Developer), seat(t, e, a, rbac.RegularUser)
	adminB := seat(t, e, b, rbac.Admin)
	path := func(ws string) string { return "/v1/workspaces/" + ws + "/roadmap" }
	get := func(ws, who string) (int, map[string]any) {
		t.Helper()
		return call(t, e, ws, http.MethodGet, path(ws), who, nil)
	}
	patch := func(ws, who string, body any) (int, map[string]any) {
		t.Helper()
		return call(t, e, ws, http.MethodPatch, path(ws), who, body)
	}
	if code, out := get(a, user); code != http.StatusOK || out["public"] != false || out["workspace"] != a {
		t.Fatalf("member read: %d %v", code, out)
	}
	// CONTROL: a member who is neither biz_owner nor admin gets 403
	for _, who := range []string{dev, user} {
		if code, out := patch(a, who, map[string]any{"public": true}); code != http.StatusForbidden {
			t.Fatalf("member %s on the switch: %d %v", who, code, out)
		}
	}
	// CONTROL: an admin of b naming a is refused and writes nothing
	if code, out := patch(a, adminB, map[string]any{"public": true}); code != http.StatusForbidden || out["error"] != "not_member" {
		t.Fatalf("admin of b on a: %d %v", code, out)
	}
	if code, out := get(a, adminB); code != http.StatusForbidden {
		t.Fatalf("admin of b reads a: %d %v", code, out)
	}
	if code, _ := get(a, ""); code != http.StatusForbidden {
		t.Fatalf("no session: %d", code)
	}
	if _, out := get(a, owner); out["public"] != false {
		t.Fatalf("a refused switch wrote: %v", out)
	}
	// the biz_owner and the admin each flip it
	if code, out := patch(a, owner, map[string]any{"public": true}); code != http.StatusOK || out["public"] != true {
		t.Fatalf("biz_owner on: %d %v", code, out)
	}
	if _, out := get(b, adminB); out["public"] != false {
		t.Fatalf("a's switch turned b: %v", out)
	}
	if code, out := patch(a, admin, map[string]any{"public": false}); code != http.StatusOK || out["public"] != false {
		t.Fatalf("admin off: %d %v", code, out)
	}
	for _, body := range []any{map[string]any{}, map[string]any{"public": true, "audience": "public"}} {
		if code, out := patch(a, admin, body); code != http.StatusBadRequest {
			t.Fatalf("body %v: %d %v", body, code, out)
		}
	}
	if code, _ := patch("rmnosuch1", admin, map[string]any{"public": true}); code != http.StatusForbidden {
		t.Fatalf("no such workspace: %d", code)
	}
}
