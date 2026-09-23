package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// rbacEnv: the store-backed authorizer (no rbac.Fixed), humans named by the
// SessionID seam but seated as real memberships with real roles.
func rbacEnv(t *testing.T) *env {
	return newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.WUIDispatch = true
		_, o.WUIKey, _ = ed25519.GenerateKey(nil)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
}

// seat admits a fresh human to tid with role through an operator invite.
func seat(t *testing.T, e *env, tid, role string) string {
	t.Helper()
	h := e.st.(store.Humans)
	b := make([]byte, 5)
	rand.Read(b) //nolint:errcheck
	email := hex.EncodeToString(b) + "@example.com"
	now := time.Now()
	if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: role,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	hum, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return hum
}

func call(t *testing.T, e *env, tid, method, path, as string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, e.url(tid)+path, rd)
	req.Header.Set("Content-Type", "application/json")
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

func perms(m map[string]any) map[string]bool {
	out := map[string]bool{}
	ps, _ := m["permissions"].([]any)
	for _, p := range ps {
		out[p.(string)] = true
	}
	return out
}

// 025 FR-005/FR-006: /v1/view/me per role, channel create and the WUI send
// gated by permission. CONTROLS: tester and pure_agent cannot create a
// channel; a tester's @agent send is refused as forbidden while a
// developer's same send passes the permission and fails later on routing.
func TestRBACPerRoleEntryPoints(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	who := map[string]string{}
	for _, r := range []string{rbac.BizOwner, rbac.ProductOwner, rbac.Admin, rbac.Developer, rbac.Tester, rbac.PureAgent} {
		who[r] = seat(t, e, tid, r)
	}
	for role, hum := range who {
		code, me := call(t, e, tid, http.MethodGet, "/v1/view/me", hum, nil)
		want := rbac.DefaultRoles()[role]
		if code != http.StatusOK || me["role"] != role || me["human_id"] != hum || len(perms(me)) != len(want.Perms) ||
			me["tenant_owner"] != want.TenantOwner {
			t.Fatalf("%s /v1/view/me %d %v", role, code, me)
		}
	}
	// Door off, no session: the guest sees no role and no permission list.
	if code, me := call(t, e, tid, http.MethodGet, "/v1/view/me", "", nil); code != http.StatusOK || me["role"] != nil || me["permissions"] != nil {
		t.Fatalf("guest /v1/view/me %d %v", code, me)
	}

	for role, want := range map[string]int{rbac.Developer: http.StatusCreated, rbac.Tester: http.StatusForbidden,
		rbac.PureAgent: http.StatusForbidden, rbac.ProductOwner: http.StatusCreated} {
		code, body := call(t, e, tid, http.MethodPost, "/v1/channels", who[role], map[string]string{"channel": "c-" + role[:3]})
		if code != want {
			t.Fatalf("%s POST /v1/channels = %d %v, want %d", role, code, body, want)
		}
		if want == http.StatusForbidden && (body["error"] != "forbidden" || body["permission"] != rbac.ChannelsManage) {
			t.Fatalf("%s 403 body %v", role, body)
		}
	}

	// WUI socket: a note is allowed to every role; @agent needs agents.command.
	tw := dialMember(t, e, tid, "Tess", who[rbac.Tester])
	if f := sendFrame(t, tw, "7a1c0d2e-3f4b-4c5d-8e6f-7a8b9c0d1e01", "note", "hello", ""); f["type"] != "ack" {
		t.Fatalf("tester note: %v", f)
	}
	if f := sendFrame(t, tw, "7a1c0d2e-3f4b-4c5d-8e6f-7a8b9c0d1e02", "task", "@CLE-07 run tests", ""); f["error"] != "forbidden" {
		t.Fatalf("CONTROL: tester commanded an agent: %v", f)
	}
	dw := dialMember(t, e, tid, "Dev", who[rbac.Developer])
	if f := sendFrame(t, dw, "7a1c0d2e-3f4b-4c5d-8e6f-7a8b9c0d1e03", "task", "@CLE-07 run tests", ""); f["error"] == "forbidden" || f["error"] == nil {
		t.Fatalf("developer dispatch should pass RBAC and fail on routing (no CLE-07 here): %v", f)
	}
	// Demotion bites on the OPEN socket (membership is never cached).
	if code, body := call(t, e, tid, http.MethodPut, "/v1/members/"+who[rbac.Developer]+"/role", who[rbac.BizOwner],
		map[string]string{"role": rbac.Tester}); code != http.StatusOK {
		t.Fatalf("owner demotes developer: %d %v", code, body)
	}
	if f := sendFrame(t, dw, "7a1c0d2e-3f4b-4c5d-8e6f-7a8b9c0d1e04", "task", "@CLE-07 run tests", ""); f["error"] != "forbidden" {
		t.Fatalf("demoted member still commands agents on its open socket: %v", f)
	}
	// A non-member session reads nothing.
	if code, body := call(t, e, tid, http.MethodGet, "/v1/view/topics", "HUM-999999", nil); code != http.StatusForbidden {
		t.Fatalf("non-member read: %d %v", code, body)
	}
}

