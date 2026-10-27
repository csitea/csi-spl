package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/keydesk"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 159 T5 with spec 127 H2 (rdb 0234): the lease route's checks, the
// box's exhausted report, the manager's retry and the fall-back switch,
// driven through the desk's own client (hubclient.VendorKeyHub), so the
// tokens the desk passes to a seat are the ones asserted here. The key is
// the fake sk-test-0000.

// keyBox is a box of tid whose pin declared mode ("" = none), as a join
// token redeem records it.
func keyBox(t *testing.T, e *env, tid, id, mode string) *box {
	t.Helper()
	b := e.box(tid, id)
	raw, _ := base64.StdEncoding.DecodeString(b.pub)
	jt := e.st.(store.JoinTokens)
	h := make([]byte, 32)
	rand.Read(h) //nolint:errcheck
	now := time.Now()
	tok := store.JoinToken{Hash: hex.EncodeToString(h), TenantID: tid, CreatedBy: "HUM-1", CreatedAt: now, ExpiresAt: now.Add(time.Hour)}
	if err := jt.CreateJoinToken(context.Background(), tok); err != nil {
		t.Fatal(err)
	}
	if _, err := jt.RedeemJoinToken(context.Background(), tid, tok.Hash, id, ed25519.PublicKey(raw), mode, now); err != nil {
		t.Fatal(err)
	}
	return b
}

// refusal is the desk's token for err ("" = no error).
func refusal(err error) string {
	var re *keydesk.Refused
	if errors.As(err, &re) {
		return re.Token
	}
	if err != nil {
		return "error: " + err.Error()
	}
	return ""
}

