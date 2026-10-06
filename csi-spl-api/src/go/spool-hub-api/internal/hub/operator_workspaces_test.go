package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

const opPath = "/v1/operator/workspaces"

// newTenantID is a fresh workspace id that does not exist yet.
func newTenantID(prefix string) string {
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	return prefix + hex.EncodeToString(b)
}

// operatorEnv is a hub whose operator workspace is op (created here) and
// one other workspace; both with one member per role.
func operatorEnv(t *testing.T, opTenant func(op, other string) string) (e *env, op, other string, who, whoOther map[string]string) {
	t.Helper()
	op, other = newTenantID("op"), newTenantID("ot")
	e = rbacEnv(t, func(o *hub.Options) { o.OperatorTenant = opTenant(op, other) })
	for _, id := range []string{op, other} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	who, whoOther = map[string]string{}, map[string]string{}
	for _, r := range rbac.RoleIDs {
		who[r] = seat(t, e, op, r)
		whoOther[r] = seat(t, e, other, r)
	}
	return e, op, other, who, whoOther
}

// spec 074 phase 1 (owner HUM-10 msg 94071e2e: "he has to be admin, not biz
// owner"): only the ADMIN of the operator workspace may call any operator
// workspace route. Every other role there, the anonymous door-off guest, and
// the admin of another workspace get 403 operator.workspaces on every route.
// CONTROL: the same admin passes, so the 403s are the role rule, not a
// broken route.
func TestOperatorWorkspacesRoleMatrix(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	routes := []struct {
		method, path string
		body         any
	}{
		{http.MethodGet, opPath, nil},
		{http.MethodPost, opPath, map[string]any{"id": newTenantID("nw")}},
		{http.MethodGet, opPath + "/" + other, nil},
		{http.MethodPatch, opPath + "/" + other, map[string]any{"display_name": "x"}},
		{http.MethodDelete, opPath + "/" + other, nil},
	}
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
		for _, x := range routes {
			code, body := call(t, e, c.tenant, x.method, x.path, c.hum, x.body)
			if code != http.StatusForbidden || body["permission"] != "operator.workspaces" {
				t.Errorf("%s: %s %s = %d %v, want 403 operator.workspaces", c.name, x.method, x.path, code, body)
			}
		}
	}
	// CONTROL: nothing a denied caller sent was applied.
	if ws, _ := e.st.(store.OperatorWorkspaces).GetWorkspace(context.Background(), other); !ws.SuspendedAt.IsZero() || ws.DisplayName != "" {
		t.Fatalf("a denied call changed %s: %+v", other, ws)
	}
	if code, body := call(t, e, op, http.MethodGet, opPath, who[rbac.Admin], nil); code != http.StatusOK || listed(body)[other] == nil {
		t.Fatalf("CONTROL: operator admin list = %d %v", code, body)
	}
}

// CONTROL for the matrix: the rule follows the CONFIGURED operator workspace.
// Name the other workspace and its admin passes while op's admin, who passed
// above, now gets 403; with no operator workspace every route is 404.
func TestOperatorWorkspacesFollowCnf(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(_, other string) string { return other })
	if code, _ := call(t, e, op, http.MethodGet, opPath, who[rbac.Admin], nil); code != http.StatusForbidden {
		t.Fatalf("admin of a non-operator workspace: %d, want 403", code)
	}
	if code, _ := call(t, e, other, http.MethodGet, opPath, whoOther[rbac.Admin], nil); code != http.StatusOK {
		t.Fatalf("admin of the configured operator workspace: %d, want 200", code)
	}
	e2, op2, _, who2, _ := operatorEnv(t, func(string, string) string { return "" })
	if code, _ := call(t, e2, op2, http.MethodGet, opPath, who2[rbac.Admin], nil); code != http.StatusNotFound {
		t.Fatalf("no operator workspace: %d, want 404", code)
	}
}

// unflagOperator clears tenants.is_operator after a test that set it: the
// hub package shares one Postgres database, where the flag would otherwise
// overrule every later test's cnf operator workspace. Memory is per env.
func unflagOperator(t *testing.T, e *env) {
	t.Helper()
	pg, ok := e.st.(*store.Postgres)
	if !ok {
		return
	}
	t.Cleanup(func() {
		if _, err := pg.Pool().Exec(context.Background(), `BEGIN; SELECT set_config('app.rls_scope', 'operator', true);
			UPDATE tenants SET is_operator = false WHERE is_operator; COMMIT`); err != nil {
			t.Error(err)
		}
	})
}

