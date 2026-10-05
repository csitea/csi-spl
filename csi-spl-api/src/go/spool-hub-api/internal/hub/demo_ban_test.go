package hub_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/077 3.6 "ban", T016 part B: in the demo workspace a moderator's
// DELETE /v1/members/{human_id} of a demo_user is a ban. The member is gone,
// and the open admission refuses that identity next time. A demo_user cannot
// ban; a removal outside the demo workspace bans nothing.
func TestDemoBan(t *testing.T) {
	e, demo := demoEnv(t)
	ctx := context.Background()
	admin := seat(t, e, demo, rbac.Admin)
	vic, vicID := seatIdent(t, e, demo, rbac.DemoUser)
	other, _ := seatIdent(t, e, demo, rbac.DemoUser)
	bans := e.st.(store.DemoBans)
	open := store.AdmitPolicy{OpenWorkspace: demo, OpenProviders: []string{"google"}}

	// Negative: a demo_user cannot ban another visitor.
	if code, _ := call(t, e, demo, http.MethodDelete, "/v1/members/"+vic, other, nil); code != http.StatusForbidden {
		t.Fatalf("demo_user ban: %d, want 403", code)
	}
	if b, _ := bans.DemoBanned(ctx, demo, vicID); b || !isMember(t, e, demo, vic) {
		t.Fatalf("a refused ban changed state: banned=%v member=%v", b, isMember(t, e, demo, vic))
	}
	if code, _ := call(t, e, demo, http.MethodDelete, "/v1/members/"+vic, admin, nil); code != http.StatusNoContent {
		t.Fatalf("moderator ban: %d, want 204", code)
	}
	if isMember(t, e, demo, vic) {
		t.Fatal("the banned visitor is still a member")
	}
	if b, err := bans.DemoBanned(ctx, demo, vicID); err != nil || !b {
		t.Fatalf("DemoBanned after the ban: %v %v, want true", b, err)
	}
	// The banned identity is refused at the next admission.
	if hum, err := e.st.(store.Humans).Admit(ctx, vicID, demo, open, time.Now()); !errors.Is(err, store.ErrDemoBanned) {
		t.Fatalf("banned identity re-admitted: %q %v, want ErrDemoBanned", hum, err)
	}
	// CONTROL: the visitor not banned keeps the seat.
	if !isMember(t, e, demo, other) {
		t.Fatal("the other visitor lost the seat")
	}

	// CONTROL: removing a member of another workspace bans nothing.
	t2 := "t" + randHex(4)
	if err := e.st.CreateTenant(ctx, store.Tenant{ID: t2, RootPubKey: make([]byte, 32)}); err != nil {
		t.Fatal(err)
	}
	owner := seat(t, e, t2, rbac.Admin)
	dev, devID := seatIdent(t, e, t2, rbac.Developer)
	if code, _ := call(t, e, t2, http.MethodDelete, "/v1/members/"+dev, owner, nil); code != http.StatusNoContent {
		t.Fatalf("remove in t2: %d, want 204", code)
	}
	if b, _ := bans.DemoBanned(ctx, t2, devID); b {
		t.Fatal("a removal outside the demo workspace banned the identity")
	}
}

// seatIdent is seat, also answering the identity the member signed in with.
func seatIdent(t *testing.T, e *env, tid, role string) (string, store.Identity) {
	t.Helper()
	h := e.st.(store.Humans)
	email := randHex(5) + "@example.com"
	now := time.Now()
	if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: role,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	id := store.Identity{Provider: "google", Subject: "s-" + email, Email: email}
	hum, err := h.Admit(context.Background(), id, tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return hum, id
}

func isMember(t *testing.T, e *env, tid, hum string) bool {
	t.Helper()
	ms, err := e.st.(store.MemberDirectory).ListMembers(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range ms {
		if m.HumanID == hum {
			return true
		}
	}
	return false
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b) //nolint:errcheck
	return hex.EncodeToString(b)
}
