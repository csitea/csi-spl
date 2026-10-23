package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// lockRig is one pinned box, its K_box, a fresh K_lock, an owner and
// another admin (spec 025 box-owner-lock.md, row B2).
type lockRig struct {
	e            *env
	tid          string
	b            *box
	kbox, klock  ed25519.PrivateKey
	owner, admin string
}

func newLockRig(t *testing.T) *lockRig {
	t.Helper()
	e := rbacEnv(t)
	tid, _ := e.tenant()
	b := e.box(tid, "box-own", "CLE-01")
	e.pin(tid, b)
	kbox, err := sign.LoadPrivate(b.cfg.KeysDir, b.id)
	if err != nil {
		t.Fatal(err)
	}
	_, klock, _ := ed25519.GenerateKey(nil)
	// The owner is a developer: the lock reads no role, only its owners.
	return &lockRig{e: e, tid: tid, b: b, kbox: kbox, klock: klock,
		owner: seat(t, e, tid, rbac.Developer), admin: seat(t, e, tid, rbac.Admin)}
}

func lb64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// body is the lock row at version v, signed body by klock.
func (r *lockRig) body(v int64, peers ...string) store.BoxLock {
	l := store.BoxLock{TenantID: r.tid, BoxID: r.b.id, LockPubKey: lb64(r.klock.Public().(ed25519.PublicKey)),
		BoxPubKey: lb64(r.kbox.Public().(ed25519.PublicKey)), Owners: []string{r.owner}, PeerBoxes: peers,
		HidePosts: true, Version: v}
	l.SignedBody = store.BoxLockBody(l)
	l.Signature = lb64(ed25519.Sign(r.klock, []byte(l.SignedBody)))
	return l
}

func (r *lockRig) createReq(l store.BoxLock, boxKey ed25519.PrivateKey) map[string]any {
	return map[string]any{"signed_body": l.SignedBody, "signature": l.Signature,
		"box_signature": lb64(ed25519.Sign(boxKey, []byte(l.SignedBody)))}
}

func (r *lockRig) path() string { return "/v1/boxes/" + r.b.id + "/lock" }

func (r *lockRig) call(t *testing.T, method, as string, body any) (int, map[string]any) {
	t.Helper()
	return call(t, r.e, r.tid, method, r.path(), as, body)
}

// nonce is a fresh hub nonce, read by the owner.
func (r *lockRig) nonce(t *testing.T) string {
	t.Helper()
	code, v := r.call(t, http.MethodGet, r.owner, nil)
	n, _ := v["nonce"].(string)
	if code != http.StatusOK || n == "" {
		t.Fatalf("nonce: %d %v", code, v)
	}
	return n
}

func (r *lockRig) changeReq(l store.BoxLock, nonce string, key ed25519.PrivateKey) map[string]any {
	st := hub.BoxLockChangeStatement(r.tid, r.b.id, nonce, l.SignedBody)
	return map[string]any{"signed_body": l.SignedBody, "signature": l.Signature, "nonce": nonce,
		"nonce_signature": lb64(ed25519.Sign(key, []byte(st)))}
}

func (r *lockRig) liftReq(version int64, nonce string, key ed25519.PrivateKey) map[string]any {
	st := hub.BoxLockLiftStatement(r.tid, r.b.id, version, nonce)
	return map[string]any{"nonce": nonce, "signature": lb64(ed25519.Sign(key, []byte(st)))}
}

func (r *lockRig) audits(t *testing.T) map[string]int {
	t.Helper()
	rows, err := r.e.st.(store.BoxLockStore).BoxLockAudits(context.Background(), r.tid, r.b.id, 100)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]int{}
	for _, a := range rows {
		out[a.Path+"/"+a.Verdict] += a.Count
	}
	return out
}

