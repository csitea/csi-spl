package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Sign-in emails (owner HUM-10, t1 f265541a, msgs cca0746d + 39420f52): the
// person or an admin adds an address as PENDING; only a cloud-provider
// sign-in that proves it, started from the holder's own session (LinkTo),
// turns it ACTIVE. Every positive case below has its control.

func emailsOf(t *testing.T, e SignInEmails, hum string) map[string]SignInEmail {
	t.Helper()
	list, err := e.SignInEmails(context.Background(), hum)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]SignInEmail{}
	for _, x := range list {
		out[x.Email] = x
	}
	return out
}

func admitOK(t *testing.T, h Humans, id Identity, tenant string) string {
	t.Helper()
	hum, err := h.Admit(context.Background(), id, tenant, AdmitPolicy{}, time.Now().UTC())
	if err != nil {
		t.Fatalf("admit %s: %v", id.Provider, err)
	}
	return hum
}

// A link sign-in (LinkTo = HUM-x) at Google whose verified address is a
// PENDING address of HUM-x lands on HUM-x, and the address turns active; the
// main address stays.
func TestSignInEmailPendingLinksProviderSignIn(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h, e := s.(Humans), s.(SignInEmails)
		t.Run(name, func(t *testing.T) {
			main, gmail := uid("main-")+"@example.com", uid("second-")+"@example.org"
			x := admitOK(t, h, Identity{Provider: ProviderNative, Subject: main, Email: main}, "")
			if st, err := e.AddPendingEmail(ctx, x, gmail, "t-1", "HUM-1", now); err != nil || st != EmailPending {
				t.Fatalf("add: %q %v", st, err)
			}
			if got := emailsOf(t, e, x)[gmail]; got.State != EmailPending || len(got.Providers) != 0 {
				t.Fatalf("before the sign-in: %+v", got)
			}
			g := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: gmail, LinkTo: x}, "")
			if g != x {
				t.Fatalf("google sign-in of a pending address landed on %q, want %q", g, x)
			}
			got := emailsOf(t, e, x)
			if got[gmail].State != EmailActive || len(got[gmail].Providers) != 1 || got[gmail].Providers[0] != "google" {
				t.Fatalf("after the sign-in: %+v", got[gmail])
			}
			if !got[main].Main || got[gmail].Main {
				t.Fatalf("main address moved: %+v", got)
			}
			// The pending row is gone: adding it again answers active.
			if st, err := e.AddPendingEmail(ctx, x, gmail, "t-1", "HUM-1", now); err != nil || st != EmailActive {
				t.Fatalf("re-add after activation: %q %v", st, err)
			}
			// CONTROL: an address nobody added mints its own human.
			other := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: uid("stranger-") + "@example.org"}, "")
			if other == x {
				t.Fatal("an address with no pending row linked onto the member")
			}
		})
	}
}

// Security: a pending address never links a native password sign-in, and
// never an identity whose provider asserted no address.
func TestSignInEmailPendingNeverLinksPassword(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h, e := s.(Humans), s.(SignInEmails)
		t.Run(name, func(t *testing.T) {
			main, extra := uid("main-")+"@example.com", uid("extra-")+"@example.org"
			x := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: main}, "")
			if _, err := e.AddPendingEmail(ctx, x, extra, "t-1", "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			pw := admitOK(t, h, Identity{Provider: ProviderNative, Subject: extra, Email: extra, LinkTo: x}, "")
			if pw == x {
				t.Fatal("a password sign-in activated a pending address")
			}
			anon := admitOK(t, h, Identity{Provider: "facebook", Subject: uid("f-")}, "")
			if anon == x {
				t.Fatal("an identity with no asserted address linked")
			}
			if got := emailsOf(t, e, x)[extra]; got.State != EmailPending {
				t.Fatalf("the pending address changed state: %+v", got)
			}
		})
	}
}

