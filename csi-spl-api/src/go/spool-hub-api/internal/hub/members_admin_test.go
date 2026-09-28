package hub_test

import (
	"context"
	"net/http"
	"net/url"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// the admin's Users page API. CONTROL: every role but admin gets
// 403 on every members.invite route (list, invite, revoke, remove); the role
// route is members.roles (admin + biz_owner, 025 §3.2). The admin lists,
// invites (the invitation mail goes out), re-roles, removes and revokes; it
// cannot remove itself nor strand the tenant without an admin.
func TestMembersAdminAPI(t *testing.T) {
	var mu sync.Mutex
	var mailed []string
	e := rbacEnv(t, func(o *hub.Options) {
		o.InviteMail = func(_ context.Context, tenant, email, locale string) (string, error) {
			mu.Lock()
			defer mu.Unlock()
			mailed = append(mailed, tenant+"|"+email+"|"+locale)
			return "sent", nil
		}
	})
	tid, _ := e.tenant()
	who := map[string]string{}
	for _, r := range rbac.RoleIDs {
		who[r] = seat(t, e, tid, r)
	}
	admin := who[rbac.Admin]
	victim := seat(t, e, tid, rbac.Tester)
	pending := "pending-" + tid + "@example.com"
	if code, body := call(t, e, tid, http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": pending, "role": rbac.Tester}); code != http.StatusCreated || body["mail"] != "sent" {
		t.Fatalf("admin invite: %d %v", code, body)
	}
	mu.Lock()
	if len(mailed) != 1 || mailed[0] != tid+"|"+pending+"|" {
		t.Fatalf("invitation mail: %v", mailed)
	}
	mu.Unlock()

	revoke := "/v1/members/invites?email=" + url.QueryEscape(pending)
	for _, role := range rbac.RoleIDs {
		if role == rbac.Admin || role == rbac.BizOwner { // specs/046: both manage members
			continue
		}
		as := who[role]
		for _, x := range []struct {
			method, path string
			body         any
		}{
			{http.MethodGet, "/v1/members", nil},
			{http.MethodPost, "/v1/members/invites", map[string]string{"email": "n-" + role + "@example.com"}},
			{http.MethodDelete, revoke, nil},
			{http.MethodDelete, "/v1/members/" + victim, nil},
		} {
			code, body := call(t, e, tid, x.method, x.path, as, x.body)
			if code != http.StatusForbidden || body["permission"] != rbac.MembersInvite {
				t.Fatalf("CONTROL: %s %s %s = %d %v, want 403 members.invite", role, x.method, x.path, code, body)
			}
		}
		code, _ := call(t, e, tid, http.MethodPut, "/v1/members/"+victim+"/role", as, map[string]string{"role": rbac.Tester})
		if want := http.StatusForbidden; role != rbac.BizOwner && code != want {
			t.Fatalf("CONTROL: %s re-roled a member: %d", role, code)
		}
	}
	// No session: 403 too.
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/members", "", nil); code != http.StatusForbidden {
		t.Fatalf("CONTROL: anonymous list: %d", code)
	}
	// Another tenant's admin sees nothing here.
	other, _ := e.tenant()
	stranger := seat(t, e, other, rbac.Admin)
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/members", stranger, nil); code != http.StatusForbidden {
		t.Fatalf("CONTROL: another tenant's admin listed: %d", code)
	}

	// The admin's list.
	code, body := call(t, e, tid, http.MethodGet, "/v1/members", admin, nil)
	if code != http.StatusOK || body["tenant_id"] != tid || body["you"] != admin {
		t.Fatalf("admin list: %d %v", code, body)
	}
	rows := map[string]map[string]any{}
	for _, m := range body["members"].([]any) {
		row := m.(map[string]any)
		rows[row["human_id"].(string)] = row
	}
	if len(rows) != len(rbac.RoleIDs)+1 || rows[victim]["role"] != rbac.Tester || rows[victim]["email"] == "" ||
		rows[victim]["manageable"] != true || rows[admin]["you"] != true || rows[admin]["manageable"] != false ||
		rows[who[rbac.BizOwner]]["manageable"] != false {
		t.Fatalf("members rows: %v", rows)
	}
	if _, leak := rows[stranger]; leak {
		t.Fatalf("CONTROL: another tenant's member listed")
	}
	ins := body["invites"].([]any)
	if len(ins) != 1 || ins[0].(map[string]any)["email"] != pending || ins[0].(map[string]any)["expired"] != false {
		t.Fatalf("invites: %v", ins)
	}
	grant := map[string]bool{}
	for _, r := range body["roles"].([]any) {
		rr := r.(map[string]any)
		grant[rr["id"].(string)] = rr["grantable"].(bool)
	}
	if len(grant) != len(rbac.RoleIDs) || grant[rbac.BizOwner] || !grant[rbac.Admin] || !grant[rbac.Tester] {
		t.Fatalf("roles: %v", grant)
	}

	for _, x := range []struct {
		name, method, path string
		body               any
		want               int
		token              string
	}{
		{"admin re-roles the victim", http.MethodPut, "/v1/members/" + victim + "/role", map[string]string{"role": rbac.Developer, "from_role": rbac.Tester}, 200, ""},
		{"admin cannot remove itself", http.MethodDelete, "/v1/members/" + admin, nil, 409, "self"},
		{"admin removes the victim", http.MethodDelete, "/v1/members/" + victim, nil, 204, ""},
		{"removed twice", http.MethodDelete, "/v1/members/" + victim, nil, 404, "not_found"},
		{"revoke needs an address", http.MethodDelete, "/v1/members/invites?email=nope", nil, 400, "bad_email"},
		{"admin revokes the invite", http.MethodDelete, revoke, nil, 204, ""},
		{"revoked twice", http.MethodDelete, revoke, nil, 404, "not_found"},
	} {
		code, body := call(t, e, tid, x.method, x.path, admin, x.body)
		if code != x.want || (x.token != "" && body["error"] != x.token) {
			t.Fatalf("%s: %d %v, want %d %s", x.name, code, body, x.want, x.token)
		}
	}
	if _, body := call(t, e, tid, http.MethodGet, "/v1/members", admin, nil); len(body["invites"].([]any)) != 0 || len(body["members"].([]any)) != len(rbac.RoleIDs) {
		t.Fatalf("after remove+revoke: %v", body)
	}
	// A second admin: the first may now step down, the second removes it.
	second := who[rbac.Developer]
	if code, body := call(t, e, tid, http.MethodPut, "/v1/members/"+second+"/role", admin, map[string]string{"role": rbac.Admin}); code != 200 {
		t.Fatalf("second admin: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodDelete, "/v1/members/"+admin, second, nil); code != http.StatusNoContent {
		t.Fatalf("second admin removes the first: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/members", admin, nil); code != http.StatusForbidden {
		t.Fatalf("CONTROL: a removed admin still lists: %d", code)
	}
	// No mailer configured: the invite stands, mail says so.
	e2 := rbacEnv(t)
	t2, _ := e2.tenant()
	a2 := seat(t, e2, t2, rbac.Admin)
	if code, body := call(t, e2, t2, http.MethodPost, "/v1/members/invites", a2, map[string]string{"email": "x@example.com"}); code != http.StatusCreated || body["mail"] != "not_configured" {
		t.Fatalf("no mailer: %d %v", code, body)
	}
	// The last member who can manage members (no biz_owner here, specs/046)
	// cannot step down.
	if code, body := call(t, e2, t2, http.MethodPut, "/v1/members/"+a2+"/role", a2, map[string]string{"role": rbac.Developer}); code != http.StatusConflict || body["error"] != "last_admin" {
		t.Fatalf("the last admin steps down: %d %v, want 409 last_admin", code, body)
	}
}
