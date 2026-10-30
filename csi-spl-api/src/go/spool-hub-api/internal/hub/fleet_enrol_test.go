package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// fleetRig is newFleetDeskRig (an operator workspace op with opBox and
// spareBox pinned, another workspace) plus ws, a workspace with no member at
// all (so nobody holds agents.join) and box_join_enabled false, marked for
// fleet seating; opBox is a listed fleet desk box, spareBox is not.
type fleetRig struct {
	*fleetDeskRig
	ws   string
	base time.Time
}

func newFleetRig(t *testing.T) *fleetRig {
	t.Helper()
	r := &fleetRig{fleetDeskRig: newFleetDeskRig(t), ws: newTenantID("fw"), base: time.Now().UTC().Truncate(time.Second)}
	ctx := context.Background()
	root, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(ctx, store.Tenant{ID: r.ws, RootPubKey: root}); err != nil {
		t.Fatal(err)
	}
	if err := r.e.st.(store.FleetSeating).SetFleetSeating(ctx, r.ws, true); err != nil {
		t.Fatal(err)
	}
	if on, err := r.e.st.(store.BoxJoinSwitch).BoxJoinEnabled(ctx, r.ws); err != nil || on {
		t.Fatalf("control: box_join_enabled %v %v, want false", on, err)
	}
	if _, _, err := r.e.st.(store.FleetDeskBoxes).PutFleetDeskBox(ctx, r.opBox.id, "HUM-10"); err != nil {
		t.Fatal(err)
	}
	return r
}

// ts is the rig's clock plus n seconds, as the box sends it.
func (r *fleetRig) ts(n int) string {
	return r.base.Add(time.Duration(n) * time.Second).Format(time.RFC3339)
}

func boxPriv(t *testing.T, b *box) ed25519.PrivateKey {
	t.Helper()
	priv, err := sign.LoadPrivate(b.cfg.KeysDir, b.id)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

// enrolBody is a request for box into tenant at ts with a fresh key, signed
// by opKey (sig_op) and the fresh key (sig_new); it answers the fresh key too.
func enrolBody(tenant, boxID, ts string, opKey ed25519.PrivateKey) (map[string]any, ed25519.PrivateKey) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	return signedEnrol(tenant, boxID, ts, opKey, pub, priv), priv
}

func signedEnrol(tenant, boxID, ts string, opKey ed25519.PrivateKey, pub ed25519.PublicKey, newKey ed25519.PrivateKey) map[string]any {
	pk := base64.StdEncoding.EncodeToString(pub)
	payload, _ := wire.FleetEnrolPayload(tenant, boxID, pk, ts)
	return map[string]any{"tenant": tenant, "box_id": boxID, "pubkey": pk, "ts": ts,
		"sig_op": sign.Sign(opKey, payload), "sig_new": sign.Sign(newKey, payload)}
}

func (r *fleetRig) enrol(t *testing.T, body map[string]any) (int, map[string]any) {
	t.Helper()
	return call(t, r.e, r.op, http.MethodPost, "/v1/fleet/enrol", "", body)
}

// workspaces is GET /v1/fleet/workspaces signed by key as boxID at ts.
func (r *fleetRig) workspaces(t *testing.T, boxID, ts string, key ed25519.PrivateKey) (int, map[string]bool) {
	t.Helper()
	payload, _ := wire.FleetWorkspacesPayload(boxID, ts)
	req, _ := http.NewRequest(http.MethodGet, r.e.url(r.op)+"/v1/fleet/workspaces", nil)
	req.Header.Set(wire.FleetBoxHeader, boxID)
	req.Header.Set(wire.FleetTSHeader, ts)
	req.Header.Set(wire.FleetSigHeader, sign.Sign(key, payload))
	resp, err := r.e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out struct {
		Items []store.FleetWorkspace `json:"items"`
	}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	got := map[string]bool{}
	for _, w := range out.Items {
		got[w.Tenant] = w.Pinned
	}
	return resp.StatusCode, got
}

// enrolAudit is ws's fleet enrol audit rows, "<box> by <actor_tenant>/<actor_hum>".
func (r *fleetRig) enrolAudit(t *testing.T) []string {
	t.Helper()
	rows, err := r.e.st.(store.OperatorWorkspaces).OperatorAuditOf(context.Background(), r.ws, 50)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, a := range rows {
		if b, ok := a.Detail["fleet_enrol"].(string); ok && a.Action == store.AuditUpdate && a.Detail["box_mode"] == "fleet" {
			out = append(out, b+" by "+a.ActorTenant+"/"+a.ActorHum)
		}
	}
	return out
}

