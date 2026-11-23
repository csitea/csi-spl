package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 181 row B7 (SPL-6329): the operator-only join-token mint, bound to
// <tenant> and <vm>, audited. Synthetic ids only.

// opJoinEnv is a join hub (the cnf TTL) whose operator workspace is op, and
// a private workspace priv with its spec 108 switch ON; both have one member
// per role.
func opJoinEnv(t *testing.T) (e *env, op, priv string, who, whoPriv map[string]string) {
	t.Helper()
	op, priv = newTenantID("op"), newTenantID("pw")
	e = joinEnv(t, func(o *hub.Options) { o.OperatorTenant = op })
	for _, id := range []string{op, priv} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	setBoxJoin(t, e, priv, true)
	who, whoPriv = map[string]string{}, map[string]string{}
	for _, r := range rbac.RoleIDs {
		who[r] = seat(t, e, op, r)
		whoPriv[r] = seat(t, e, priv, r)
	}
	return e, op, priv, who, whoPriv
}

func opJoinPath(tenant string) string { return opPath + "/" + tenant + "/join-tokens" }

// opMint mints as the operator admin and answers the plain token.
func opMint(t *testing.T, e *env, op, admin, tenant, box string) string {
	t.Helper()
	code, out := call(t, e, op, http.MethodPost, opJoinPath(tenant), admin, map[string]any{"box_id": box, "label": "private vm"})
	tok, _ := out["token"].(string)
	if code != http.StatusCreated || !strings.HasPrefix(tok, "spj1."+tenant+".") || out["box_id"] != box {
		t.Fatalf("operator mint %s/%s: %d %v", tenant, box, code, out)
	}
	return tok
}

// RED CONTROL of row B7: a token the operator minted for <vm> is redeemed by
// another box -> refused (409 join_token_box_mismatch), and the token stays
// unused. CONTROL: <vm> itself then redeems the same token -> 200, pinned in
// <tenant> as a dedicated box. n = 1 mint, 2 redeems.
func TestOperatorJoinMintBoundToVM(t *testing.T) {
	e, op, priv, who, _ := opJoinEnv(t)
	vm := "spl-vm-" + priv
	tok := opMint(t, e, op, who[rbac.Admin], priv, vm)
	code, eb := redeem(t, e, nil, tok, "spl-vm-other", newKey(t), time.Now())
	if code != http.StatusConflict || eb.Error != "join_token_box_mismatch" {
		t.Fatalf("RED: a token for %s redeemed by another box = %d %+v, want 409 join_token_box_mismatch", vm, code, eb)
	}
	if _, err := e.st.GetPin(context.Background(), priv, "spl-vm-other"); err == nil {
		t.Fatal("the refused redeem pinned the other box")
	}
	key := newKey(t)
	if code, eb := redeem(t, e, nil, tok, vm, key, time.Now()); code != http.StatusOK {
		t.Fatalf("CONTROL: %s redeems its own token = %d %+v, want 200", vm, code, eb)
	}
	p, err := e.st.GetPin(context.Background(), priv, vm)
	if err != nil || !p.Equal(key.Public().(ed25519.PublicKey)) {
		t.Fatalf("CONTROL: %s is not pinned to its key in %s: %v", vm, priv, err)
	}
	if _, err := e.st.GetPin(context.Background(), op, vm); err == nil {
		t.Fatalf("the token seated %s in the operator workspace %s, not only in %s", vm, op, priv)
	}
}

// Operator only: every role of the private workspace (its admin included),
// every non-admin role of the operator workspace and the anonymous caller get
// 403 operator.workspaces, and no token is stored. CONTROL: the operator
// admin's mint is 201 and lists in the workspace's own token list.
func TestOperatorJoinMintOperatorOnly(t *testing.T) {
	e, op, priv, who, whoPriv := opJoinEnv(t)
	type caller struct{ name, tenant, hum string }
	var denied []caller
	for _, r := range rbac.RoleIDs {
		if r != rbac.Admin {
			denied = append(denied, caller{"operator " + r, op, who[r]})
		}
		denied = append(denied, caller{"private-workspace " + r, priv, whoPriv[r]})
	}
	denied = append(denied, caller{"anonymous", op, ""})
	body := map[string]any{"box_id": "spl-vm-x"}
	for _, c := range denied {
		code, out := call(t, e, c.tenant, http.MethodPost, opJoinPath(priv), c.hum, body)
		if code != http.StatusForbidden || out["permission"] != "operator.workspaces" {
			t.Errorf("%s: %d %v, want 403 operator.workspaces", c.name, code, out)
		}
	}
	js := e.st.(store.JoinTokens)
	if toks, _ := js.ListJoinTokens(context.Background(), priv, time.Now()); len(toks) != 0 {
		t.Fatalf("a denied caller stored %d token(s)", len(toks))
	}
	opMint(t, e, op, who[rbac.Admin], priv, "spl-vm-x")
	if toks, _ := js.ListJoinTokens(context.Background(), priv, time.Now()); len(toks) != 1 || toks[0].BoxID != "spl-vm-x" {
		t.Fatalf("CONTROL: the operator mint lists %+v, want one token bound to spl-vm-x", toks)
	}
}

