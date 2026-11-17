package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 119 primary-workspace.md v0.3.1, T-PW1 (tasks.md T019): the Primary
// workspace setting on PUT /v1/me/realm/profile. A workspace outside 2.1 is
// 400 bad_primary_workspace and writes nothing; a valid one is stored and
// read back; act-as, an agent and a box token are 403 person_only. A stored
// workspace that stops passing 2.1 is kept and answered stale (2.4). Memory,
// and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// pwRig is P signed in as the owner of W1, with a demo workspace on and the
// act-as clone switch of notesCloneStore.
type pwRig struct {
	r     *doorRig
	cs    *notesCloneStore
	w1    string
	demo  string
	p     string
	ident store.Identity
}

func newPWRig(t *testing.T) *pwRig {
	t.Helper()
	sub := "pw-" + randHex(5)
	demo := "t" + randHex(4)
	cs := &notesCloneStore{}
	r, _, w1 := realmRigAs(t, &lockedBuf{}, sub, func(o *hub.Options) {
		o.DemoWorkspace = demo
		// The wrapper hides store.Humans, so the hub would build no
		// authorizer: wire the one cmd/spool's store gives it.
		o.Authorizer = &rbac.Authorizer{Src: store.RBACSource{H: o.Store.(store.Humans)}}
		cs.Store, cs.Realm, cs.Notes, cs.MembershipLister = o.Store, o.Store.(store.Realm), o.Store.(store.Notes), o.Store.(store.MembershipLister)
		o.Store = cs
	})
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(context.Background(), store.Tenant{ID: demo, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	return &pwRig{r: r, cs: cs, w1: w1, demo: demo, p: r.session(t).HumanID,
		ident: store.Identity{Provider: "google", Subject: sub, Email: sub + "@example.com"}}
}

// seatP seats P in a fresh workspace (or tid, when given) with role, through
// an invite to P's own address, and answers the workspace.
func (x *pwRig) seatP(t *testing.T, tid, role string) string {
	t.Helper()
	if tid == "" {
		tid, _ = x.r.e.tenant()
	}
	h := x.r.e.st.(store.Humans)
	now := time.Now()
	if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: x.ident.Email, Role: role,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	hum, err := h.Admit(context.Background(), x.ident, tid, store.AdmitPolicy{}, now)
	if err != nil || hum != x.p {
		t.Fatalf("seat P in %s as %s: %s %v, want %s", tid, role, hum, err, x.p)
	}
	return tid
}

// put sends PUT /v1/me/realm/profile with ws as the primary workspace.
func (x *pwRig) put(t *testing.T, ws string, hdr map[string]string) (int, map[string]any) {
	t.Helper()
	return realmDo(t, x.r, http.MethodPut, "/v1/me/realm/profile",
		map[string]any{"time_zone": "Europe/Helsinki", "primary_workspace_id": ws}, hdr)
}

// stored is P's primary workspace as the store holds it.
func (x *pwRig) stored(t *testing.T) string {
	t.Helper()
	p, err := x.r.e.st.(store.Realm).RealmProfileOf(context.Background(), x.p)
	if err != nil {
		t.Fatal(err)
	}
	return p.PrimaryWorkspaceID
}

func TestRealmPrimaryWorkspaceSetting(t *testing.T) {
	x := newPWRig(t)
	ctx := context.Background()
	valid := x.seatP(t, "", rbac.Developer)
	outside, _ := x.r.e.tenant()
	guest := x.seatP(t, "", rbac.ChannelGuest)
	accountant := x.seatP(t, "", rbac.TimeAccountant)
	demo := x.seatP(t, x.demo, rbac.DemoUser)
	readOnly := x.seatP(t, "", rbac.Developer)
	if err := x.r.e.st.SetBillingStatus(ctx, readOnly, billing.StatusUnpaid); err != nil {
		t.Fatal(err)
	}

	// A valid one (and P's own W1) is stored and read back.
	for _, ws := range []string{valid, x.w1} {
		if code, out := x.put(t, ws, nil); code != http.StatusOK || out["primary_workspace_id"] != ws || out["primary_workspace_stale"] != nil {
			t.Fatalf("PUT valid %s = %d %v, want 200 with it", ws, code, out)
		}
		if code, out := realmDo(t, x.r, http.MethodGet, "/v1/me/realm/profile", nil, nil); code != http.StatusOK || out["primary_workspace_id"] != ws {
			t.Fatalf("GET after PUT %s = %d %v", ws, code, out)
		}
	}

	// Outside 2.1: 400 bad_primary_workspace, nothing written (the zone too).
	for _, c := range []struct{ name, ws string }{
		{"not a member", outside}, {"a channel_guest seat", guest}, {"no notes.send (accountant only)", accountant},
		{"a demo visit", demo}, {"billing read-only", readOnly}, {"no such workspace", "t-none-" + randHex(4)},
		{"201 bytes", strings.Repeat("w", 201)},
	} {
		code, out := realmDo(t, x.r, http.MethodPut, "/v1/me/realm/profile",
			map[string]any{"time_zone": "Asia/Tokyo", "primary_workspace_id": c.ws}, nil)
		if code != http.StatusBadRequest || realmToken(out) != "bad_primary_workspace" {
			t.Errorf("T-PW1 %s: PUT = %d %v, want 400 bad_primary_workspace", c.name, code, out)
		}
		if p, _ := x.r.e.st.(store.Realm).RealmProfileOf(ctx, x.p); p.PrimaryWorkspaceID != x.w1 || p.TimeZone != "Europe/Helsinki" {
			t.Errorf("T-PW1 %s: the refused PUT wrote %+v", c.name, p)
		}
	}

	// "" clears it.
	if code, out := x.put(t, "", nil); code != http.StatusOK || out["primary_workspace_id"] != "" || x.stored(t) != "" {
		t.Fatalf("PUT \"\" = %d %v, stored %q: want cleared", code, out, x.stored(t))
	}

	// 2.4: W stops passing 2.1 (billing stops writes): the value is kept and
	// answered stale; writes back on, it is not.
	if code, _ := x.put(t, valid, nil); code != http.StatusOK {
		t.Fatalf("PUT valid again = %d", code)
	}
	if err := x.r.e.st.SetBillingStatus(ctx, valid, billing.StatusUnpaid); err != nil {
		t.Fatal(err)
	}
	if code, out := realmDo(t, x.r, http.MethodGet, "/v1/me/realm/profile", nil, nil); code != http.StatusOK ||
		out["primary_workspace_id"] != valid || out["primary_workspace_stale"] != true {
		t.Errorf("T-PW1 stale: GET = %d %v, want the id kept and primary_workspace_stale true", code, out)
	}
	if err := x.r.e.st.SetBillingStatus(ctx, valid, billing.StatusActive); err != nil {
		t.Fatal(err)
	}
	if _, out := realmDo(t, x.r, http.MethodGet, "/v1/me/realm/profile", nil, nil); out["primary_workspace_stale"] != nil {
		t.Errorf("CONTROL: writes back on, GET still answers stale: %v", out)
	}

	// A body cannot set the answered flag.
	if code, out := realmDo(t, x.r, http.MethodPut, "/v1/me/realm/profile",
		map[string]any{"primary_workspace_id": valid, "primary_workspace_stale": true}, nil); code != http.StatusBadRequest {
		t.Errorf("PUT with primary_workspace_stale = %d %v, want 400 (unknown field)", code, out)
	}

	// A box token and act-as: 403 person_only, nothing written.
	if code, out := x.put(t, x.w1, map[string]string{"Authorization": "Bearer box-upload-token"}); code != http.StatusForbidden || realmToken(out) != "person_only" {
		t.Errorf("T-PW1 box token: PUT = %d %v, want 403 person_only", code, out)
	}
	x.cs.clone = x.p // P's session is now an act-as clone's
	if code, out := x.put(t, x.w1, nil); code != http.StatusForbidden || realmToken(out) != "person_only" {
		t.Errorf("T-PW1 act-as: PUT = %d %v, want 403 person_only", code, out)
	}
	x.cs.clone = ""
	if got := x.stored(t); got != valid {
		t.Errorf("a refused caller wrote: stored %q, want %q", got, valid)
	}
}

// TestRealmPrimaryWorkspaceAgent: a signed-in human whose one seat is a
// pure agent's has no realm (realmRefuses): PUT is 403 person_only and
// writes nothing.
func TestRealmPrimaryWorkspaceAgent(t *testing.T) {
	x := newPWRig(t)
	n := &notesRig{r: x.r}
	c, agent := n.browserAs(t, x.w1, rbac.PureAgent)
	code, out, _ := n.do(t, c, http.MethodPut, "/v1/me/realm/profile", map[string]any{"primary_workspace_id": x.w1}, nil)
	if code != http.StatusForbidden || realmToken(out) != "person_only" {
		t.Errorf("T-PW1 agent: PUT = %d %v, want 403 person_only", code, out)
	}
	if p, _ := x.r.e.st.(store.Realm).RealmProfileOf(context.Background(), agent); p.PrimaryWorkspaceID != "" {
		t.Errorf("the agent's refused PUT wrote: %+v", p)
	}
	// CONTROL: P's own PUT of the same body is 200.
	if code, out := x.put(t, x.w1, nil); code != http.StatusOK {
		t.Errorf("CONTROL: P's PUT = %d %v, want 200", code, out)
	}
}