// spec 074 phase 1b (owner D1: the operator workspace is recorded "in the
// db"): hub start claims the cnf workspace into tenants.is_operator while no
// row is flagged, and the store answers it from then on.
func TestOperatorWorkspaceClaimedFromCnf(t *testing.T) {
	e, op, _, _, _ := operatorEnv(t, func(op, _ string) string { return op })
	unflagOperator(t, e)
	ctx := context.Background()
	if got, err := e.srv.ClaimOperatorWorkspace(ctx); err != nil || got != op {
		t.Fatalf("start-up claim: %q %v, want the cnf workspace %q", got, err, op)
	}
	if got, err := e.st.(store.OperatorFlag).OperatorTenant(ctx); err != nil || got != op {
		t.Fatalf("flag after the claim: %q %v, want %q", got, err, op)
	}
}

// Once a row is flagged the FLAG decides, not the cnf: flag the other
// workspace (cnf still names op) and its admin passes, op's admin gets 403,
// the list marks only it operator, and a start-up claim does not move the
// flag back to the cnf. CONTROL: before the flag, op's admin passed (cnf).
func TestOperatorWorkspacesFollowDBFlag(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	unflagOperator(t, e)
	ctx := context.Background()
	if code, _ := call(t, e, op, http.MethodGet, opPath, who[rbac.Admin], nil); code != http.StatusOK {
		t.Fatalf("control: admin of the cnf workspace, nothing flagged: %d, want 200", code)
	}
	if got, err := e.st.(store.OperatorFlag).ClaimOperatorTenant(ctx, other); err != nil || got != other {
		t.Fatalf("flag %s: %q %v", other, got, err)
	}
	if got, err := e.srv.ClaimOperatorWorkspace(ctx); err != nil || got != other {
		t.Fatalf("start-up claim: %q %v, want the flagged %q (never moved to the cnf)", got, err, other)
	}
	if code, _ := call(t, e, op, http.MethodGet, opPath, who[rbac.Admin], nil); code != http.StatusForbidden {
		t.Fatalf("admin of the cnf workspace, flag elsewhere: %d, want 403", code)
	}
	code, body := call(t, e, other, http.MethodGet, opPath, whoOther[rbac.Admin], nil)
	if code != http.StatusOK || listed(body)[other]["operator"] != true || listed(body)[op]["operator"] != false {
		t.Fatalf("admin of the flagged workspace: %d %v, want 200 with only %s operator", code, body, other)
	}
}

func listed(body map[string]any) map[string]map[string]any {
	out := map[string]map[string]any{}
	ws, _ := body["workspaces"].([]any)
	for _, w := range ws {
		m := w.(map[string]any)
		out[m["id"].(string)] = m
	}
	return out
}

// The operator admin's full life cycle of a workspace: create (a generated
// root key answered once, the first admin invited), list, read, rename +
// billing, suspend (its door answers 403 workspace_suspended), resume (the
// door opens again: the CONTROL that the 403 is the suspension), archive
// (soft: the row stays), and the audit trail of every step.
func TestOperatorWorkspacesLifecycle(t *testing.T) {
	e, op, _, who, _ := operatorEnv(t, func(op, _ string) string { return op })
	admin := who[rbac.Admin]
	id := newTenantID("nw")
	code, body := call(t, e, op, http.MethodPost, opPath, admin, map[string]any{"id": id,
		"display_name": "New One", "first_admin_email": "first-" + id + "@example.com", "no_mail": true})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, body)
	}
	priv, _ := base64.StdEncoding.DecodeString(body["root_private_key"].(string))
	tn, err := e.st.GetTenant(context.Background(), id)
	if err != nil || len(priv) != ed25519.PrivateKeySize || !tn.RootPubKey.Equal(ed25519.PrivateKey(priv).Public()) {
		t.Fatalf("root key: stored %v err %v", tn.RootPubKey, err)
	}
	if inv := body["invite"].(map[string]any); inv["status"] != "invited" || inv["role"] != rbac.Admin {
		t.Fatalf("first admin invite: %v", inv)
	}
	if ws := body["workspace"].(map[string]any); ws["display_name"] != "New One" || ws["billing_status"] != "manual" {
		t.Fatalf("created workspace: %v", ws)
	}
	if code, _ := call(t, e, op, http.MethodPost, opPath, admin, map[string]any{"id": id}); code != http.StatusConflict {
		t.Fatalf("re-create: %d, want 409", code)
	}
	if code, body := call(t, e, op, http.MethodGet, opPath, admin, nil); code != http.StatusOK || listed(body)[id] == nil || listed(body)[op]["operator"] != true {
		t.Fatalf("list: %d %v", code, body)
	}
	if code, body := call(t, e, op, http.MethodPatch, opPath+"/"+id, admin, map[string]any{"display_name": "Renamed", "billing_status": "active"}); code != http.StatusOK ||
		body["workspace"].(map[string]any)["display_name"] != "Renamed" || body["workspace"].(map[string]any)["billing_status"] != "active" {
		t.Fatalf("patch: %d %v", code, body)
	}
	suspendRoundTrip(t, e, op, admin, id)
	if code, _ := call(t, e, op, http.MethodDelete, opPath+"/"+id+"?purge=1", admin, nil); code != http.StatusBadRequest {
		t.Fatalf("purge: %d, want 400 (no hard purge)", code)
	}
	if code, body := call(t, e, op, http.MethodDelete, opPath+"/"+id, admin, nil); code != http.StatusOK ||
		body["workspace"].(map[string]any)["archived_at"] == nil || body["workspace"].(map[string]any)["suspended_at"] == nil {
		t.Fatalf("archive: %d %v", code, body)
	}
	for _, x := range []struct{ method, body string }{{http.MethodDelete, ""}, {http.MethodPatch, "s"}} {
		var b any
		if x.body != "" {
			b = map[string]any{"suspended": true}
		}
		if code, _ := call(t, e, op, x.method, opPath+"/"+op, admin, b); code != http.StatusConflict {
			t.Fatalf("%s on the operator workspace itself: %d, want 409", x.method, code)
		}
	}
	assertAudit(t, e, op, admin, id, []string{"create", "update", "suspend", "resume", "archive"})
}

