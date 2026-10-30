package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// rbacEnv: the store-backed authorizer (no rbac.Fixed), humans named by the
// SessionID seam but seated as real memberships with real roles.
func rbacEnv(t *testing.T, mut ...func(*hub.Options)) *env {
	return newEnv(t, append([]func(*hub.Options){func(o *hub.Options) {
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
	}}, mut...)...)
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
	if m, ok := body.(map[string]any); ok && method == http.MethodPost && path == "/v1/issues" {
		if _, has := m["discussions"]; !has { // SPL-1593: every create links one; the tenant's default
			m["discussions"] = []string{store.IssueDiscussionDefault(tid)}
		}
	}
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
	for _, r := range rbac.RoleIDs {
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
	cust := seat(t, e, tid, rbac.Developer)
	spare := seat(t, e, tid, rbac.Developer)
	spare2 := seat(t, e, tid, rbac.Developer)

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
		{"biz_owner invites (specs/046, rdb 0074)", http.MethodPost, "/v1/members/invites", owner, map[string]string{"email": "o@example.com"}, 201, ""},
		{"biz_owner removes (members.invite)", http.MethodDelete, "/v1/members/" + spare, owner, nil, 204, ""},
		{"biz_owner makes an admin (it holds every permission)", http.MethodPut, "/v1/members/" + spare2 + "/role", owner, map[string]string{"role": rbac.Admin}, 200, ""},
		{"biz_customer cannot invite", http.MethodPost, "/v1/members/invites", cust, map[string]string{"email": "c@example.com"}, 403, "forbidden"},
		{"admin invites a regular_user", http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "z@example.com", "role": rbac.RegularUser}, 201, ""},
		{"admin invites a biz_customer", http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "k@example.com", "role": rbac.BizCustomer}, 201, ""},
		{"owner makes a developer a biz_customer", http.MethodPut, "/v1/members/" + cust + "/role", owner, map[string]string{"role": rbac.BizCustomer, "from_role": rbac.Developer}, 200, ""},
		{"biz_customer cannot invite either", http.MethodPost, "/v1/members/invites", cust, map[string]string{"email": "c@example.com"}, 403, "forbidden"},
		{"admin cannot invite a biz_owner", http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "b@example.com", "role": rbac.BizOwner}, 403, "forbidden"},
		{"unknown role", http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "x@example.com", "role": "superuser"}, 400, "bad_role"},
		{"bad email", http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "nope"}, 400, "bad_email"},
		{"unknown field", http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "x@example.com", "admin": "1"}, 400, "bad_json"},
		{"developer cannot change roles", http.MethodPut, "/v1/members/" + tester + "/role", dev, map[string]string{"role": rbac.Developer}, 403, "forbidden"},
		{"developer cannot promote itself", http.MethodPut, "/v1/members/" + dev + "/role", dev, map[string]string{"role": rbac.Admin}, 403, "forbidden"},
		{"admin cannot demote the owner", http.MethodPut, "/v1/members/" + owner + "/role", admin, map[string]string{"role": rbac.Developer}, 403, "forbidden"},
		{"admin cannot make an owner", http.MethodPut, "/v1/members/" + dev + "/role", admin, map[string]string{"role": rbac.BizOwner}, 403, "forbidden"},
		{"admin cannot remove the owner", http.MethodDelete, "/v1/members/" + owner, admin, nil, 403, "forbidden"},
		{"stale from_role", http.MethodPut, "/v1/members/" + tester + "/role", admin, map[string]string{"role": rbac.Developer, "from_role": rbac.Admin}, 409, "role_changed"},
		{"admin promotes tester to developer", http.MethodPut, "/v1/members/" + tester + "/role", admin, map[string]string{"role": rbac.Developer, "from_role": rbac.Tester}, 200, ""},
		{"not a member", http.MethodPut, "/v1/members/HUM-999999/role", admin, map[string]string{"role": rbac.Tester}, 404, "not_found"},
		{"the last owner cannot demote itself", http.MethodPut, "/v1/members/" + owner + "/role", owner, map[string]string{"role": rbac.Developer}, 409, "last_owner"},
		// Nobody removes themselves; the store's last-owner
		// guard stays (store TestTenantRolesAndLastOwner).
		{"the owner cannot remove itself", http.MethodDelete, "/v1/members/" + owner, owner, nil, 409, "self"},
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
	// A second owner frees the first (owner promotes the product_owner), then the first may step down.
	if code, body := call(t, e, tid, http.MethodPut, "/v1/members/"+po+"/role", owner, map[string]string{"role": rbac.BizOwner}); code != 200 {
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

// failingCopy is a store whose receipt copy always fails (specs/119 T-R2);
// every other method is the real store's.
type failingCopyMem struct{ *store.Memory }
type failingCopyPG struct{ *store.Postgres }

var errStubCopy = fmt.Errorf("%w: stubbed", store.ErrRealmCopy)

func (failingCopyMem) CopyRealmReceipts(context.Context, string, string, string, time.Time) (int, error) {
	return 0, errStubCopy
}
func (failingCopyPG) CopyRealmReceipts(context.Context, string, string, string, time.Time) (int, error) {
	return 0, errStubCopy
}

// receiptHours gives hum one approved topic entry today in tid, with a note.
func receiptHours(t *testing.T, e *env, tid, hum string) {
	t.Helper()
	now := time.Now().UTC()
	if err := e.st.(store.Hours).PutHoursEntries(context.Background(), tid, hum, []store.HoursEntry{{
		Day: now.Format(time.DateOnly), Target: "t:secret-topic", Minutes: 75, State: store.HoursApproved,
		Note: "secret-note"}}, hum, now); err != nil {
		t.Fatal(err)
	}
}

// receiptsOf is hum's receipt rows of tid.
func receiptsOf(t *testing.T, e *env, hum, tid string) []store.RealmReceipt {
	t.Helper()
	rs, err := e.st.(store.Realm).RealmReceipts(context.Background(), hum)
	if err != nil {
		t.Fatal(err)
	}
	var out []store.RealmReceipt
	for _, r := range rs {
		if r.WorkspaceID == tid {
			out = append(out, r)
		}
	}
	return out
}

// specs/119 8.1 row 1, T-R1 (route half), T-R9, T-R10: a removal takes the
// leaver's receipt first; disabling a membership takes none, removing it
// afterwards does; a member removed without the copy (before 119 shipped)
// has none. The workspace keeps the hours.
func TestRBACRemovalTakesReceipt(t *testing.T) {
	e := rbacEnv(t)
	ctx := context.Background()
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	leaver := seat(t, e, tid, rbac.Developer)
	paused := seat(t, e, tid, rbac.Developer)
	before := seat(t, e, tid, rbac.Developer)
	for _, h := range []string{leaver, paused, before} {
		receiptHours(t, e, tid, h)
	}

	// T-R10: removed the old way (no copy): no receipt, and nothing later adds one.
	if err := e.st.(store.Humans).RemoveMember(ctx, tid, before); err != nil {
		t.Fatal(err)
	}
	if rs := receiptsOf(t, e, before, tid); len(rs) != 0 {
		t.Fatalf("T-R10: a member removed before the copy has receipts %+v", rs)
	}

	// T-R1: the removal copies first; the row has no content; the hours stay.
	if code, body := call(t, e, tid, http.MethodDelete, "/v1/members/"+leaver, admin, nil); code != http.StatusNoContent {
		t.Fatalf("remove: %d %v", code, body)
	}
	rs := receiptsOf(t, e, leaver, tid)
	if len(rs) != 1 || rs[0].Label != "topic" || rs[0].Kind != "work" || rs[0].Minutes != 75 || rs[0].Rev != 0 {
		t.Fatalf("T-R1: receipts %+v, want one topic/work row of 75 at rev 0", rs)
	}
	if s := fmt.Sprintf("%+v", rs); strings.Contains(s, "secret") {
		t.Fatalf("T-R1: content in a receipt: %s", s)
	}
	if kept, err := e.st.(store.Hours).HoursEntries(ctx, tid, leaver, "2000-01-01", "2999-12-31"); err != nil || len(kept) != 1 {
		t.Fatalf("T-R1: the workspace keeps the hours: %v %v", kept, err)
	}

	// T-R9: disabling copies nothing; removing the disabled membership does.
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+paused, admin, map[string]any{"disabled": true}); code != http.StatusNoContent {
		t.Fatalf("disable: %d %v", code, body)
	}
	if rs := receiptsOf(t, e, paused, tid); len(rs) != 0 {
		t.Fatalf("T-R9: disabling took a receipt %+v", rs)
	}
	if code, body := call(t, e, tid, http.MethodDelete, "/v1/members/"+paused, admin, nil); code != http.StatusNoContent {
		t.Fatalf("remove the disabled member: %d %v", code, body)
	}
	if rs := receiptsOf(t, e, paused, tid); len(rs) != 1 {
		t.Fatalf("T-R9: removing the disabled member took %d receipt rows, want 1", len(rs))
	}
}

