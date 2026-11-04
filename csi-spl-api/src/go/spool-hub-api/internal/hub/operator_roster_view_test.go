package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 153 section 3.17 (SPL-4786): GET /v1/operator/fleet-roster, the
// boxes and agents the other workspaces have on their own, one row per box.
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full); there
// the tenants table is the instance's, so each case reads only its own ids.

const fleetRosterPath = "/v1/operator/fleet-roster"

type rosterRow struct {
	Workspace     string   `json:"workspace"`
	WorkspaceName string   `json:"workspace_name"`
	BoxID         string   `json:"box_id"`
	Agents        []string `json:"agents"`
	PubKey        *string  `json:"pub_key"`
	OS            any      `json:"os"`
	AgentPresence map[string]struct {
		State string `json:"state"`
	} `json:"agent_presence"`
}

type rosterView struct {
	Boxes      []rosterRow `json:"boxes"`
	AlsoSeated map[string][]struct {
		Workspace     string `json:"workspace"`
		WorkspaceName string `json:"workspace_name"`
	} `json:"also_seated"`
}

func getFleetRoster(t *testing.T, r *fleetTokensRig) rosterView {
	t.Helper()
	code, body := call(t, r.e, r.op, http.MethodGet, fleetRosterPath, r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("GET %s as the operator admin: %d %v", fleetRosterPath, code, body)
	}
	raw, _ := json.Marshal(body)
	var v rosterView
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// rowsOf is the view's rows of box id, as workspace|box|agents.
func rowsOf(v rosterView, box string) []rosterRow {
	out := []rosterRow{}
	for _, b := range v.Boxes {
		if b.BoxID == box {
			out = append(out, b)
		}
	}
	return out
}

func namedWorkspace(t *testing.T, r *fleetTokensRig, prefix, name string) string {
	t.Helper()
	id := newTenantID(prefix)
	pub, _, _ := ed25519.GenerateKey(nil)
	ctx := context.Background()
	if err := r.e.st.CreateTenant(ctx, store.Tenant{ID: id, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	if err := r.e.st.(store.TenantSettings).SetTenantConfig(ctx, id, store.TenantConfigPatch{DisplayName: &name}); err != nil {
		t.Fatal(err)
	}
	return id
}

// R1, R2: a box pinned only in a customer workspace is a row under it, its
// agent keyed by its own box (c-001 on two boxes = two rows); a box the
// operator workspace also has is no customer row, only also_seated.
// RED CONTROL (planted, commit body): the loop limited to the operator
// workspace -> the customer box absent; the own-box skip dropped -> the
// shared box a customer row.
func TestFleetRosterCustomerBoxOnce(t *testing.T) {
	r := newFleetTokensRig(t)
	cust := namedWorkspace(t, r, "cu", "Customer Space")
	mac := r.e.box(cust, "mac-"+newTenantID(""), "c-001")
	r.e.pin(cust, mac)
	sat := r.e.box(r.op, "sat-"+newTenantID(""), "c-001")
	r.e.pin(r.op, sat)
	r.e.pin(cust, r.e.box(cust, sat.id, "c-002")) // seated in the customer workspace too, with its own key there

	v := getFleetRoster(t, r)
	got := rowsOf(v, mac.id)
	if len(got) != 1 || got[0].Workspace != cust || got[0].WorkspaceName != "Customer Space" {
		t.Fatalf("R1 customer box %s rows %+v, want one under %s named Customer Space", mac.id, got, cust)
	}
	if !slices.Equal(got[0].Agents, []string{"c-001"}) || got[0].AgentPresence["c-001"].State == "" {
		t.Errorf("R1 agents %v presence %v, want c-001 with a state", got[0].Agents, got[0].AgentPresence)
	}
	if got[0].PubKey != nil || got[0].OS != nil {
		t.Errorf("R1 a customer row carries a key or host facts: %+v", got[0])
	}
	if n := rowsOf(v, sat.id); len(n) != 0 {
		t.Errorf("R2 the operator's own box %s is a customer row too: %+v", sat.id, n)
	}
	seats := v.AlsoSeated[sat.id]
	if len(seats) != 1 || seats[0].Workspace != cust || seats[0].WorkspaceName != "Customer Space" {
		t.Errorf("R2 also_seated[%s] = %+v, want the customer workspace", sat.id, seats)
	}
	if n := rowsOf(v, r.opBox.id); len(n) != 0 {
		t.Errorf("R2 the operator workspace's box is a row: %+v", n)
	}
	if n := rowsOf(v, r.otherBox.id); len(n) != 1 || n[0].Workspace != r.other {
		t.Errorf("R1 the other workspace's box rows %+v, want one under %s", n, r.other)
	}
}

// R3: an archived workspace and a box locked in its workspace are absent.
func TestFleetRosterArchivedAndLocked(t *testing.T) {
	r := newFleetTokensRig(t)
	gone := namedWorkspace(t, r, "ar", "Archived Space")
	old := r.e.box(gone, "old-"+newTenantID(""))
	r.e.pin(gone, old)
	if err := r.e.st.(store.OperatorWorkspaces).SetWorkspaceState(context.Background(), gone, true, true, time.Now()); err != nil {
		t.Fatal(err)
	}
	lockTo(t, r.e, r.other, r.otherBox, "HUM-1")
	v := getFleetRoster(t, r)
	if n := rowsOf(v, old.id); len(n) != 0 {
		t.Errorf("R3 archived workspace's box listed: %+v", n)
	}
	if n := rowsOf(v, r.otherBox.id); len(n) != 0 {
		t.Errorf("R3 a locked box listed: %+v", n)
	}
}

// R4: only the operator workspace's admin (or the operator SA) may read it.
func TestFleetRosterDoors(t *testing.T) {
	r := newFleetTokensRig(t)
	for _, who := range [][2]string{{r.op, r.dev}, {r.other, r.otherA}} {
		if code, body := call(t, r.e, who[0], http.MethodGet, fleetRosterPath, who[1], nil); code != http.StatusForbidden {
			t.Errorf("R4 %s of %s: %d %v, want 403", who[1], who[0], code, body)
		}
	}
}
