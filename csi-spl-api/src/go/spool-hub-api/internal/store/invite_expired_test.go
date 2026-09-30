package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-1229 (CLE-77781): a pending invite that has lapsed refuses the sign-in
// with ErrInviteExpired — told apart from ErrNotAdmitted (a stranger with no
// invite) so the login page can say "ask for a fresh invite" instead of the
// blank not_allowed both used to share. Memory always, Postgres with a DSN.
func TestAdmitInviteExpired(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 9, 30, 5, 0, 0, 0, time.UTC)
	boot := AdmitPolicy{BootstrapOwner: true}
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			// A bootstrap owner so the tenant is not empty: the invitee below
			// cannot fall through to bootstrap and mask the expiry.
			owner := Identity{Provider: "google", Subject: uid("o-"), Email: "owner@example.com"}
			o, err := h.Admit(ctx, owner, tid, boot, now)
			if err != nil {
				t.Fatal(err)
			}

			// An invite that expires an hour from now, then a sign-in two hours
			// later: the invite has lapsed.
			lapsed := "lapsed@example.com"
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: lapsed, InvitedBy: o, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			later := now.Add(2 * time.Hour)
			who := Identity{Provider: "google", Subject: uid("l-"), Email: lapsed}
			if _, err := h.Admit(ctx, who, tid, boot, later); !errors.Is(err, ErrInviteExpired) {
				t.Fatalf("expired invite: want ErrInviteExpired, got %v", err)
			}
			// The refusal wrote nothing: the invite stays pending (not accepted),
			// so a re-issued invite still works.
			if n, err := s.CountMembers(ctx, tid); err != nil || n != 1 {
				t.Fatalf("refusal wrote a membership: n=%d err=%v", n, err)
			}

			// CONTROL: a stranger with NO invite is ErrNotAdmitted, not expired.
			stranger := Identity{Provider: "google", Subject: uid("s-"), Email: "stranger@example.com"}
			if _, err := h.Admit(ctx, stranger, tid, boot, later); !errors.Is(err, ErrNotAdmitted) || errors.Is(err, ErrInviteExpired) {
				t.Fatalf("stranger: want ErrNotAdmitted (not expired), got %v", err)
			}

			// CONTROL: a fresh invite for the same address admits — expiry, not
			// the address, was the only bar.
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: lapsed, InvitedBy: o, ExpiresAt: later.Add(time.Hour)}, later); err != nil {
				t.Fatal(err)
			}
			if _, err := h.Admit(ctx, who, tid, boot, later); err != nil {
				t.Fatalf("fresh invite after re-issue: %v", err)
			}
			if n, _ := s.CountMembers(ctx, tid); n != 2 {
				t.Fatalf("re-issued invite did not admit: members=%d", n)
			}

			// The Registrar maps the store's ErrInviteExpired to
			// auth.ErrInviteExpired (auth_error=invite_expired).
			exp := "expiredreg@example.com"
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: exp, InvitedBy: o, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			reg := AuthHooks{H: h, Policy: boot, Now: func() time.Time { return later }}
			if _, err := reg.Register(ctx, auth.Identity{Provider: "google", Subject: uid("r-"), Email: exp}, tid); !errors.Is(err, auth.ErrInviteExpired) {
				t.Fatalf("registrar over an expired invite: want auth.ErrInviteExpired, got %v", err)
			}
		})
	}
}
