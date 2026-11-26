package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// wuiPinOf is tenant's live box-wui pin, nil when it has none.
func wuiPinOf(t *testing.T, e *env, tenant string) ed25519.PublicKey {
	t.Helper()
	got, err := e.st.GetPin(context.Background(), tenant, hub.WUIBox)
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return got
}

// wuiSweepEnv is an operator env with the sweep switch set to on, and the
// system workspace present (Postgres has it from rdb 0191, Memory gets it
// here, live, so the system skip is the sweep's own rule).
func wuiSweepEnv(t *testing.T, on bool) (e *env, op, admin string) {
	t.Helper()
	op = newTenantID("op")
	e = rbacEnv(t, func(o *hub.Options) { o.OperatorTenant, o.BoxWUIPinSweep = op, on })
	for _, id := range []string{op, store.SystemTenant} {
		pub, _, _ := ed25519.GenerateKey(nil)
		err := e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub})
		if err != nil && id == op {
			t.Fatal(err)
		}
	}
	return e, op, seat(t, e, op, rbac.Admin)
}

// Spec 158 10.6 item 3 (row P2, SPL-5020): with cnf hub.box_wui_pin_sweep on,
// the sweep pins the hub's box-wui key in a workspace with no box-wui pin
// row, once (one audit row, a second sweep writes nothing), and skips the
// system, suspended, archived and unpaid workspaces; a revoked pin and a
// foreign key stay as they are (P1's controls). RED CONTROL: on the code
// before P2 there is no sweep, and the workspace with no row stays unpinned.
func TestSweepWUIPinsPinsGapsOnly(t *testing.T) {
	e, op, admin := wuiSweepEnv(t, true)
	ctx, wui, now := context.Background(), hubWUIPub(t, e), time.Now().UTC().Truncate(time.Second)
	foreign, _, _ := ed25519.GenerateKey(nil)
	gap, sus, arc, unpaid, fid, rid := wuiPinTenant(t, e), wuiPinTenant(t, e), wuiPinTenant(t, e),
		wuiPinTenant(t, e), wuiPinTenant(t, e), wuiPinTenant(t, e)
	ows := e.st.(store.OperatorWorkspaces)
	if err := ows.SetWorkspaceState(ctx, sus, true, false, now); err != nil {
		t.Fatal(err)
	}
	if err := ows.SetWorkspaceState(ctx, arc, true, true, now); err != nil {
		t.Fatal(err)
	}
	if err := e.st.SetBillingStatus(ctx, unpaid, billing.StatusUnpaid); err != nil {
		t.Fatal(err)
	}
	for _, p := range []struct {
		id  string
		key ed25519.PublicKey
	}{{fid, foreign}, {rid, wui}} {
		if err := e.st.PutPin(ctx, p.id, hub.WUIBox, p.key, false, now, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.st.RevokePin(ctx, rid, hub.WUIBox, now.Add(time.Second), now); err != nil {
		t.Fatal(err)
	}
	sys := wuiPinOf(t, e, store.SystemTenant)
	if n := e.srv.SweepWUIPins(ctx); n < 1 {
		t.Fatalf("sweep pinned %d workspaces, want at least the gap", n)
	}
	e.srv.SweepWUIPins(ctx)
	if got := wuiPinOf(t, e, gap); !got.Equal(wui) {
		t.Fatalf("gap: box-wui pin %x, want the hub's key", got)
	}
	if n := wuiPinRows(t, e, op, admin, gap); n != 1 {
		t.Fatalf("gap: %d box-wui pin audit rows after two sweeps, want 1", n)
	}
	for _, c := range []struct {
		name, id string
		want     ed25519.PublicKey
	}{{"suspended", sus, nil}, {"archived", arc, nil}, {"unpaid", unpaid, nil},
		{"revoked", rid, nil}, {"foreign key", fid, foreign}, {"system", store.SystemTenant, sys}} {
		if got := wuiPinOf(t, e, c.id); !got.Equal(c.want) {
			t.Fatalf("%s: box-wui pin %x after the sweep, want %x", c.name, got, c.want)
		}
		if c.id != store.SystemTenant {
			if n := wuiPinRows(t, e, op, admin, c.id); n != 0 {
				t.Fatalf("%s: %d box-wui pin audit rows, want 0", c.name, n)
			}
		}
	}
}

// Spec 158 10.6 item 3: the switch defaults off, and off the sweep writes
// nothing. CONTROL: the same workspace is pinned by an ensureWUIPin call, so
// the empty sweep is the switch, not a missing key.
func TestSweepWUIPinsSwitchOff(t *testing.T) {
	e, op, admin := wuiSweepEnv(t, false)
	ctx, gap := context.Background(), wuiPinTenant(t, e)
	if n := e.srv.SweepWUIPins(ctx); n != 0 {
		t.Fatalf("switch off: sweep pinned %d, want 0", n)
	}
	if got := wuiPinOf(t, e, gap); got != nil {
		t.Fatalf("switch off: box-wui pin %x, want none", got)
	}
	if got := e.srv.EnsureWUIPin(ctx, gap, op, admin); got != "pinned" {
		t.Fatalf("control: ensureWUIPin = %q, want pinned", got)
	}
}