// Spec 158 row T7 (4.2.4, 4.5): the refusals - an unlisted box 403, a bad
// sig_op 401, a bad sig_new 401, fleet_seating false 403, a replayed ts 409 -
// and the enrolment itself: into a workspace with box_join_enabled false and
// no member holding agents.join it SUCCEEDS (201), the pin is the new key
// with box_mode fleet, and one operator_audit row is written. CONTROL: the
// same workspace with fleet_seating false is refused, then flipped on the
// same kind of request passes.
func TestFleetEnrol(t *testing.T) {
	r := newFleetRig(t)
	ctx := context.Background()
	opKey, spareKey := boxPriv(t, r.opBox), boxPriv(t, r.spareBox)

	body, _ := enrolBody(r.ws, r.spareBox.id, r.ts(1), spareKey)
	if code, got := r.enrol(t, body); code != http.StatusForbidden || got["error"] != "fleet_box_not_listed" {
		t.Errorf("unlisted box: %d %v, want 403 fleet_box_not_listed", code, got)
	}
	body, _ = enrolBody(r.ws, r.opBox.id, r.ts(1), spareKey)
	if code, got := r.enrol(t, body); code != http.StatusUnauthorized || got["error"] != "bad_sig" {
		t.Errorf("sig_op by another key: %d %v, want 401 bad_sig", code, got)
	}
	pub, _, _ := ed25519.GenerateKey(nil)
	_, wrong, _ := ed25519.GenerateKey(nil)
	if code, got := r.enrol(t, signedEnrol(r.ws, r.opBox.id, r.ts(1), opKey, pub, wrong)); code != http.StatusUnauthorized || got["error"] != "bad_sig" {
		t.Errorf("bad sig_new: %d %v, want 401 bad_sig", code, got)
	}
	body, _ = enrolBody(r.ws, r.opBox.id, time.Now().Add(-time.Hour).UTC().Format(time.RFC3339), opKey)
	if code, got := r.enrol(t, body); code != http.StatusUnauthorized {
		t.Errorf("ts an hour old: %d %v, want 401", code, got)
	}
	fs := r.e.st.(store.FleetSeating)
	if err := fs.SetFleetSeating(ctx, r.ws, false); err != nil {
		t.Fatal(err)
	}
	body, _ = enrolBody(r.ws, r.opBox.id, r.ts(1), opKey)
	if code, got := r.enrol(t, body); code != http.StatusForbidden || got["error"] != "fleet_seating_off" {
		t.Errorf("CONTROL fleet_seating false: %d %v, want 403 fleet_seating_off", code, got)
	}
	if got := r.enrolAudit(t); len(got) != 0 {
		t.Fatalf("a refused enrol wrote audit rows %v", got)
	}
	if err := fs.SetFleetSeating(ctx, r.ws, true); err != nil {
		t.Fatal(err)
	}
	body, newKey := enrolBody(r.ws, r.opBox.id, r.ts(2), opKey)
	code, got := r.enrol(t, body)
	if code != http.StatusCreated || got["box_mode"] != "fleet" || got["tenant"] != r.ws {
		t.Fatalf("enrol, box_join_enabled false, no agents.join holder: %d %v, want 201", code, got)
	}
	if pin, err := r.e.st.GetPin(ctx, r.ws, r.opBox.id); err != nil || !pin.Equal(newKey.Public()) {
		t.Fatalf("pin after enrol: %v %v, want the new key", pin, err)
	}
	if mode, err := r.e.st.(store.BoxJoinSwitch).PinBoxMode(ctx, r.ws, r.opBox.id); err != nil || mode != store.BoxModeFleet {
		t.Fatalf("box_mode %q %v, want fleet", mode, err)
	}
	if code, got := r.enrol(t, body); code != http.StatusConflict || got["error"] != "stale_pin_op" {
		t.Errorf("replayed ts: %d %v, want 409 stale_pin_op", code, got)
	}
	want := r.opBox.id + " by " + r.op + "/" + r.opBox.id
	if got := r.enrolAudit(t); len(got) != 1 || got[0] != want {
		t.Fatalf("audit %v, want [%s]", got, want)
	}
}

