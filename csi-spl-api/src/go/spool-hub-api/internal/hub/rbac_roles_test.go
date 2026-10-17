package hub_test

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// strs is a JSON array of strings, in order.
func strs(v any) []string {
	var out []string
	for _, x := range v.([]any) {
		out = append(out, x.(string))
	}
	return out
}

// setRoles gives hum the role set roles in tid, the first one primary.
func setRoles(t *testing.T, e *env, tid, hum string, roles ...string) {
	t.Helper()
	if err := e.st.(store.Humans).SetMemberRoles(context.Background(), tid, hum, roles, roles[0], nil); err != nil {
		t.Fatalf("seat %s as %v: %v", hum, roles, err)
	}
}

// memberRowOf is hum's row of GET /v1/members.
func memberRowOf(t *testing.T, body map[string]any, hum string) map[string]any {
	t.Helper()
	ms, _ := body["members"].([]any)
	for _, m := range ms {
		if row := m.(map[string]any); row["human_id"] == hum {
			return row
		}
	}
	t.Fatalf("no members row for %s in %v", hum, body)
	return nil
}

// 025 §10.2 rules 4-6, §10.5 row R2: the members API over role sets. An
// admin cannot GIVE a set that holds a role it lacks, nor TOUCH a member
// whose set holds one (a non-primary role counts as much as the primary);
// the last owner and the last admin are counted over sets; from_roles is
// the optimistic check. RED CONTROL: Covers on the primary only lets the
// admin manage the {developer, biz_owner} member -> the "admin cannot touch"
// rows go red.
func TestRBACMembersAPIRoles(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	owner := seat(t, e, tid, rbac.BizOwner)
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)
	mixed := seat(t, e, tid, rbac.Developer)
	setRoles(t, e, tid, mixed, rbac.Developer, rbac.BizOwner) // the owner's role as a NON-primary one

	type c struct {
		name, path, as string
		body           any
		want           int
		token          string
	}
	roles := func(hum string) string { return "/v1/members/" + hum + "/roles" }
	for _, x := range []c{
		{"developer cannot set roles", roles(dev), dev, map[string]any{"roles": []string{rbac.Developer, rbac.Tester}}, 403, "forbidden"},
		{"admin cannot give {developer, biz_owner}", roles(dev), admin, map[string]any{"roles": []string{rbac.Developer, rbac.BizOwner}}, 403, "forbidden"},
		{"admin cannot touch a member holding biz_owner as a non-primary role", roles(mixed), admin, map[string]any{"roles": []string{rbac.Developer}}, 403, "forbidden"},
		{"nor through the one-role route", "/v1/members/" + mixed + "/role", admin, map[string]string{"role": rbac.Tester}, 403, "forbidden"},
		{"nor remove it", "/v1/members/" + mixed, admin, nil, 403, "forbidden"},
		{"empty set", roles(dev), admin, map[string]any{"roles": []string{}}, 400, "bad_role"},
		{"unknown role", roles(dev), admin, map[string]any{"roles": []string{"superuser"}}, 400, "bad_role"},
		{"demo_user is not grantable next to another", roles(dev), admin, map[string]any{"roles": []string{rbac.Developer, rbac.DemoUser}}, 400, "bad_role"},
		{"primary outside the set", roles(dev), admin, map[string]any{"roles": []string{rbac.Developer}, "primary": rbac.Tester}, 400, "bad_role"},
		{"stale from_roles", roles(dev), admin, map[string]any{"roles": []string{rbac.Tester}, "from_roles": []string{rbac.Tester}}, 409, "role_changed"},
		{"not a member", roles("HUM-999999"), admin, map[string]any{"roles": []string{rbac.Tester}}, 404, "not_found"},
	} {
		method := http.MethodPut
		if x.body == nil {
			method = http.MethodDelete
		}
		code, body := call(t, e, tid, method, x.path, x.as, x.body)
		if code != x.want || (x.token != "" && body["error"] != x.token) {
			t.Fatalf("%s: %d %v, want %d %s", x.name, code, body, x.want, x.token)
		}
	}

	// The admin gives a set it covers, primary named; from_roles matches.
	code, body := call(t, e, tid, http.MethodPut, roles(dev), admin, map[string]any{
		"roles": []string{rbac.Developer, rbac.Tester}, "primary": rbac.Tester, "from_roles": []string{rbac.Developer}})
	if code != 200 || body["role"] != rbac.Tester || !slices.Equal(strs(body["roles"]), []string{rbac.Tester, rbac.Developer}) {
		t.Fatalf("admin sets {tester, developer}: %d %v", code, body)
	}
	// The set grants the union at once: developer's agents.command rides a tester primary.
	if code, me := call(t, e, tid, http.MethodGet, "/v1/view/me", dev, nil); code != 200 || me["role"] != rbac.Tester ||
		!slices.Equal(strs(me["roles"]), []string{rbac.Tester, rbac.Developer}) || !perms(me)[rbac.AgentsCommand] {
		t.Fatalf("view/me of the two-role member: %d %v", code, me)
	}
	// The mixed member is a tenant owner through its non-primary role.
	if code, me := call(t, e, tid, http.MethodGet, "/v1/view/me", mixed, nil); code != 200 || me["role"] != rbac.Developer || me["tenant_owner"] != true {
		t.Fatalf("view/me of {developer, biz_owner}: %d %v", code, me)
	}
	// GET /v1/members carries the sets, and manageable reads the whole set.
	code, list := call(t, e, tid, http.MethodGet, "/v1/members", admin, nil)
	if code != 200 {
		t.Fatalf("list: %d %v", code, list)
	}
	if row := memberRowOf(t, list, mixed); row["role"] != rbac.Developer || !slices.Equal(strs(row["roles"]), []string{rbac.Developer, rbac.BizOwner}) || row["manageable"] != false {
		t.Fatalf("mixed row %v: want roles [developer biz_owner], manageable false", row)
	}
	if row := memberRowOf(t, list, dev); !slices.Equal(strs(row["roles"]), []string{rbac.Tester, rbac.Developer}) || row["manageable"] != true {
		t.Fatalf("dev row %v", row)
	}

	// Last owner over sets: the plain owner may step down, the mixed member
	// still holds biz_owner; then the mixed member is the last owner.
	if code, body := call(t, e, tid, http.MethodPut, roles(owner), owner, map[string]any{"roles": []string{rbac.Developer}}); code != 200 {
		t.Fatalf("owner steps down while the mixed member holds biz_owner: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodPut, roles(mixed), mixed, map[string]any{"roles": []string{rbac.Developer}}); code != http.StatusConflict || body["error"] != "last_owner" {
		t.Fatalf("the last owner (non-primary) drops it: %d %v, want 409 last_owner", code, body)
	}
	// It may change its primary while keeping the owner role.
	if code, body := call(t, e, tid, http.MethodPut, roles(mixed), mixed, map[string]any{"roles": []string{rbac.Developer, rbac.BizOwner}, "primary": rbac.BizOwner}); code != 200 || body["role"] != rbac.BizOwner {
		t.Fatalf("owner re-primaries: %d %v", code, body)
	}

	// Last admin over sets (no biz_owner in this tenant, as TestMembersAdminAPI).
	e2 := rbacEnv(t)
	t2, _ := e2.tenant()
	a2 := seat(t, e2, t2, rbac.Admin)
	if code, body := call(t, e2, t2, http.MethodPut, roles(a2), a2, map[string]any{"roles": []string{rbac.Developer, rbac.Tester}}); code != http.StatusConflict || body["error"] != "last_admin" {
		t.Fatalf("the last admin drops admin: %d %v, want 409 last_admin", code, body)
	}
	if code, body := call(t, e2, t2, http.MethodPut, roles(a2), a2, map[string]any{"roles": []string{rbac.Developer, rbac.Admin}, "primary": rbac.Developer}); code != 200 || body["role"] != rbac.Developer {
		t.Fatalf("the last admin keeps admin as a non-primary role: %d %v", code, body)
	}
	if code, body := call(t, e2, t2, http.MethodPut, roles(a2), a2, map[string]any{"roles": []string{rbac.Developer}}); code != http.StatusConflict || body["error"] != "last_admin" {
		t.Fatalf("the last admin (non-primary) drops it: %d %v, want 409 last_admin", code, body)
	}

	// Preflight admits PUT on the new route.
	req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+roles(dev), nil)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Access-Control-Request-Method", http.MethodPut)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Origin") != wuiOrigin {
		t.Fatalf("roles preflight %d %v", resp.StatusCode, resp.Header)
	}
}