// Section 6.2: create needs an owner's session, K_box over the body and
// K_lock's signature; change and lift need an owner's session and K_lock
// over a fresh hub nonce; GET answers owners only. Every refusal is audited.
func TestBoxLockRoutes(t *testing.T) {
	r := newLockRig(t)
	_, other, _ := ed25519.GenerateKey(nil)
	v1 := r.body(1)

	// Create: another admin confirming is refused; a body the box did not
	// sign is refused; the owner's confirm locks the box; a second is 409.
	if code, v := r.call(t, http.MethodPost, r.admin, r.createReq(v1, r.kbox)); code != http.StatusForbidden || v["error"] != "not_owner" {
		t.Fatalf("create as another admin: %d %v", code, v)
	}
	if code, v := r.call(t, http.MethodPost, r.owner, r.createReq(v1, other)); code != http.StatusForbidden || v["error"] != "bad_box_sig" {
		t.Fatalf("create, box_signature by another key: %d %v", code, v)
	}
	forged := v1
	forged.Signature = lb64(ed25519.Sign(other, []byte(v1.SignedBody)))
	if code, v := r.call(t, http.MethodPost, r.owner, r.createReq(forged, r.kbox)); code != http.StatusForbidden || v["error"] != "bad_sig" {
		t.Fatalf("create, signature by another key: %d %v", code, v)
	}
	if code, v := r.call(t, http.MethodPost, r.owner, r.createReq(v1, r.kbox)); code != http.StatusCreated || v["version"] != 1.0 {
		t.Fatalf("create as the owner: %d %v", code, v)
	}
	if code, v := r.call(t, http.MethodPost, r.owner, r.createReq(v1, r.kbox)); code != http.StatusConflict {
		t.Fatalf("second create: %d %v", code, v)
	}

	// GET: 404 to anyone but an owner, whatever their role.
	if code, _ := r.call(t, http.MethodGet, r.admin, nil); code != http.StatusNotFound {
		t.Fatalf("GET as another admin: %d", code)
	}
	nonce := r.nonce(t)

	// Change. RED CONTROL of the row: a PUT signed by another key is 403,
	// both when the nonce statement is (the stored K_lock does not verify it)
	// and when the body names another K_lock (the store refuses the re-key).
	v2 := r.body(2, "box-peer")
	if code, v := r.call(t, http.MethodPut, r.owner, r.changeReq(v2, nonce, other)); code != http.StatusForbidden || v["error"] != "bad_sig" {
		t.Fatalf("PUT, statement by another key: %d %v", code, v)
	}
	rekey := v2
	rekey.LockPubKey = lb64(other.Public().(ed25519.PublicKey))
	rekey.SignedBody = store.BoxLockBody(rekey)
	rekey.Signature = lb64(ed25519.Sign(other, []byte(rekey.SignedBody)))
	if code, v := r.call(t, http.MethodPut, r.owner, r.changeReq(rekey, nonce, r.klock)); code != http.StatusForbidden || v["error"] != "bad_sig" {
		t.Fatalf("PUT, body under another K_lock: %d %v", code, v)
	}
	if code, v := r.call(t, http.MethodPut, r.admin, r.changeReq(v2, nonce, r.klock)); code != http.StatusForbidden || v["error"] != "box_locked" {
		t.Fatalf("PUT as another admin with good signatures: %d %v", code, v)
	}
	if code, v := r.call(t, http.MethodPut, r.owner, r.changeReq(v2, "1."+lb64([]byte("x")), r.klock)); code != http.StatusBadRequest || v["error"] != "stale_nonce" {
		t.Fatalf("PUT with a nonce the hub did not issue: %d %v", code, v)
	}
	if code, v := r.call(t, http.MethodPut, r.owner, r.changeReq(v2, nonce, r.klock)); code != http.StatusOK || v["version"] != 2.0 {
		t.Fatalf("PUT as the owner: %d %v", code, v)
	}
	if code, v := r.call(t, http.MethodPut, r.owner, r.changeReq(v2, nonce, r.klock)); code != http.StatusConflict || v["error"] != "stale_version" {
		t.Fatalf("PUT replayed: %d %v", code, v)
	}

	// Rebind (4.5): a malformed box_pubkey changes nothing; a new one is
	// pinned in the same call.
	resign := func(l store.BoxLock) store.BoxLock {
		l.SignedBody = store.BoxLockBody(l)
		l.Signature = lb64(ed25519.Sign(r.klock, []byte(l.SignedBody)))
		return l
	}
	bad := r.body(3, "box-peer")
	bad.BoxPubKey = "AAAA"
	if code, v := r.call(t, http.MethodPut, r.owner, r.changeReq(resign(bad), nonce, r.klock)); code != http.StatusBadRequest {
		t.Fatalf("PUT with a malformed box_pubkey: %d %v", code, v)
	}
	if l, _ := r.e.st.(store.BoxLockStore).BoxLock(context.Background(), r.tid, r.b.id); l == nil || l.Version != 2 {
		t.Fatalf("a refused rebind changed the lock: %+v", l)
	}
	newBox, _, _ := ed25519.GenerateKey(nil)
	v3 := r.body(3, "box-peer")
	v3.BoxPubKey = lb64(newBox)
	if code, v := r.call(t, http.MethodPut, r.owner, r.changeReq(resign(v3), nonce, r.klock)); code != http.StatusOK || v["box_pubkey"] != lb64(newBox) {
		t.Fatalf("rebind: %d %v", code, v)
	}
	if pin, err := r.e.st.GetPin(context.Background(), r.tid, r.b.id); err != nil || lb64(pin) != lb64(newBox) {
		t.Fatalf("rebind did not pin the new box key: %v %v", err, pin)
	}

	// Lift: another admin, or a statement at another version or by another
	// key, is refused; the owner's lifts it and the box reads unlocked.
	nonce = r.nonce(t)
	if code, _ := r.call(t, http.MethodDelete, r.admin, r.liftReq(3, nonce, r.klock)); code != http.StatusForbidden {
		t.Fatalf("DELETE as another admin: %d", code)
	}
	for _, bad := range []map[string]any{r.liftReq(2, nonce, r.klock), r.liftReq(3, nonce, other)} {
		if code, v := r.call(t, http.MethodDelete, r.owner, bad); code != http.StatusForbidden || v["error"] != "bad_sig" {
			t.Fatalf("DELETE with a bad statement: %d %v", code, v)
		}
	}
	if code, _ := r.call(t, http.MethodDelete, r.owner, r.liftReq(3, nonce, r.klock)); code != http.StatusNoContent {
		t.Fatalf("DELETE as the owner: %d", code)
	}
	if code, _ := r.call(t, http.MethodGet, r.owner, nil); code != http.StatusNotFound {
		t.Fatalf("GET after the lift: %d", code)
	}
	// One row per refusal path, and the store's rows of the three writes.
	got := r.audits(t)
	for _, k := range []string{"lock_create/refused", "lock_get/refused", "lock_change/refused", "lock_lift/refused",
		"create/created", "change/changed", "lift/lifted"} {
		if got[k] == 0 {
			t.Errorf("no %s audit row: %v", k, got)
		}
	}
}