// 409 on another human's active or pending address; idempotent on one's own.
func TestSignInEmailAddCollision(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h, e := s.(Humans), s.(SignInEmails)
		t.Run(name, func(t *testing.T) {
			ya := uid("y-") + "@example.com"
			x := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: uid("x-") + "@example.com"}, "")
			y := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: ya}, "")
			if _, err := e.AddPendingEmail(ctx, x, ya, "t-1", "HUM-1", now); !errors.Is(err, ErrEmailTaken) {
				t.Fatalf("another human's active address: %v, want ErrEmailTaken", err)
			}
			yp := uid("yp-") + "@example.org"
			if _, err := e.AddPendingEmail(ctx, y, yp, "t-1", "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if _, err := e.AddPendingEmail(ctx, x, yp, "t-1", "HUM-1", now); !errors.Is(err, ErrEmailTaken) {
				t.Fatalf("another human's pending address: %v, want ErrEmailTaken", err)
			}
			if st, err := e.AddPendingEmail(ctx, y, yp, "t-1", "HUM-1", now); err != nil || st != EmailPending {
				t.Fatalf("own pending again: %q %v", st, err)
			}
			if st, err := e.AddPendingEmail(ctx, y, ya, "t-1", "HUM-1", now); err != nil || st != EmailActive {
				t.Fatalf("own active: %q %v", st, err)
			}
			// CONTROL: a free address is added.
			if st, err := e.AddPendingEmail(ctx, x, uid("free-")+"@example.org", "t-1", "HUM-1", now); err != nil || st != EmailPending {
				t.Fatalf("free address: %q %v", st, err)
			}
		})
	}
}

// Remove: a pending or extra address goes; the main address and the last
// identity that can sign in stay.
func TestSignInEmailRemove(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h, e := s.(Humans), s.(SignInEmails)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			main := uid("prov-") + "@example.com"
			// An operator-provisioned member: its main address is an operator
			// identity, which cannot sign in itself.
			x, _, err := s.(MemberProvisioner).ProvisionMember(ctx, ProvisionInput{Tenant: tid, Email: main, Role: RoleTenantOwner}, now)
			if err != nil {
				t.Fatal(err)
			}
			only := uid("only-") + "@example.org"
			if _, err := e.AddPendingEmail(ctx, x, only, tid, "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if g := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: only, LinkTo: x}, ""); g != x {
				t.Fatalf("activation landed on %q", g)
			}
			if err := e.RemoveSignInEmail(ctx, x, only); !errors.Is(err, ErrLastSignIn) {
				t.Fatalf("remove the last sign-in: %v, want ErrLastSignIn", err)
			}
			if err := e.RemoveSignInEmail(ctx, x, main); !errors.Is(err, ErrMainEmail) {
				t.Fatalf("remove the main address: %v, want ErrMainEmail", err)
			}
			// A second way in: now the first is an extra one and goes.
			second := uid("second-") + "@example.org"
			if _, err := e.AddPendingEmail(ctx, x, second, tid, "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			admitOK(t, h, Identity{Provider: "linkedin", Subject: uid("l-"), Email: second, LinkTo: x}, "")
			if err := e.RemoveSignInEmail(ctx, x, only); err != nil {
				t.Fatalf("remove an extra address: %v", err)
			}
			if _, ok := emailsOf(t, e, x)[only]; ok {
				t.Fatal("removed address still listed")
			}
			// Removed means removed: that address now mints its own human.
			if g := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: only}, ""); g == x {
				t.Fatal("a removed address still links")
			}
			pend := uid("pend-") + "@example.org"
			if _, err := e.AddPendingEmail(ctx, x, pend, tid, "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if err := e.RemoveSignInEmail(ctx, x, pend); err != nil {
				t.Fatalf("remove a pending address: %v", err)
			}
			if err := e.RemoveSignInEmail(ctx, x, pend); !errors.Is(err, ErrNotFound) {
				t.Fatalf("remove it twice: %v, want ErrNotFound", err)
			}
		})
	}
}