// TestVendorKeyLeaseRedControl is the T5 red control, hub half: a box
// reports the vendor's refusal (as keyexec does on a fake 402) -> the next
// lease of that kind is 409 key_exhausted, on every box of the workspace;
// a retry clears it. Before the report the same lease passes every check
// and stops at the seal (increment 3).
func TestVendorKeyLeaseRedControl(t *testing.T) {
	e, _ := vkEnv(t)
	ctx := context.Background()
	tid, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	// An admin biz invited: confirmed, so it still writes once a key is set
	// (an operator-made manager is not: 127 Q-4 A, T1).
	admin, _ := seatBy(t, e, tid, rbac.Admin, biz)
	a := keyBox(t, e, tid, "box-a", store.BoxModeDedicated)
	b := keyBox(t, e, tid, "box-b", store.BoxModeDedicated)
	ha, hb := hubclient.VendorKeyHub{C: a.c}, hubclient.VendorKeyHub{C: b.c}
	lp := e.st.(store.VendorKeyLeases)

	if _, err := ha.Lease(ctx, "claude"); refusal(err) != "box_not_approved" {
		t.Fatalf("unapproved box: %v, want box_not_approved", err)
	}
	for _, id := range []string{"box-a", "box-b"} {
		if err := lp.ApproveVendorKeyBox(ctx, tid, id, biz, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := ha.Lease(ctx, "claude"); refusal(err) != "no_key" {
		t.Fatalf("no key: %v, want no_key", err)
	}
	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusNoContent {
		t.Fatalf("PUT = %d %v", code, body)
	}
	if _, err := ha.Lease(ctx, "claude"); refusal(err) != "box_key_not_enrolled" {
		t.Fatalf("lease before the refusal: %v, want box_key_not_enrolled (every check passed)", err)
	}
	if err := ha.Exhausted(ctx, "claude"); err != nil {
		t.Fatalf("exhausted report: %v", err)
	}
	for name, h := range map[string]hubclient.VendorKeyHub{"box-a": ha, "box-b": hb} {
		if _, err := h.Lease(ctx, "claude"); refusal(err) != "key_exhausted" {
			t.Fatalf("%s lease after the refusal: %v, want key_exhausted", name, err)
		}
	}
	if err := hb.Exhausted(ctx, "claude"); err != nil {
		t.Fatalf("second report: %v", err)
	}
	code, body := call(t, e, tid, http.MethodGet, "/v1/vendor-keys", admin, nil)
	if row := keyRow(t, body, "claude"); code != http.StatusOK || row["exhausted"] != true || row["exhausted_at"] == nil {
		t.Fatalf("GET = %d %v, want claude exhausted", code, body)
	}
	if body["metered_fallback"] != false {
		t.Fatalf("metered_fallback = %v, want false by default", body["metered_fallback"])
	}
	if code, body := call(t, e, tid, http.MethodPost, "/v1/vendor-keys/claude/retry", admin, nil); code != http.StatusNoContent {
		t.Fatalf("retry = %d %v", code, body)
	}
	if _, err := ha.Lease(ctx, "claude"); refusal(err) != "box_key_not_enrolled" {
		t.Fatalf("lease after retry: %v, want box_key_not_enrolled", err)
	}
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/vendor-keys/qwen/retry", admin, nil); code != http.StatusNotFound {
		t.Fatalf("retry of an unset kind = %d, want 404", code)
	}
}

// TestVendorKeyLeaseRefusals: a shared or undeclared pin, an unavailable
// kind, a member's token, and another workspace's box never pass.
func TestVendorKeyLeaseRefusals(t *testing.T) {
	e, _ := vkEnv(t)
	ctx := context.Background()
	tid, _ := e.tenant()
	other, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusNoContent {
		t.Fatalf("PUT = %d %v", code, body)
	}
	lp := e.st.(store.VendorKeyLeases)
	for _, c := range []struct{ id, mode string }{{"box-s", store.BoxModeShared}, {"box-n", ""}} {
		b := keyBox(t, e, tid, c.id, c.mode)
		if err := lp.ApproveVendorKeyBox(ctx, tid, c.id, biz, time.Now()); err != nil {
			t.Fatal(err)
		}
		h := hubclient.VendorKeyHub{C: b.c}
		if _, err := h.Lease(ctx, "claude"); refusal(err) != "box_not_dedicated" {
			t.Errorf("%s lease: %v, want box_not_dedicated", c.id, err)
		}
		if err := h.Exhausted(ctx, "claude"); refusal(err) != "box_not_dedicated" {
			t.Errorf("%s exhausted: %v, want box_not_dedicated", c.id, err)
		}
	}
	d := keyBox(t, e, tid, "box-d", store.BoxModeDedicated)
	if err := lp.ApproveVendorKeyBox(ctx, tid, "box-d", biz, time.Now()); err != nil {
		t.Fatal(err)
	}
	hd := hubclient.VendorKeyHub{C: d.c}
	if _, err := hd.Lease(ctx, "grok"); refusal(err) != "kind_not_available" {
		t.Errorf("grok lease: %v, want kind_not_available", err)
	}
	if _, err := hd.Lease(ctx, "openai"); refusal(err) != "bad_kind" {
		t.Errorf("unknown kind: %v, want bad_kind (never a 404: the desk reads it as no route)", err)
	}
	if err := hd.Exhausted(ctx, "qwen"); refusal(err) != "no_key" {
		t.Errorf("exhausted of an unset kind: %v, want no_key", err)
	}
	// Another workspace's dedicated, approved box reads its OWN workspace's
	// row: none (127 L1); the key of tid stays usable.
	x := keyBox(t, e, other, "box-x", store.BoxModeDedicated)
	if err := lp.ApproveVendorKeyBox(ctx, other, "box-x", "HUM-9", time.Now()); err != nil {
		t.Fatal(err)
	}
	hx := hubclient.VendorKeyHub{C: x.c}
	if _, err := hx.Lease(ctx, "claude"); refusal(err) != "no_key" {
		t.Errorf("other workspace's box: %v, want no_key", err)
	}
	if err := hx.Exhausted(ctx, "claude"); refusal(err) != "no_key" {
		t.Errorf("other workspace's report: %v, want no_key", err)
	}
	if _, err := hd.Lease(ctx, "claude"); refusal(err) != "box_key_not_enrolled" {
		t.Errorf("tid's key after the other's report: %v, want box_key_not_enrolled", err)
	}
	// A member's browser token is never a box (the lease route is box-only).
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/vendor-keys/claude/lease", biz, nil); code == http.StatusOK || code == http.StatusNotFound {
		t.Errorf("member POST lease = %d, want a refusal that is not a 404", code)
	}
}

// TestVendorKeyMeteredFallbackSwitch: off by default, a manager turns it on
// and off (159 9, owner Q-2 B); a developer cannot.
func TestVendorKeyMeteredFallbackSwitch(t *testing.T) {
	e, _ := vkEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)
	read := func() any {
		t.Helper()
		_, body := call(t, e, tid, http.MethodGet, "/v1/vendor-keys", admin, nil)
		return body["metered_fallback"]
	}
	if v := read(); v != false {
		t.Fatalf("default = %v, want false", v)
	}
	for _, on := range []bool{true, false} {
		if code, body := call(t, e, tid, http.MethodPut, "/v1/vendor-keys/settings", admin, map[string]any{"metered_fallback": on}); code != http.StatusNoContent {
			t.Fatalf("PUT %v = %d %v", on, code, body)
		}
		if v := read(); v != on {
			t.Fatalf("after PUT %v: %v", on, v)
		}
	}
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/vendor-keys/settings", dev, map[string]any{"metered_fallback": true}); code != http.StatusForbidden {
		t.Fatalf("developer PUT = %d, want 403", code)
	}
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/vendor-keys/settings", admin, map[string]any{}); code != http.StatusBadRequest {
		t.Fatalf("empty body = %d, want 400", code)
	}
}