// Section 6.3: every refusal of a write bumps exactly one refused row on
// its path, the store's refusals (bad_sig, box_locked, stale_version) and the
// route's own (bad_box_sig, stale_nonce) included.
func TestBoxLockRefusalsAudited(t *testing.T) {
	r := newLockRig(t)
	_, other, _ := ed25519.GenerateKey(nil)
	v1 := r.body(1)
	if code, v := r.call(t, http.MethodPost, r.owner, r.createReq(v1, r.kbox)); code != http.StatusCreated {
		t.Fatalf("create as the owner: %d %v", code, v)
	}
	nonce := r.nonce(t)
	v2 := r.body(2, "box-peer")
	if code, v := r.call(t, http.MethodPut, r.owner, r.changeReq(v2, nonce, r.klock)); code != http.StatusOK {
		t.Fatalf("PUT as the owner: %d %v", code, v)
	}
	// A non-owner who names itself in owners passes the owner check of the
	// body it sent; the box did not sign that body.
	self := r.body(1)
	self.Owners = []string{r.admin}
	self.SignedBody = store.BoxLockBody(self)
	self.Signature = lb64(ed25519.Sign(r.klock, []byte(self.SignedBody)))
	forged := v1
	forged.Signature = lb64(ed25519.Sign(other, []byte(v1.SignedBody)))
	rekey := r.body(3)
	rekey.LockPubKey = lb64(other.Public().(ed25519.PublicKey))
	rekey.SignedBody = store.BoxLockBody(rekey)
	rekey.Signature = lb64(ed25519.Sign(other, []byte(rekey.SignedBody)))
	for _, c := range []struct {
		name, method, as, path, code string
		body                         map[string]any
	}{
		{"POST bad_box_sig on a locked box", http.MethodPost, r.admin, "lock_create", "bad_box_sig", r.createReq(self, other)},
		{"POST bad_sig", http.MethodPost, r.owner, "lock_create", "bad_sig", r.createReq(forged, r.kbox)},
		{"POST box_locked", http.MethodPost, r.owner, "lock_create", "box_locked", r.createReq(v1, r.kbox)},
		{"PUT bad_sig statement", http.MethodPut, r.owner, "lock_change", "bad_sig", r.changeReq(r.body(3), nonce, other)},
		{"PUT bad_sig body", http.MethodPut, r.owner, "lock_change", "bad_sig", r.changeReq(rekey, nonce, r.klock)},
		{"PUT stale_version", http.MethodPut, r.owner, "lock_change", "stale_version", r.changeReq(v2, nonce, r.klock)},
		{"PUT stale_nonce", http.MethodPut, r.owner, "lock_change", "stale_nonce", r.changeReq(r.body(3), "1."+lb64([]byte("x")), r.klock)},
		{"DELETE stale_nonce", http.MethodDelete, r.owner, "lock_lift", "stale_nonce", r.liftReq(2, "1."+lb64([]byte("x")), r.klock)},
	} {
		key := c.path + "/refused"
		before := r.audits(t)[key]
		if code, v := r.call(t, c.method, c.as, c.body); v["error"] != c.code {
			t.Fatalf("%s: %d %v", c.name, code, v)
		}
		if got := r.audits(t)[key]; got != before+1 {
			t.Errorf("%s: %s count %d -> %d, want +1", c.name, key, before, got)
		}
	}
}