// Audited: one operator_audit row in <tenant>, action mint_join_token, by the
// operator admin of op, naming the token id and <vm>, never the token. n = 1.
func TestOperatorJoinMintAudited(t *testing.T) {
	e, op, priv, who, _ := opJoinEnv(t)
	tok := opMint(t, e, op, who[rbac.Admin], priv, "spl-vm-audit")
	trail, err := e.st.(store.OperatorWorkspaces).OperatorAuditOf(context.Background(), priv, 10)
	if err != nil {
		t.Fatal(err)
	}
	var hits []store.OperatorAudit
	for _, a := range trail {
		if a.Action == store.AuditMintJoinToken {
			hits = append(hits, a)
		}
	}
	if len(hits) != 1 {
		t.Fatalf("audit rows %s = %d (%+v), want 1", store.AuditMintJoinToken, len(hits), trail)
	}
	a := hits[0]
	id := tokenHash(tok)[:store.JoinTokenIDLen]
	if a.ActorTenant != op || a.ActorHum != who[rbac.Admin] || a.Detail["join_token"] != id || a.Detail["box_id"] != "spl-vm-audit" {
		t.Fatalf("audit row %+v, want actor %s/%s, join_token %s, box_id spl-vm-audit", a, op, who[rbac.Admin], id)
	}
	for k, v := range a.Detail {
		if s, _ := v.(string); strings.Contains(s, tok[strings.LastIndex(tok, ".")+1:]) || k == "token" || k == "label" {
			t.Fatalf("audit detail %q carries the token or the label: %v", k, a.Detail)
		}
	}
}

// The refusals, each with its control: no box_id (400 box_id_required), the
// workspace's switch off (403 box_join_disabled), no such workspace (404),
// and <vm> already seated in another workspace (409 vm_bound_elsewhere).
func TestOperatorJoinMintRefusals(t *testing.T) {
	e, op, priv, who, _ := opJoinEnv(t)
	admin := who[rbac.Admin]
	if code, out := call(t, e, op, http.MethodPost, opJoinPath(priv), admin, map[string]any{"label": "x"}); code != http.StatusBadRequest || out["error"] != "box_id_required" {
		t.Errorf("no box_id: %d %v, want 400 box_id_required", code, out)
	}
	if code, out := call(t, e, op, http.MethodPost, opJoinPath(newTenantID("no")), admin, map[string]any{"box_id": "spl-vm-n"}); code != http.StatusNotFound {
		t.Errorf("no such workspace: %d %v, want 404", code, out)
	}
	setBoxJoin(t, e, priv, false)
	if code, out := call(t, e, op, http.MethodPost, opJoinPath(priv), admin, map[string]any{"box_id": "spl-vm-off"}); code != http.StatusForbidden || out["error"] != "box_join_disabled" {
		t.Errorf("switch off: %d %v, want 403 box_join_disabled", code, out)
	}
	setBoxJoin(t, e, priv, true)
	// <vm> seated in a second private workspace, then minted for priv.
	priv2 := newTenantID("pw")
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: priv2, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	setBoxJoin(t, e, priv2, true)
	vm := "spl-vm-" + priv2
	tok := opMint(t, e, op, admin, priv2, vm)
	if code, out := call(t, e, op, http.MethodPost, opJoinPath(priv), admin, map[string]any{"box_id": vm}); code != http.StatusConflict || out["error"] != "vm_bound_elsewhere" {
		t.Errorf("open token for %s in %s, mint for %s: %d %v, want 409 vm_bound_elsewhere", vm, priv2, priv, code, out)
	}
	if code, eb := redeem(t, e, nil, tok, vm, newKey(t), time.Now()); code != http.StatusOK {
		t.Fatalf("redeem in %s: %d %+v", priv2, code, eb)
	}
	if code, out := call(t, e, op, http.MethodPost, opJoinPath(priv), admin, map[string]any{"box_id": vm}); code != http.StatusConflict || out["error"] != "vm_bound_elsewhere" {
		t.Errorf("%s seated in %s, mint for %s: %d %v, want 409 vm_bound_elsewhere", vm, priv2, priv, code, out)
	}
	// CONTROL: the same admin mints another box id for priv.
	opMint(t, e, op, admin, priv, "spl-vm-free")
}
