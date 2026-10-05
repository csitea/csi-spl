package auth_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// s077 LEAK-1 (c-325 proof): a sign-in naming a workspace whose seat is
// suspended or past access_until must be refused like a stranger's, because
// the door (MemberRole) already says "no membership".
func TestAdmitRefusesDeadSeat(t *testing.T) {
	for _, kind := range []string{"control-live", "suspended", "expired"} {
		t.Run(kind, func(t *testing.T) {
			st := store.NewMemory()
			ctx, now := context.Background(), time.Now()
			pub, _, _ := ed25519.GenerateKey(nil)
			f := struct{ hum, dev string }{dev: "tc325b"}
			who := store.Identity{Provider: "google", Subject: "c325-sub", Email: "c325@example.com"}
			if err := st.CreateTenant(ctx, store.Tenant{ID: f.dev, RootPubKey: pub}); err != nil {
				t.Fatal(err)
			}
			if err := st.PutInvite(ctx, store.Invite{TenantID: f.dev, Email: who.Email, Role: rbac.Developer,
				InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			var err0 error
			if f.hum, err0 = st.Admit(ctx, who, f.dev, store.AdmitPolicy{}, now); err0 != nil {
				t.Fatal(err0)
			}
			switch kind {
			case "suspended":
				if err := st.SetMemberDisabled(ctx, f.dev, f.hum, true, time.Now()); err != nil {
					t.Fatal(err)
				}
			case "expired":
				past := time.Now().Add(-time.Hour)
				if err := st.SetMemberAccessUntil(ctx, f.dev, f.hum, &past); err != nil {
					t.Fatal(err)
				}
			}
			hooks := store.AuthHooks{H: st}
			member, _ := hooks.Member(ctx, f.hum, f.dev)
			hum, err := hooks.Register(ctx, auth.Identity{Provider: who.Provider, Subject: who.Subject, Email: who.Email}, f.dev)
			_ = hum
			if kind == "control-live" {
				if !member || err != nil {
					t.Fatalf("CONTROL: live seat member=%v register err=%v", member, err)
				}
				return
			}
			if member {
				t.Fatalf("door says member for a %s seat", kind)
			}
			if !errors.Is(err, auth.ErrNotAllowed) {
				t.Errorf("LEAK-1: door says no membership, yet Register admitted the %s seat (err=%v): the callback would put t=%s in the cookie and record sign_in there", kind, err, f.dev)
			}
		})
	}
}
