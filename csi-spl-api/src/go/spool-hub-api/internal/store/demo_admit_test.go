package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/077 T007 (FR-004): the open demo admission. A provider-verified
// Google or Facebook identity signing in to the demo workspace with no invite
// is seated as demo_user, only while the demo is on. Every other path is a
// negative case: each must refuse and write nothing.
func TestHumansOpenDemoAdmission(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			demo, other := newTenant(t, s), newTenant(t, s)
			open := AdmitPolicy{OpenWorkspace: demo, OpenProviders: []string{"google", "facebook"}}
			tag := uid("")
			ident := func(provider, local string) Identity {
				return Identity{Provider: provider, Subject: uid(local + "-"), Email: local + "-" + tag + "@example.com"}
			}
			role := func(hum, tenant string) string {
				t.Helper()
				r, err := h.MemberRole(ctx, hum, tenant)
				if errors.Is(err, ErrNotFound) {
					return ""
				}
				if err != nil {
					t.Fatal(err)
				}
				return r
			}
			refused := func(what string, id Identity, tenant string, p AdmitPolicy) {
				t.Helper()
				if hum, err := h.Admit(ctx, id, tenant, p, now); !errors.Is(err, ErrNotAdmitted) {
					t.Fatalf("%s: admitted %q, err %v; want ErrNotAdmitted", what, hum, err)
				}
			}

			// The open door: Google and Facebook, verified, no invite.
			g := ident("google", "visitor-g")
			hg, err := h.Admit(ctx, g, demo, open, now)
			if err != nil || role(hg, demo) != rbac.DemoUser {
				t.Fatalf("google visitor: %q %v role %q", hg, err, role(hg, demo))
			}
			if again, err := h.Admit(ctx, g, demo, open, now); err != nil || again != hg || role(hg, demo) != rbac.DemoUser {
				t.Fatalf("re-login: %q %v", again, err)
			}
			fb := ident("facebook", "visitor-f")
			if hf, err := h.Admit(ctx, fb, demo, open, now); err != nil || role(hf, demo) != rbac.DemoUser {
				t.Fatalf("facebook visitor: %q %v", hf, err)
			}

			// Negative: the flag off (no OpenWorkspace), even with providers listed.
			refused("flag off", ident("google", "off"), demo, AdmitPolicy{OpenProviders: open.OpenProviders})
			// Negative: a password identity, and an operator one, never.
			refused("password identity", ident(ProviderNative, "pw"), demo, open)
			refused("operator identity", ident(ProviderOperator, "op"), demo, open)
			// Negative: an unverified address (the store sees Email "" then).
			unverified := ident("google", "unverified")
			unverified.Email = ""
			refused("unverified email", unverified, demo, open)
			// Negative: a federated provider not in the list.
			refused("provider not listed", ident("microsoft", "ms"), demo, open)
			refused("facebook unlisted", ident("facebook", "fb2"), demo,
				AdmitPolicy{OpenWorkspace: demo, OpenProviders: []string{"google"}})
			// Negative: another tenant: the open rule never applies outside demo.
			refused("another tenant", ident("google", "elsewhere"), other, open)

			// Negative: a real member of another workspace is not seated as a
			// visitor (the demo has no real members; its end wipes visitor data).
			member := ident("google", "real")
			hr, err := h.Admit(ctx, member, other, AdmitPolicy{BootstrapOwner: true}, now)
			if err != nil || role(hr, other) != RoleTenantOwner {
				t.Fatalf("real member: %q %v", hr, err)
			}
			refused("existing real member", member, demo, open)
			if r := role(hr, demo); r != "" {
				t.Fatalf("refusal wrote a demo membership: %q", r)
			}

			// An invite to the demo workspace wins over the open rule, and an
			// existing real member of it keeps that role on every sign-in.
			staff := ident("google", "staff")
			if err := h.PutInvite(ctx, Invite{TenantID: demo, Email: staff.Email, Role: rbac.Admin,
				InvitedBy: AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			hs, err := h.Admit(ctx, staff, demo, open, now)
			if err != nil || role(hs, demo) != rbac.Admin {
				t.Fatalf("invited staff: %q %v role %q", hs, err, role(hs, demo))
			}
			if _, err := h.Admit(ctx, staff, demo, open, now); err != nil || role(hs, demo) != rbac.Admin {
				t.Fatalf("real member of demo demoted on re-login: %v role %q", err, role(hs, demo))
			}
		})
	}
}

// Bootstrap never seats an owner in the open demo workspace: the first
// visitor of an empty demo is a demo_user, and a password identity that the
// bootstrap rule would have made owner is refused.
func TestHumansOpenDemoNeverBootstraps(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			demo := newTenant(t, s)
			p := AdmitPolicy{BootstrapOwner: true, OpenWorkspace: demo, OpenProviders: []string{"google", "facebook"}}
			tag := uid("")
			pw := Identity{Provider: ProviderNative, Subject: "pw-" + tag + "@example.com", Email: "pw-" + tag + "@example.com"}
			if hum, err := h.Admit(ctx, pw, demo, p, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("password identity bootstrapped the demo: %q %v", hum, err)
			}
			g := Identity{Provider: "google", Subject: uid("boot-"), Email: "boot-" + tag + "@example.com"}
			hum, err := h.Admit(ctx, g, demo, p, now)
			if err != nil {
				t.Fatal(err)
			}
			if r, err := h.MemberRole(ctx, hum, demo); err != nil || r != rbac.DemoUser {
				t.Fatalf("first visitor of an empty demo: role %q %v, want demo_user", r, err)
			}
		})
	}
}