// The pin rules beyond the replay: the same key again at a later ts is 200
// (no second audit row); another fresh key for a box already seated is 409;
// the box's own operator key is live elsewhere, 409; a pin revoked after the
// listing is 403 until the operator lists the box again, then 201; a revoked
// operator pin stops the box (401). Unknown workspace 404.
func TestFleetEnrolPinRules(t *testing.T) {
	r := newFleetRig(t)
	ctx := context.Background()
	opKey := boxPriv(t, r.opBox)
	body, newKey := enrolBody(r.ws, r.opBox.id, r.ts(1), opKey)
	if code, got := r.enrol(t, body); code != http.StatusCreated {
		t.Fatalf("enrol: %d %v", code, got)
	}
	again := signedEnrol(r.ws, r.opBox.id, r.ts(2), opKey, newKey.Public().(ed25519.PublicKey), newKey)
	if code, got := r.enrol(t, again); code != http.StatusOK {
		t.Errorf("same key, later ts: %d %v, want 200", code, got)
	}
	other, _ := enrolBody(r.ws, r.opBox.id, r.ts(3), opKey)
	if code, got := r.enrol(t, other); code != http.StatusConflict || got["error"] != "pin_conflict" {
		t.Errorf("another key for a seated box: %d %v, want 409 pin_conflict", code, got)
	}
	ws2 := newTenantID("fw")
	root, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(ctx, store.Tenant{ID: ws2, RootPubKey: root}); err != nil {
		t.Fatal(err)
	}
	if err := r.e.st.(store.FleetSeating).SetFleetSeating(ctx, ws2, true); err != nil {
		t.Fatal(err)
	}
	live := signedEnrol(ws2, r.opBox.id, r.ts(3), opKey, opKey.Public().(ed25519.PublicKey), opKey)
	if code, got := r.enrol(t, live); code != http.StatusConflict || got["error"] != "pin_conflict" {
		t.Errorf("a key live in the operator workspace: %d %v, want 409 pin_conflict", code, got)
	}
	if err := r.e.st.RevokePin(ctx, r.ws, r.opBox.id, r.base.Add(4*time.Second), time.Now()); err != nil {
		t.Fatal(err)
	}
	body, _ = enrolBody(r.ws, r.opBox.id, r.ts(5), opKey)
	if code, got := r.enrol(t, body); code != http.StatusForbidden || got["error"] != "fleet_pin_revoked" {
		t.Errorf("revoked since listed: %d %v, want 403 fleet_pin_revoked", code, got)
	}
	fd := r.e.st.(store.FleetDeskBoxes)
	time.Sleep(20 * time.Millisecond)
	if err := fd.DeleteFleetDeskBox(ctx, r.opBox.id); err != nil {
		t.Fatal(err)
	}
	if _, _, err := fd.PutFleetDeskBox(ctx, r.opBox.id, "HUM-10"); err != nil {
		t.Fatal(err)
	}
	body, _ = enrolBody(r.ws, r.opBox.id, r.ts(6), opKey)
	if code, got := r.enrol(t, body); code != http.StatusCreated {
		t.Errorf("listed again: %d %v, want 201", code, got)
	}
	body, _ = enrolBody(newTenantID("nx"), r.opBox.id, r.ts(7), opKey)
	if code, _ := r.enrol(t, body); code != http.StatusNotFound {
		t.Errorf("unknown workspace: %d, want 404", code)
	}
	if err := r.e.st.RevokePin(ctx, r.op, r.opBox.id, r.base.Add(8*time.Second), time.Now()); err != nil {
		t.Fatal(err)
	}
	body, _ = enrolBody(ws2, r.opBox.id, r.ts(9), opKey)
	if code, got := r.enrol(t, body); code != http.StatusUnauthorized {
		t.Errorf("operator pin revoked: %d %v, want 401", code, got)
	}
}

// GET /v1/fleet/workspaces: a listed box sees ws (fleet_seating true) and
// whether it is pinned there; the other workspace (fleet_seating false) and
// a suspended one are not listed. An unlisted box 403, a bad signature 401.
func TestFleetWorkspaces(t *testing.T) {
	r := newFleetRig(t)
	ctx := context.Background()
	opKey := boxPriv(t, r.opBox)
	sus := newTenantID("fs")
	root, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(ctx, store.Tenant{ID: sus, RootPubKey: root}); err != nil {
		t.Fatal(err)
	}
	if err := r.e.st.(store.FleetSeating).SetFleetSeating(ctx, sus, true); err != nil {
		t.Fatal(err)
	}
	if err := r.e.st.(store.OperatorWorkspaces).SetWorkspaceState(ctx, sus, true, false, time.Now()); err != nil {
		t.Fatal(err)
	}
	// every create sets fleet_seating true (SPL-4295): opt other out
	if err := r.e.st.(store.FleetSeating).SetFleetSeating(ctx, r.other, false); err != nil {
		t.Fatal(err)
	}
	code, got := r.workspaces(t, r.opBox.id, r.ts(0), opKey)
	if pinned, ok := got[r.ws]; code != http.StatusOK || !ok || pinned {
		t.Fatalf("list: %d %v, want %s unpinned", code, got, r.ws)
	}
	if _, ok := got[r.other]; ok {
		t.Errorf("a workspace with fleet_seating false is listed: %v", got)
	}
	if _, ok := got[sus]; ok {
		t.Errorf("a suspended workspace is listed: %v", got)
	}
	body, _ := enrolBody(r.ws, r.opBox.id, r.ts(1), opKey)
	if code, got := r.enrol(t, body); code != http.StatusCreated {
		t.Fatalf("enrol: %d %v", code, got)
	}
	if _, got = r.workspaces(t, r.opBox.id, r.ts(1), opKey); !got[r.ws] {
		t.Errorf("after the enrol: %v, want %s pinned", got, r.ws)
	}
	if code, _ = r.workspaces(t, r.spareBox.id, r.ts(1), boxPriv(t, r.spareBox)); code != http.StatusForbidden {
		t.Errorf("unlisted box: %d, want 403", code)
	}
	if code, _ = r.workspaces(t, r.opBox.id, r.ts(1), boxPriv(t, r.spareBox)); code != http.StatusUnauthorized {
		t.Errorf("signed by another key: %d, want 401", code)
	}
}
