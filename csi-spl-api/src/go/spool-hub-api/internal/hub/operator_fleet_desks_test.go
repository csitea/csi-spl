package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

const fleetDesksPath = "/v1/operator/fleet-desks"

// fleetDeskRig is an operator workspace op with an admin and a developer,
// another workspace with its admin, a box pinned in op (opBox), a box pinned
// only in the other workspace (otherBox), and the operator service account.
type fleetDeskRig struct {
	e                         *env
	op, other                 string
	admin, dev, otherA        string
	opBox, otherBox, spareBox *box
}

func newFleetDeskRig(t *testing.T) *fleetDeskRig {
	t.Helper()
	r := &fleetDeskRig{op: newTenantID("op"), other: newTenantID("ot")}
	r.e = rbacEnv(t, func(o *hub.Options) {
		o.OperatorTenant = r.op
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
	for _, id := range []string{r.op, r.other} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := r.e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	r.admin, r.dev, r.otherA = seat(t, r.e, r.op, rbac.Admin), seat(t, r.e, r.op, rbac.Developer), seat(t, r.e, r.other, rbac.Admin)
	// Box ids are unique per rig: fleet_desk_boxes is the instance's table.
	r.opBox = r.e.box(r.op, "fd-"+newTenantID(""))
	r.spareBox = r.e.box(r.op, "fd-"+newTenantID(""))
	r.otherBox = r.e.box(r.other, "fd-"+newTenantID(""))
	r.e.pin(r.op, r.opBox)
	r.e.pin(r.op, r.spareBox)
	r.e.pin(r.other, r.otherBox)
	t.Cleanup(func() {
		fd := r.e.st.(store.FleetDeskBoxes)
		for _, b := range []*box{r.opBox, r.spareBox, r.otherBox} {
			_ = fd.DeleteFleetDeskBox(context.Background(), b.id)
		}
	})
	return r
}

// fleetDeskAudit is the op workspace's fleet desk audit rows, "add <box>" /
// "remove <box>", oldest first.
func (r *fleetDeskRig) audit(t *testing.T) []string {
	t.Helper()
	rows, err := r.e.st.(store.OperatorWorkspaces).OperatorAuditOf(context.Background(), r.op, 50)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, a := range rows {
		if box, ok := a.Detail["fleet_desk_box"].(string); ok && a.Action == store.AuditUpdate && a.ActorTenant == r.op {
			out = append(out, a.Detail["op"].(string)+" "+box+" by "+a.ActorHum)
		}
	}
	return out
}

func (r *fleetDeskRig) listed(t *testing.T) map[string]bool {
	t.Helper()
	code, got := call(t, r.e, r.op, http.MethodGet, fleetDesksPath, r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("admin list: %d %v", code, got)
	}
	out := map[string]bool{} // box -> live_pin; other tests' rows may share the Postgres table
	items, _ := got["items"].([]any)
	for _, it := range items {
		m := it.(map[string]any)
		out[m["box_id"].(string)] = m["live_pin"].(bool)
	}
	return out
}

// Spec 158 row T6: only the operator workspace's admin (or the operator
// service account) lists, adds and removes a fleet desk box; a box with no
// live pin in the operator workspace is refused - one pinned only in another
// workspace, one never pinned, one whose operator pin was revoked - and is
// not listed. Every add and remove writes one operator_audit row. CONTROL: the
// same admin's PUT of a box pinned in the operator workspace is 201.
func TestFleetDeskBoxRoutes(t *testing.T) {
	r := newFleetDeskRig(t)
	put := func(box, as string) (int, map[string]any) {
		return call(t, r.e, r.op, http.MethodPut, fleetDesksPath+"/"+box, as, nil)
	}
	for name, who := range map[string][2]string{"operator developer": {r.op, r.dev}, "other workspace admin": {r.other, r.otherA}, "anonymous": {r.op, ""}} {
		for _, rt := range [][2]string{{http.MethodGet, fleetDesksPath}, {http.MethodPut, fleetDesksPath + "/" + r.opBox.id},
			{http.MethodDelete, fleetDesksPath + "/" + r.opBox.id}} {
			if code, got := call(t, r.e, who[0], rt[0], rt[1], who[1], nil); code != http.StatusForbidden || got["permission"] != "operator.workspaces" {
				t.Errorf("%s %s %s: %d %v, want 403 operator.workspaces", name, rt[0], rt[1], code, got)
			}
		}
	}
	for name, box := range map[string]string{"pinned only in another workspace": r.otherBox.id, "never pinned": "fd-" + newTenantID("")} {
		if code, got := put(box, r.admin); code != http.StatusConflict || got["error"] != "no_live_pin" {
			t.Errorf("PUT a box %s: %d %v, want 409 no_live_pin", name, code, got)
		}
	}
	if code, got := put("Not_A_Box", r.admin); code != http.StatusBadRequest {
		t.Errorf("PUT a bad box id: %d %v, want 400", code, got)
	}
	if l := r.listed(t); l[r.opBox.id] || l[r.otherBox.id] {
		t.Fatalf("a refused PUT listed %v", l)
	}
	code, got := put(r.opBox.id, r.admin)
	if code != http.StatusCreated || got["box_id"] != r.opBox.id || got["added_by"] != r.admin || got["live_pin"] != true {
		t.Fatalf("CONTROL PUT a box pinned in the operator workspace: %d %v", code, got)
	}
	if code, got = put(r.opBox.id, r.admin); code != http.StatusOK || got["added_by"] != r.admin {
		t.Fatalf("second PUT: %d %v, want 200 and the row kept", code, got)
	}
	if l := r.listed(t); !l[r.opBox.id] || l[r.otherBox.id] {
		t.Fatalf("list after the PUT: %v", l)
	}
	if code, _ = call(t, r.e, r.op, http.MethodDelete, fleetDesksPath+"/"+r.opBox.id, r.admin, nil); code != http.StatusNoContent {
		t.Fatalf("delete: %d", code)
	}
	if code, _ = call(t, r.e, r.op, http.MethodDelete, fleetDesksPath+"/"+r.opBox.id, r.admin, nil); code != http.StatusNotFound {
		t.Fatalf("second delete: %d, want 404", code)
	}
	want := []string{"add " + r.opBox.id + " by " + r.admin, "remove " + r.opBox.id + " by " + r.admin}
	if got := r.audit(t); len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("audit %v, want %v", got, want)
	}
	if err := r.e.st.RevokePin(context.Background(), r.op, r.opBox.id, time.Now().Add(time.Second), time.Now()); err != nil {
		t.Fatal(err)
	}
	if code, got = put(r.opBox.id, r.admin); code != http.StatusConflict || got["error"] != "no_live_pin" {
		t.Fatalf("PUT a box whose operator pin was revoked: %d %v, want 409 no_live_pin", code, got)
	}
}

// The operator service account (the path of do_spl_fleet_desk_box) adds, lists
// and removes a box with no member session; the audit row names it. A token
// that is not the operator's is refused.
func TestFleetDeskBoxOperatorSA(t *testing.T) {
	r := newFleetDeskRig(t)
	path := fleetDesksPath + "/" + r.spareBox.id
	if code, _ := opCall(t, r.e, r.op, http.MethodPut, path, "junk", nil); code != http.StatusForbidden && code != http.StatusUnauthorized {
		t.Errorf("a bad token: %d, want 401/403", code)
	}
	if code, got := opCall(t, r.e, r.op, http.MethodPut, path, "good", nil); code != http.StatusCreated || got["added_by"] != operatorSA {
		t.Fatalf("SA PUT: %d %v", code, got)
	}
	if code, got := opCall(t, r.e, r.op, http.MethodGet, fleetDesksPath, "good", nil); code != http.StatusOK || !r.listed(t)[r.spareBox.id] {
		t.Fatalf("SA list: %d %v", code, got)
	}
	if code, _ := opCall(t, r.e, r.op, http.MethodDelete, path, "good", nil); code != http.StatusNoContent {
		t.Fatalf("SA delete: %d", code)
	}
	want := []string{"add " + r.spareBox.id + " by " + operatorSA, "remove " + r.spareBox.id + " by " + operatorSA}
	if got := r.audit(t); len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("audit %v, want %v", got, want)
	}
}