func suspendRoundTrip(t *testing.T, e *env, op, admin, id string) {
	t.Helper()
	if code, _ := call(t, e, id, http.MethodGet, "/v1/view/me", "", nil); code != http.StatusOK {
		t.Fatalf("CONTROL: live workspace door: %d", code)
	}
	if code, body := call(t, e, op, http.MethodPatch, opPath+"/"+id, admin, map[string]any{"suspended": true}); code != http.StatusOK || body["workspace"].(map[string]any)["suspended_at"] == nil {
		t.Fatalf("suspend: %d %v", code, body)
	}
	if code, body := call(t, e, id, http.MethodGet, "/v1/view/me", "", nil); code != http.StatusForbidden || body["error"] != "workspace_suspended" {
		t.Fatalf("suspended door: %d %v, want 403 workspace_suspended", code, body)
	}
	if code, _ := call(t, e, op, http.MethodPatch, opPath+"/"+id, admin, map[string]any{"suspended": false}); code != http.StatusOK {
		t.Fatalf("resume: %d", code)
	}
	if code, _ := call(t, e, id, http.MethodGet, "/v1/view/me", "", nil); code != http.StatusOK {
		t.Fatalf("resumed door: %d, want 200", code)
	}
}

// assertAudit: the workspace's trail holds want in order, each by admin.
func assertAudit(t *testing.T, e *env, op, admin, id string, want []string) {
	t.Helper()
	code, body := call(t, e, op, http.MethodGet, opPath+"/"+id, admin, nil)
	if code != http.StatusOK {
		t.Fatalf("read: %d %v", code, body)
	}
	var got []string
	rows, _ := body["audit"].([]any)
	for _, r := range rows {
		m := r.(map[string]any)
		if m["actor_hum"] != admin || m["actor_tenant"] != op {
			t.Fatalf("audit row not by the operator admin: %v", m)
		}
		if a := m["action"].(string); a != "read" {
			got = append(got, a)
		}
	}
	if len(got) < len(want) {
		t.Fatalf("audit %v, want at least %v", got, want)
	}
	i := 0
	for _, a := range got {
		if i < len(want) && a == want[i] {
			i++
		}
	}
	if i != len(want) {
		t.Fatalf("audit %v does not hold %v in order", got, want)
	}
}

// r3-B03: a display name the store refuses (a newline passes the create
// check but not SetTenantConfig) still creates the workspace and answers its
// root key once, so the answer stays 201 - and says the name was NOT stored
// instead of hiding it. CONTROL: a plain name reports "stored".
func TestOperatorWorkspaceCreateReportsDisplayName(t *testing.T) {
	e, op, _, who, _ := operatorEnv(t, func(op, _ string) string { return op })
	admin := who[rbac.Admin]
	for _, c := range []struct{ name, want string }{{"Bad\nName", "not_stored"}, {"Good Name", "stored"}} {
		id := newTenantID("nw")
		code, body := call(t, e, op, http.MethodPost, opPath, admin, map[string]any{"id": id, "display_name": c.name})
		if code != http.StatusCreated || body["root_private_key"] == nil {
			t.Fatalf("create %q: %d %v", c.name, code, body)
		}
		dn, _ := body["display_name"].(map[string]any)
		if dn["status"] != c.want {
			t.Fatalf("create %q: display_name = %v, want status %q", c.name, body["display_name"], c.want)
		}
	}
}