// specs/119 T-R2: a failed copy answers 503 receipt_failed and the
// membership stays. CONTROL: the same removal on the real store passes.
func TestRBACRemovalReceiptFailedKeepsMember(t *testing.T) {
	e := rbacEnv(t, func(o *hub.Options) {
		switch st := o.Store.(type) {
		case *store.Memory:
			o.Store = failingCopyMem{st}
		case *store.Postgres:
			o.Store = failingCopyPG{st}
		}
	})
	ctx := context.Background()
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	leaver := seat(t, e, tid, rbac.Developer)
	receiptHours(t, e, tid, leaver)
	code, body := call(t, e, tid, http.MethodDelete, "/v1/members/"+leaver, admin, nil)
	if code != http.StatusServiceUnavailable || body["error"] != "receipt_failed" {
		t.Fatalf("remove with a failing copy: %d %v, want 503 receipt_failed", code, body)
	}
	if role, err := e.st.(store.Humans).MemberRole(ctx, leaver, tid); err != nil || role != rbac.Developer {
		t.Fatalf("the member did not stay: %q %v", role, err)
	}

	ok := rbacEnv(t)
	tid2, _ := ok.tenant()
	admin2 := seat(t, ok, tid2, rbac.Admin)
	leaver2 := seat(t, ok, tid2, rbac.Developer)
	if code, body := call(t, ok, tid2, http.MethodDelete, "/v1/members/"+leaver2, admin2, nil); code != http.StatusNoContent {
		t.Fatalf("CONTROL: the real store's removal: %d %v", code, body)
	}
}