// helloAs answers a raw role hello for the rig's box, edited by edit, and
// either the welcome or the close reason.
func (r *lockRig) helloAs(t *testing.T, role string, edit func(f *wire.Frame, nonce string)) (wire.Frame, string) {
	t.Helper()
	conn, nonce := r.e.raw(r.tid)
	defer conn.CloseNow() //nolint:errcheck
	f := helloFrame(r.b, nonce, time.Now().UTC().Format(time.RFC3339), role)
	if edit != nil {
		edit(&f, nonce)
	}
	wsjson.Write(context.Background(), conn, f) //nolint:errcheck
	var wel wire.Frame
	err := wsjson.Read(context.Background(), conn, &wel)
	var ce websocket.CloseError
	if errors.As(err, &ce) {
		return wire.Frame{}, ce.Reason
	}
	if err != nil || wel.Type != wire.TWelcome {
		t.Fatalf("hello: %v %+v", err, wel)
	}
	return wel, ""
}

// proof signs the unlock proof (4.4 step 1) for f with key.
func (r *lockRig) proof(key ed25519.PrivateKey, boot string) func(f *wire.Frame, nonce string) {
	return func(f *wire.Frame, nonce string) {
		f.BootID = boot
		p := lockkey.ProofPayload(r.tid, r.b.id, nonce, boot, lb64(r.kbox.Public().(ed25519.PublicKey)), f.TS)
		f.UnlockProof = lb64(ed25519.Sign(key, p))
	}
}

