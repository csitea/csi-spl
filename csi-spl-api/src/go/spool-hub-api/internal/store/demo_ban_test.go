package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// specs/077 3.6 "ban", T016 part B: BanMember removes the demo_user and lists
// its account and address digests; the open admission then refuses that
// account, and another account with the same address, and writes nothing.
// Another visitor is unaffected, and the ban list is per workspace.
func TestDemoBan(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			r := newDemoStayRig(t, s, time.Hour)
			r.open.OpenProviders = []string{"google", "facebook"}
			bans := s.(DemoBans)
			at := r.t0.Add(time.Minute)
			alice, bob := r.admit(t, "alice", at), r.admit(t, "bob", at)
			if err := bans.BanMember(ctx, r.demo, alice, "HUM-mod", at); err != nil {
				t.Fatalf("ban alice: %v", err)
			}
			if n := r.members(t); n != 1 {
				t.Fatalf("after the ban %d memberships, want 1 (bob)", n)
			}
			if err := bans.BanMember(ctx, r.demo, alice, "HUM-mod", at); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second ban of a removed member: %v, want ErrNotFound", err)
			}
			// Negative: the banned account at the next admission.
			if hum, err := r.admitErr(r.ident("alice"), r.open, at.Add(time.Minute)); !errors.Is(err, ErrDemoBanned) ||
				!errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("banned account re-admitted: %q %v, want ErrDemoBanned", hum, err)
			}
			// Negative: a new account (another provider) with the banned address.
			fb := r.ident("alice")
			fb.Provider, fb.Subject = "facebook", "fb-"+r.tag
			if hum, err := r.admitErr(fb, r.open, at.Add(time.Minute)); !errors.Is(err, ErrDemoBanned) {
				t.Fatalf("banned address via another account: %q %v, want ErrDemoBanned", hum, err)
			}
			if n := r.members(t); n != 1 {
				t.Fatalf("refused admissions left %d memberships, want 1", n)
			}
			if b, err := bans.DemoBanned(ctx, r.demo, r.ident("alice")); err != nil || !b {
				t.Fatalf("DemoBanned(alice) = %v %v, want true", b, err)
			}
			// CONTROL: bob, never banned, signs in again inside his stay, and
			// a new visitor is admitted at the same instant.
			if got, err := r.admitErr(r.ident("bob"), r.open, at.Add(time.Minute)); err != nil || got != bob {
				t.Fatalf("bob re-login: %q %v", got, err)
			}
			r.admit(t, "carol", at.Add(time.Minute))
			if b, err := bans.DemoBanned(ctx, r.demo, r.ident("bob")); err != nil || b {
				t.Fatalf("DemoBanned(bob) = %v %v, want false", b, err)
			}
			// CONTROL: the ban list is per workspace.
			other := newDemoStayRig(t, s, time.Hour)
			other.tag = r.tag
			if b, err := bans.DemoBanned(ctx, other.demo, r.ident("alice")); err != nil || b {
				t.Fatalf("alice banned in another workspace: %v %v", b, err)
			}
			other.admit(t, "alice", at.Add(time.Minute))
		})
	}
}