// ---- spec 162 row B6: the Workspace log producers (cases C22, C23) ----------

// failingLog is a store whose Workspace log write always fails (C23); every
// other method is the real store's.
type failingLogMem struct{ *store.Memory }
type failingLogPG struct{ *store.Postgres }

var errStubLog = errors.New("workspace log: stubbed")

func (failingLogMem) AddWorkspaceEvent(context.Context, string, store.LogEvent, time.Time) (store.LogEvent, error) {
	return store.LogEvent{}, errStubLog
}
func (failingLogPG) AddWorkspaceEvent(context.Context, string, store.LogEvent, time.Time) (store.LogEvent, error) {
	return store.LogEvent{}, errStubLog
}

func failingLog(o *hub.Options) {
	switch st := o.Store.(type) {
	case *store.Memory:
		o.Store = failingLogMem{st}
	case *store.Postgres:
		o.Store = failingLogPG{st}
	}
}

// wsEvents is tid's Workspace log, newest first, read from the real store
// (e.st, never the failingLog wrapper).
func wsEvents(t *testing.T, e *env, tid string) []store.LogEvent {
	t.Helper()
	list, err := e.st.(store.LogEvents).WorkspaceEventsPage(context.Background(), tid, 0, store.LogEventsDeleteMax)
	if err != nil {
		t.Fatal(err)
	}
	return list
}

// logStep is one call of a producer and the Workspace log row it must leave:
// kind "" = none (a refused call, or failingLog).
type logStep struct {
	name, method, path, as string
	body                   any
	want                   int
	kind, ref              string
}

