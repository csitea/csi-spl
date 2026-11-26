package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// hubWUIPub reads the hub's box-wui public key from GET /v1/wui/pubkey.
func hubWUIPub(t *testing.T, e *env) ed25519.PublicKey {
	t.Helper()
	resp, err := e.client.Get(e.ts.URL + "/v1/wui/pubkey")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var b struct {
		PubKey string `json:"pubkey"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&b); err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("wui pubkey: %d %v", resp.StatusCode, err)
	}
	pub, err := base64.StdEncoding.DecodeString(b.PubKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		t.Fatalf("wui pubkey %q: %v", b.PubKey, err)
	}
	return pub
}

// wuiPinRows counts id's operator audit rows that record a box-wui pin.
func wuiPinRows(t *testing.T, e *env, op, admin, id string) int {
	t.Helper()
	code, body := call(t, e, op, http.MethodGet, opPath+"/"+id, admin, nil)
	if code != http.StatusOK {
		t.Fatalf("read %s: %d %v", id, code, body)
	}
	n := 0
	rows, _ := body["audit"].([]any)
	for _, r := range rows {
		m := r.(map[string]any)
		d, _ := m["detail"].(map[string]any)
		if m["action"] == "update" && d["box_wui_pin"] == "pinned" && d["box_id"] == hub.WUIBox {
			n++
		}
	}
	return n
}

// wuiPinStatus is the box_wui_pin status of a create answer ("" = absent).
func wuiPinStatus(body map[string]any) string {
	p, _ := body["box_wui_pin"].(map[string]any)
	s, _ := p["status"].(string)
	return s
}

// Spec 158 10.6 items 1-2 (row P1, SPL-5019): the operator create pins the
// hub's own box-wui key in the new workspace, with no root signature, for a
// generated root key and for an operator-supplied public key alike (no
// private key needed); the 201 says box_wui_pin "pinned" and the trail holds
// one update row for it. RED CONTROL: on the code before P1 the create
// leaves no box-wui pin and the 201 has no box_wui_pin.
func TestOperatorWorkspaceCreateWUIPin(t *testing.T) {
	e, op, _, who, _ := operatorEnv(t, func(op, _ string) string { return op })
	admin, wui := who[rbac.Admin], hubWUIPub(t, e)
	rootPub, _, _ := ed25519.GenerateKey(nil)
	for _, c := range []struct {
		name string
		body map[string]any
	}{
		{"key generated", map[string]any{}},
		{"operator's public key", map[string]any{"root_pubkey": base64.StdEncoding.EncodeToString(rootPub)}},
	} {
		id := newTenantID("nw")
		c.body["id"] = id
		code, body := call(t, e, op, http.MethodPost, opPath, admin, c.body)
		if code != http.StatusCreated || wuiPinStatus(body) != "pinned" {
			t.Fatalf("%s: create = %d %v, want 201 with box_wui_pin pinned", c.name, code, body)
		}
		got, err := e.st.GetPin(context.Background(), id, hub.WUIBox)
		if err != nil || !got.Equal(wui) {
			t.Fatalf("%s: box-wui pin of %s = %x, %v; want the hub's key", c.name, id, got, err)
		}
		if n := wuiPinRows(t, e, op, admin, id); n != 1 {
			t.Fatalf("%s: %d box-wui pin audit rows, want 1", c.name, n)
		}
	}
}

// wuiPinTenant creates a fresh workspace outside the route and answers its id.
func wuiPinTenant(t *testing.T, e *env) string {
	t.Helper()
	id := newTenantID("nw")
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	return id
}

// Spec 158 10.6 item 1, the controls: ensureWUIPin writes only where the
// workspace has no box-wui pin row. A live pin of a foreign key and a revoked
// pin of the hub's own key stay exactly as they were ("kept"), a pin of the
// hub's key is "present"; none of them writes an audit row. A write the store
// refuses (no such workspace) is "failed", not a panic. CONTROL: a workspace
// with no row is pinned once ("pinned", one audit row), and a second call on
// it is "present" with still one row, so the "kept" answers are the guard.
func TestEnsureWUIPinKeepsRevokedAndForeign(t *testing.T) {
	e, op, _, who, _ := operatorEnv(t, func(op, _ string) string { return op })
	admin, wui, ctx := who[rbac.Admin], hubWUIPub(t, e), context.Background()
	foreign, _, _ := ed25519.GenerateKey(nil)
	now := time.Now().UTC().Truncate(time.Second)
	fid, rid, pid := wuiPinTenant(t, e), wuiPinTenant(t, e), wuiPinTenant(t, e)
	for _, p := range []struct {
		id  string
		key ed25519.PublicKey
	}{{fid, foreign}, {rid, wui}, {pid, wui}} {
		if err := e.st.PutPin(ctx, p.id, hub.WUIBox, p.key, false, now, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.st.RevokePin(ctx, rid, hub.WUIBox, now.Add(time.Second), now); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, id, want string
		pin            ed25519.PublicKey // nil = no live pin
	}{{"foreign key", fid, "kept", foreign}, {"revoked", rid, "kept", nil}, {"hub key", pid, "present", wui}} {
		if got := e.srv.EnsureWUIPin(ctx, c.id, op, admin); got != c.want {
			t.Fatalf("%s: ensureWUIPin = %q, want %q", c.name, got, c.want)
		}
		got, err := e.st.GetPin(ctx, c.id, hub.WUIBox)
		if c.pin == nil && !errors.Is(err, store.ErrNotFound) || c.pin != nil && (err != nil || !got.Equal(c.pin)) {
			t.Fatalf("%s: box-wui pin now %x, %v; want %x", c.name, got, err, c.pin)
		}
		if n := wuiPinRows(t, e, op, admin, c.id); n != 0 {
			t.Fatalf("%s: %d box-wui pin audit rows, want 0", c.name, n)
		}
	}
	if got := e.srv.EnsureWUIPin(ctx, newTenantID("no"), op, admin); got != "failed" {
		t.Fatalf("no such workspace: ensureWUIPin = %q, want failed", got)
	}
	nid := wuiPinTenant(t, e)
	for _, want := range []string{"pinned", "present"} {
		if got := e.srv.EnsureWUIPin(ctx, nid, op, admin); got != want {
			t.Fatalf("control: ensureWUIPin = %q, want %q", got, want)
		}
	}
	if n := wuiPinRows(t, e, op, admin, nid); n != 1 {
		t.Fatalf("control: %d box-wui pin audit rows, want 1", n)
	}
}

// Spec 158 10.6 item 2: a hub with no box-wui key still creates the
// workspace and answers 201, with box_wui_pin "no_key" and no pin row.
func TestOperatorWorkspaceCreateWUIPinNoKey(t *testing.T) {
	op := newTenantID("op")
	e := rbacEnv(t, func(o *hub.Options) { o.OperatorTenant, o.WUIKey, o.WUIDispatch = op, nil, false })
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	admin, id := seat(t, e, op, rbac.Admin), newTenantID("nw")
	code, body := call(t, e, op, http.MethodPost, opPath, admin, map[string]any{"id": id})
	if code != http.StatusCreated || wuiPinStatus(body) != "no_key" || body["root_private_key"] == nil {
		t.Fatalf("create = %d %v, want 201 with box_wui_pin no_key and the root key", code, body)
	}
	if _, err := e.st.GetPin(context.Background(), id, hub.WUIBox); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("box-wui pin with no hub key: %v, want ErrNotFound", err)
	}
}
