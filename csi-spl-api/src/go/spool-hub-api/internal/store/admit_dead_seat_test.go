package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// s077 LEAK-1: a sign-in naming a workspace re-admits an existing seat only
// when the door would let it in. A suspended, ended (access_until) or fenced
// demo seat is refused like a stranger, so the callback sets no cookie `t`,
// records no sign_in and stores no picture there. CONTROL: a live seat, and a
// live demo seat in the open demo workspace, still sign in.
func TestAdmitRefusesDeadSeat(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		h := s.(Humans)
		ma, ok := s.(MemberAccess)
		if !ok {
			t.Fatalf("%s: no MemberAccess", name)
		}
		for _, kind := range []string{"control-live", "suspended", "expired", "control-demo", "fenced-demo-off", "fenced-demo-moved"} {
			t.Run(name+"/"+kind, func(t *testing.T) {
				now := time.Now().UTC()
				tid := newTenant(t, s)
				who := Identity{Provider: "google", Subject: uid("sub-"), Email: uid("dead-") + "@example.com"}
				demo := AdmitPolicy{OpenWorkspace: tid, OpenProviders: []string{"google"}}
				seat, again := AdmitPolicy{}, AdmitPolicy{}
				switch kind {
				case "control-demo", "fenced-demo-off", "fenced-demo-moved":
					seat, again = demo, demo
				default:
					if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: who.Email, Role: rbac.Developer,
						InvitedBy: AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
						t.Fatal(err)
					}
				}
				hum, err := h.Admit(ctx, who, tid, seat, now)
				if err != nil {
					t.Fatalf("first sign-in: %v", err)
				}
				switch kind {
				case "suspended":
					if err := s.(TenantSettings).SetMemberDisabled(ctx, tid, hum, true, now); err != nil {
						t.Fatal(err)
					}
				case "expired":
					past := now.Add(-time.Hour)
					if err := ma.SetMemberAccessUntil(ctx, tid, hum, &past); err != nil {
						t.Fatal(err)
					}
				case "fenced-demo-off":
					again = AdmitPolicy{}
				case "fenced-demo-moved":
					again = AdmitPolicy{OpenWorkspace: "another-demo", OpenProviders: []string{"google"}}
				}
				_, err = h.Admit(ctx, who, tid, again, now.Add(time.Minute))
				if kind == "control-live" || kind == "control-demo" {
					if err != nil {
						t.Fatalf("CONTROL: a live seat re-signs in: %v", err)
					}
					return
				}
				if !errors.Is(err, ErrNotAdmitted) {
					t.Fatalf("LEAK-1: the %s seat re-admitted (err=%v), want ErrNotAdmitted", kind, err)
				}
			})
		}
	}
}