// 025 FR-007, §3.4: the members API with its CONTROLS - no permission, no
// escalation, no touching a stronger role, no ownerless tenant; a removal
// bites at once.
func TestRBACMembersAPI(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	owner := seat(t, e, tid, rbac.BizOwner)
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)
	tester := seat(t, e, tid, rbac.Tester)
	po := seat(t, e, tid, rbac.ProductOwner)

	type c struct {
		name, method, path, as string
		body                   any
		want                   int
		token                  string
	}
	for _, x := range []c{
		{"developer cannot invite", http.MethodPost, "/v1/members/invites", dev, map[string]string{"email": "a@example.com"}, 403, "forbidden"},
		{"product_owner cannot invite (OQ-2)", http.MethodPost, "/v1/members/invites", po, map[string]string{"email": "a@example.com"}, 403, "forbidden"},
		{"admin invites a tester", http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "T@Example.com", "role": rbac.Tester}, 201, ""},
		{"admin invite defaults to developer", http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "d@example.com"}, 201, ""},
		{"admin cannot invite a biz_owner", http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "b@example.com", "role": rbac.BizOwner}, 403, "forbidden"},
		{"unknown role", http.MethodPost, "/v1/members/invites", owner, map[string]string{"email": "x@example.com", "role": "superuser"}, 400, "bad_role"},
		{"bad email", http.MethodPost, "/v1/members/invites", owner, map[string]string{"email": "nope"}, 400, "bad_email"},
		{"unknown field", http.MethodPost, "/v1/members/invites", owner, map[string]string{"email": "x@example.com", "admin": "1"}, 400, "bad_json"},
		{"developer cannot change roles", http.MethodPut, "/v1/members/" + tester + "/role", dev, map[string]string{"role": rbac.Developer}, 403, "forbidden"},
		{"developer cannot promote itself", http.MethodPut, "/v1/members/" + dev + "/role", dev, map[string]string{"role": rbac.Admin}, 403, "forbidden"},
		{"admin cannot demote the owner", http.MethodPut, "/v1/members/" + owner + "/role", admin, map[string]string{"role": rbac.Developer}, 403, "forbidden"},
		{"admin cannot make an owner", http.MethodPut, "/v1/members/" + dev + "/role", admin, map[string]string{"role": rbac.BizOwner}, 403, "forbidden"},
		{"admin cannot remove the owner", http.MethodDelete, "/v1/members/" + owner, admin, nil, 403, "forbidden"},
		{"stale from_role", http.MethodPut, "/v1/members/" + tester + "/role", admin, map[string]string{"role": rbac.Developer, "from_role": rbac.Admin}, 409, "role_changed"},
		{"admin promotes tester to developer", http.MethodPut, "/v1/members/" + tester + "/role", admin, map[string]string{"role": rbac.Developer, "from_role": rbac.Tester}, 200, ""},
		{"not a member", http.MethodPut, "/v1/members/HUM-999999/role", admin, map[string]string{"role": rbac.Tester}, 404, "not_found"},
		{"the last owner cannot demote itself", http.MethodPut, "/v1/members/" + owner + "/role", owner, map[string]string{"role": rbac.Developer}, 409, "last_owner"},
		{"the last owner cannot leave", http.MethodDelete, "/v1/members/" + owner, owner, nil, 409, "last_owner"},
		{"developer cannot remove", http.MethodDelete, "/v1/members/" + tester, dev, nil, 403, "forbidden"},
		{"admin removes the (now developer) tester", http.MethodDelete, "/v1/members/" + tester, admin, nil, 204, ""},
	} {
		code, body := call(t, e, tid, x.method, x.path, x.as, x.body)
		if code != x.want || (x.token != "" && body["error"] != x.token) {
			t.Fatalf("%s: %d %v, want %d %s", x.name, code, body, x.want, x.token)
		}
	}
	// The removed member reads nothing, at once.
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", tester, nil); code != http.StatusForbidden {
		t.Fatalf("removed member still reads: %d", code)
	}
	// The invite carries the role: the invitee signs in as a tester.
	h := e.st.(store.Humans)
	hum, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "t-sub", Email: "t@example.com"}, tid, store.AdmitPolicy{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if r, _ := h.MemberRole(context.Background(), hum, tid); r != rbac.Tester {
		t.Fatalf("invited role %q", r)
	}
	// A second owner frees the first (owner promotes admin), then the first may step down.
	if code, body := call(t, e, tid, http.MethodPut, "/v1/members/"+admin+"/role", owner, map[string]string{"role": rbac.BizOwner}); code != 200 {
		t.Fatalf("owner makes a second owner: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodPut, "/v1/members/"+owner+"/role", owner, map[string]string{"role": rbac.Developer}); code != 200 {
		t.Fatalf("owner steps down with a second owner: %d %v", code, body)
	}
	// Cross-tenant: an owner of another tenant manages nothing here.
	other, _ := e.tenant()
	stranger := seat(t, e, other, rbac.BizOwner)
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/members/"+dev+"/role", stranger, map[string]string{"role": rbac.Tester}); code != http.StatusForbidden {
		t.Fatalf("CONTROL: another tenant's owner changed a role here: %d", code)
	}
	// Preflight admits the verbs the WUI uses.
	req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+"/v1/members/"+dev+"/role", nil)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Access-Control-Request-Method", http.MethodPut)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Origin") != wuiOrigin {
		t.Fatalf("members preflight %d %v", resp.StatusCode, resp.Header)
	}
}