// runLogSteps runs each step in tid and checks the code and that the log
// grew by exactly its row (kind, actor = the caller, origin component ref) or
// not at all. A row's message never carries an address (spec 162 3.1).
func runLogSteps(t *testing.T, e *env, tid string, steps []logStep) {
	t.Helper()
	for _, x := range steps {
		before := len(wsEvents(t, e, tid))
		if code, body := call(t, e, tid, x.method, x.path, x.as, x.body); code != x.want {
			t.Fatalf("%s: %d %v, want %d", x.name, code, body, x.want)
		}
		got := wsEvents(t, e, tid)
		if x.kind == "" {
			if len(got) != before {
				t.Fatalf("%s: the log grew %d -> %d, want no row (newest %+v)", x.name, before, len(got), got[0])
			}
			continue
		}
		if len(got) != before+1 {
			t.Fatalf("%s: the log grew %d -> %d, want one row", x.name, before, len(got))
		}
		ev := got[0]
		if ev.Kind != x.kind || ev.Actor != x.as || ev.Level != store.LogLevelInfo ||
			ev.OriginKind != store.LogOriginComponent || ev.OriginRef != x.ref || ev.Message == "" || strings.Contains(ev.Message, "@") {
			t.Fatalf("%s: row %+v, want kind %s by %s, origin component %s, a message with no address", x.name, ev, x.kind, x.as, x.ref)
		}
	}
}

// C22: each member producer (invite, invite revoke, role, roles, remove)
// writes its one row after a successful call and none after a refused one
// (403 to a developer, 404 for a missing invite or member).
func TestWorkspaceEventsMemberProducers(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin, dev := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer)
	target, gone := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	const inv = "/v1/members/invites"
	P, D, U := http.MethodPost, http.MethodDelete, http.MethodPut
	invite := map[string]any{"email": "log-b6@example.com", "role": rbac.Tester, "no_mail": true}
	runLogSteps(t, e, tid, []logStep{
		{"refused invite", P, inv, dev, invite, 403, "", ""},
		{"invite", P, inv, admin, invite, 201, store.LogKindMemberInvited, "members"},
		{"refused revoke", D, inv + "?email=log-b6@example.com", dev, nil, 403, "", ""},
		{"revoke of no invite", D, inv + "?email=none-b6@example.com", admin, nil, 404, "", ""},
		{"revoke", D, inv + "?email=log-b6@example.com", admin, nil, 204, store.LogKindMemberInviteRevoked, "members"},
		{"refused role", U, "/v1/members/" + target + "/role", dev, map[string]any{"role": rbac.Tester}, 403, "", ""},
		{"role of no member", U, "/v1/members/HUM-999999/role", admin, map[string]any{"role": rbac.Tester}, 404, "", ""},
		{"role", U, "/v1/members/" + target + "/role", admin, map[string]any{"role": rbac.Tester}, 200, store.LogKindMemberRoleChanged, "members"},
		{"refused roles", U, "/v1/members/" + target + "/roles", dev, map[string]any{"roles": []string{rbac.Developer}}, 403, "", ""},
		{"roles", U, "/v1/members/" + target + "/roles", admin, map[string]any{"roles": []string{rbac.Developer}}, 200, store.LogKindMemberRoleChanged, "members"},
		{"refused remove", D, "/v1/members/" + gone, dev, nil, 403, "", ""},
		{"remove", D, "/v1/members/" + gone, admin, nil, 204, store.LogKindMemberRemoved, "members"},
	})
	if got := wsEvents(t, e, tid); got[0].Message != gone+" removed" || got[1].Message != target+": roles "+rbac.Developer {
		t.Fatalf("messages %q, %q", got[0].Message, got[1].Message)
	}
}

// C23: a failed log write does not fail the member action: each answers its
// usual 2xx and the log holds nothing.
func TestWorkspaceEventsMemberLogFails(t *testing.T) {
	e := rbacEnv(t, failingLog)
	tid, _ := e.tenant()
	admin, target, gone := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	invite := map[string]any{"email": "fail-b6@example.com", "no_mail": true}
	runLogSteps(t, e, tid, []logStep{
		{"invite", http.MethodPost, "/v1/members/invites", admin, invite, 201, "", ""},
		{"revoke", http.MethodDelete, "/v1/members/invites?email=fail-b6@example.com", admin, nil, 204, "", ""},
		{"role", http.MethodPut, "/v1/members/" + target + "/role", admin, map[string]any{"role": rbac.Tester}, 200, "", ""},
		{"roles", http.MethodPut, "/v1/members/" + target + "/roles", admin, map[string]any{"roles": []string{rbac.Developer}}, 200, "", ""},
		{"remove", http.MethodDelete, "/v1/members/" + gone, admin, nil, 204, "", ""},
	})
}