// An invite to an ACTIVE secondary address admits the human signing in with
// its main identity; an invite to a PENDING one does not.
func TestSignInEmailInviteMatchesActiveOnly(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h, e := s.(Humans), s.(SignInEmails)
		t.Run(name, func(t *testing.T) {
			main, active, pend := uid("main-")+"@example.com", uid("act-")+"@example.org", uid("pend-")+"@example.org"
			mainID := Identity{Provider: ProviderNative, Subject: main, Email: main}
			x := admitOK(t, h, mainID, "")
			if _, err := e.AddPendingEmail(ctx, x, active, "t-1", "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: active, LinkTo: x}, "")
			if _, err := e.AddPendingEmail(ctx, x, pend, "t-1", "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			invite := func(tid, to string) {
				if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: to, Role: rbac.Developer, InvitedBy: AdmittedOperator,
					ExpiresAt: now.Add(time.Hour)}, now); err != nil {
					t.Fatal(err)
				}
			}
			ta := newTenant(t, s)
			invite(ta, active)
			if got, err := h.Admit(ctx, mainID, ta, AdmitPolicy{}, now); err != nil || got != x {
				t.Fatalf("invite to an active secondary address: %q %v, want %q", got, err, x)
			}
			if r, err := h.MemberRole(ctx, x, ta); err != nil || r != rbac.Developer {
				t.Fatalf("membership from the secondary invite: %q %v", r, err)
			}
			tp := newTenant(t, s)
			invite(tp, pend)
			if _, err := h.Admit(ctx, mainID, tp, AdmitPolicy{}, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("invite to a pending address admitted: %v", err)
			}
		})
	}
}

// The squat (c-832 finding, dispatch-f265541a, option A): attacker A parks
// victim@ on A's own account; the victim signs in COLD at Google and gets a
// NEW human, A gains nothing, and an invite to that address lands on the
// victim, not on A. Also: a link sign-in started by ANOTHER human (LinkTo
// = someone else) does not activate it. CONTROL: the holder's own link
// sign-in does (the old cold rule landed the victim on A, which this
// test pins as red).
func TestSignInEmailSquatIsRefused(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h, e := s.(Humans), s.(SignInEmails)
		t.Run(name, func(t *testing.T) {
			a := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: uid("attacker-") + "@example.com"}, "")
			victim := uid("victim-") + "@example.org"
			if _, err := e.AddPendingEmail(ctx, a, victim, "t-1", a, now); err != nil {
				t.Fatal(err)
			}
			tid := newTenant(t, s)
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: victim, Role: rbac.Developer, InvitedBy: AdmittedOperator,
				ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			vid := Identity{Provider: "google", Subject: uid("g-"), Email: victim}
			v, err := h.Admit(ctx, vid, tid, AdmitPolicy{}, now)
			if err != nil || v == a {
				t.Fatalf("cold sign-in of a squatted address: %q %v, attacker %q", v, err, a)
			}
			if r, err := h.MemberRole(ctx, v, tid); err != nil || r != rbac.Developer {
				t.Fatalf("the invite did not land on the victim: %q %v", r, err)
			}
			if _, err := h.MemberRole(ctx, a, tid); err == nil {
				t.Fatal("the attacker gained the victim's workspace")
			}
			if got := emailsOf(t, e, a)[victim]; got.State != EmailPending {
				t.Fatalf("the squatted address changed state on the attacker: %+v", got)
			}
			// Someone else's link does not activate it either.
			p := uid("p-") + "@example.org"
			if _, err := e.AddPendingEmail(ctx, a, p, "t-1", a, now); err != nil {
				t.Fatal(err)
			}
			if g := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: p, LinkTo: v}, ""); g == a || g == v {
				t.Fatalf("a link started by another human linked: %q", g)
			}
			// CONTROL: the holder's own link sign-in activates.
			q := uid("q-") + "@example.org"
			if _, err := e.AddPendingEmail(ctx, a, q, "t-1", a, now); err != nil {
				t.Fatal(err)
			}
			if g := admitOK(t, h, Identity{Provider: "google", Subject: uid("g-"), Email: q, LinkTo: a}, ""); g != a {
				t.Fatalf("CONTROL holder's link sign-in: %q, want %q", g, a)
			}
		})
	}
}
