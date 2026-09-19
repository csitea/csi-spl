package store

import (
	"context"
	"errors"
	"regexp"
	"testing"
	"time"
)

// 010 T012/T013, FR-012: registration is idempotent on (provider, subject),
// admission is member | invite | bootstrap, a refusal writes nothing.
func TestHumansAdmitAndMembership(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	boot := AdmitPolicy{BootstrapOwner: true}
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			alice := Identity{Provider: "google", Subject: uid("sub-"), Email: "Alice@Example.com", Name: "FirstName LastName"}

			// No tenant: registered, not a member of anything.
			a, err := h.Admit(ctx, alice, "", AdmitPolicy{}, now)
			if err != nil || !regexp.MustCompile(`^HUM-[0-9]+$`).MatchString(a) {
				t.Fatalf("first callback: %q %v", a, err)
			}
			if again, err := h.Admit(ctx, alice, "", AdmitPolicy{}, now); err != nil || again != a {
				t.Fatalf("idempotent on provider+subject: %q vs %q %v", again, a, err)
			}
			if _, err := h.MemberRole(ctx, a, tid); !errors.Is(err, ErrNotFound) {
				t.Fatalf("registered is not a member: %v", err)
			}
			// Without bootstrap and without an invite: refused.
			if _, err := h.Admit(ctx, alice, tid, AdmitPolicy{}, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("no bootstrap, no invite: %v", err)
			}
			// Bootstrap: first human on a zero-member tenant is owner.
			if got, err := h.Admit(ctx, alice, tid, boot, now); err != nil || got != a {
				t.Fatalf("bootstrap: %q %v", got, err)
			}
			if r, err := h.MemberRole(ctx, a, tid); err != nil || r != RoleOwner {
				t.Fatalf("bootstrap role: %q %v", r, err)
			}

			// A second human, bootstrap on: refused (tenant has a member), and
			// the refusal writes nothing: a later admit mints a NEW id only then.
			bob := Identity{Provider: "facebook", Subject: uid("fb-"), Email: "bob@example.com"}
			if _, err := h.Admit(ctx, bob, tid, boot, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("second human without invite: %v", err)
			}
			// Invite for another address does not admit bob; an expired one neither.
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: "other@example.com", InvitedBy: a, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: "BOB@example.com", InvitedBy: a, ExpiresAt: now.Add(-time.Second)}, now); err != nil {
				t.Fatal(err)
			}
			if _, err := h.Admit(ctx, bob, tid, boot, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("expired invite admitted: %v", err)
			}
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: "bob@example.com", InvitedBy: a, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			b, err := h.Admit(ctx, bob, tid, AdmitPolicy{}, now)
			if err != nil || b == a {
				t.Fatalf("invited bob: %q %v", b, err)
			}
			if r, _ := h.MemberRole(ctx, b, tid); r != RoleMember {
				t.Fatalf("invite role: %q", r)
			}
			// The invite is single use: a third identity with bob's email is refused.
			bob2 := Identity{Provider: "password", Subject: "bob@example.com", Email: "bob@example.com"}
			if _, err := h.Admit(ctx, bob2, tid, AdmitPolicy{}, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("invite re-used: %v", err)
			}
			// Membership is per tenant.
			other := newTenant(t, s)
			if _, err := h.MemberRole(ctx, a, other); !errors.Is(err, ErrNotFound) {
				t.Fatalf("owner of %s is not a member of %s: %v", tid, other, err)
			}
			// Unknown tenant: refused; invite for it: ErrNotFound.
			if _, err := h.Admit(ctx, alice, "t-nosuch", boot, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("unknown tenant: %v", err)
			}
			if err := h.PutInvite(ctx, Invite{TenantID: "t-nosuch", Email: "x@example.com", InvitedBy: AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("invite to unknown tenant: %v", err)
			}
			// A disabled human has no role and cannot sign in.
			s.(interface{ disableHuman(string) }).disableHuman(b)
			if _, err := h.MemberRole(ctx, b, tid); !errors.Is(err, ErrNotFound) {
				t.Fatalf("disabled human still a member: %v", err)
			}
			if _, err := h.Admit(ctx, bob, "", AdmitPolicy{}, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("disabled human signed in: %v", err)
			}
			// Unlink (Meta data deletion): the next callback is a new human. Idempotent.
			if err := h.UnlinkIdentity(ctx, "google", alice.Subject); err != nil {
				t.Fatal(err)
			}
			if err := h.UnlinkIdentity(ctx, "google", alice.Subject); err != nil {
				t.Fatal(err)
			}
			if n, err := h.Admit(ctx, alice, "", AdmitPolicy{}, now); err != nil || n == a {
				t.Fatalf("after unlink: %q (was %q) %v", n, a, err)
			}
			// Bad identities are refused before any write.
			if _, err := h.Admit(ctx, Identity{Provider: "Google", Subject: "x"}, "", AdmitPolicy{}, now); err == nil {
				t.Fatal("upper-case provider accepted")
			}
			if _, err := h.Admit(ctx, Identity{Provider: "google"}, "", AdmitPolicy{}, now); err == nil {
				t.Fatal("empty subject accepted")
			}
		})
	}
}

// Two concurrent first sign-ins of a fresh tenant: exactly one owner.
func TestHumansBootstrapIsSingleOwner(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			errs := make(chan error, 8)
			for i := 0; i < 8; i++ {
				go func() {
					_, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("c-")}, tid, AdmitPolicy{BootstrapOwner: true}, time.Now())
					errs <- err
				}()
			}
			ok := 0
			for i := 0; i < 8; i++ {
				if err := <-errs; err == nil {
					ok++
				} else if !errors.Is(err, ErrNotAdmitted) {
					t.Fatal(err)
				}
			}
			if ok != 1 {
				t.Fatalf("owners admitted by bootstrap = %d, want 1", ok)
			}
		})
	}
}