// Section 4.4: a locked box's box session shows an unlock proof by K_lock
// over this socket's nonce, or the ticket an earlier proof earned on the same
// boot; anything else is refused locked_box_sealed with a sealed_hello audit
// row. RED CONTROL of the row: the hello with no proof is refused.
func TestLockedHello(t *testing.T) {
	r := newLockRig(t)
	_, other, _ := ed25519.GenerateKey(nil)

	// CONTROL: unlocked, the plain hello is welcomed.
	if _, why := r.helloAs(t, wire.RoleBox, nil); why != "" {
		t.Fatalf("unlocked box refused: %s", why)
	}
	ls := r.e.st.(store.BoxLockStore)
	if err := ls.CreateBoxLock(context.Background(), r.body(1), r.owner, time.Now()); err != nil {
		t.Fatal(err)
	}

	if _, why := r.helloAs(t, wire.RoleBox, nil); why != "locked_box_sealed" {
		t.Fatalf("locked box, no proof: %q", why)
	}
	if n := r.audits(t)["hello/sealed_hello"]; n != 1 {
		t.Fatalf("sealed_hello audit count %d, want 1: %v", n, r.audits(t))
	}
	if _, why := r.helloAs(t, wire.RoleBox, r.proof(other, "boot-1")); why != "locked_box_sealed" {
		t.Fatalf("proof by another key: %q", why)
	}
	stale := func(f *wire.Frame, nonce string) { r.proof(r.klock, "boot-1")(f, "not-"+nonce) }
	if _, why := r.helloAs(t, wire.RoleBox, stale); why != "locked_box_sealed" {
		t.Fatalf("proof over another nonce: %q", why)
	}
	if _, why := r.helloAs(t, wire.RoleBox, func(f *wire.Frame, _ string) { f.UnlockTicket = "x.y"; f.BootID = "boot-1" }); why != "locked_box_sealed" {
		t.Fatalf("forged ticket: %q", why)
	}

	wel, why := r.helloAs(t, wire.RoleBox, r.proof(r.klock, "boot-1"))
	if why != "" || wel.UnlockTicket == "" {
		t.Fatalf("good proof: %q, ticket %q", why, wel.UnlockTicket)
	}
	ticket := wel.UnlockTicket
	withTicket := func(boot string) func(f *wire.Frame, _ string) {
		return func(f *wire.Frame, _ string) { f.UnlockTicket, f.BootID = ticket, boot }
	}
	if w2, why := r.helloAs(t, wire.RoleBox, withTicket("boot-1")); why != "" || w2.UnlockTicket != "" {
		t.Fatalf("ticket, same boot: %q (new ticket %q)", why, w2.UnlockTicket)
	}
	if _, why := r.helloAs(t, wire.RoleBox, withTicket("boot-2")); why != "locked_box_sealed" {
		t.Fatalf("ticket after a reboot: %q", why)
	}

	// role=cli proves K_box only, which lives only in the unlocked holder.
	if _, why := r.helloAs(t, wire.RoleCLI, nil); why != "" {
		t.Fatalf("cli hello of a locked box: %q", why)
	}

	// A key pinned by someone else (5.1 path 8) is not the lock's box key:
	// refused even with a good proof.
	_, pinned, _ := ed25519.GenerateKey(nil)
	now := time.Now()
	if err := r.e.st.PutPin(context.Background(), r.tid, r.b.id, pinned.Public().(ed25519.PublicKey), true, now, now); err != nil {
		t.Fatal(err)
	}
	signPinned := func(f *wire.Frame, nonce string) {
		r.proof(r.klock, "boot-1")(f, nonce)
		p, _ := wire.HelloPayload(f.BoxID, nonce, f.TS)
		f.Sig = sign.Sign(pinned, p)
	}
	for _, role := range []string{wire.RoleBox, wire.RoleCLI} {
		if _, why := r.helloAs(t, role, signPinned); why != "locked_box_key" {
			t.Fatalf("%s: pinned key is not the lock's: %q", role, why)
		}
	}
}
