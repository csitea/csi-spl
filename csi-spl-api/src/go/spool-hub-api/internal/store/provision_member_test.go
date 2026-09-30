package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// CLE-77781 (owner niba-consult): an operator seats a member by email for a
// person who has NEVER signed in ("added, not invited"). ProvisionMember must
// list them at once, accept a pending invite, and — the point — make a later
// real sign-in with the same verified address LINK to the SAME human, not mint
// a second. With a password the member also gets a native credential (email
// pre-verified, no mail). Memory always; Postgres (incl. the credential) with a DSN.
func TestProvisionMember(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 9, 30, 16, 0, 0, 0, time.UTC)
	const email = "office@nibaconsult.example"
	const name = "Raya Simeonova"
	pwHash, err := auth.HashPassword("a-chosen-pass", auth.Argon2Params{MemoryKiB: 64, Iterations: 1})
	if err != nil {
		t.Fatal(err)
	}
	for drv, s := range drivers(t) {
		h := s.(Humans)
		mp, ok := s.(MemberProvisioner)
		if !ok {
			t.Fatalf("%s: store is not a MemberProvisioner", drv)
		}
		t.Run(drv, func(t *testing.T) {
			tid := newTenant(t, s)
			// A pending invite exists (the owner had created one); provisioning
			// accepts it so it never lingers as a dangling invite.
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: email, Role: RoleTenantOwner,
				InvitedBy: AdmittedOperator, ExpiresAt: now.Add(48 * time.Hour)}, now); err != nil {
				t.Fatal(err)
			}

			in := ProvisionInput{Tenant: tid, Email: email, DisplayName: name, Role: RoleTenantOwner,
				OrderedBy: "HUM-10", PasswordHash: pwHash}
			hum, created, err := mp.ProvisionMember(ctx, in, now)
			if err != nil || hum == "" || !created {
				t.Fatalf("provision: hum=%q created=%v err=%v", hum, created, err)
			}
			// Listed now, biz_owner, never signed in.
			if r, err := h.MemberRole(ctx, hum, tid); err != nil || r != RoleTenantOwner {
				t.Fatalf("role = %q %v, want %q", r, err, RoleTenantOwner)
			}
			d := s.(MemberDirectory)
			ms, err := d.ListMembers(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			var seen *Member
			for i := range ms {
				if ms[i].HumanID == hum {
					seen = &ms[i]
				}
			}
			if seen == nil || seen.DisplayName != name {
				t.Fatalf("provisioned member not listed with name: %+v", seen)
			}
			if !seen.LastSeen.IsZero() {
				t.Fatalf("a never-signed-in member should have no last-seen: %v", seen.LastSeen)
			}
			// The pending invite is accepted, not dangling.
			ins, err := d.ListInvites(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			for _, iv := range ins {
				if iv.Email == email {
					t.Fatalf("invite for %s still pending after provisioning", email)
				}
			}

			// THE POINT: a Google sign-in with the same verified email LINKS to
			// the same human (no second human, no second seat), role kept.
			g := Identity{Provider: "google", Subject: uid("g-"), Email: email}
			ghum, err := h.Admit(ctx, g, tid, AdmitPolicy{}, now.Add(time.Hour))
			if err != nil || ghum != hum {
				t.Fatalf("google sign-in should link to %s, got %q %v", hum, ghum, err)
			}
			if n, err := s.CountMembers(ctx, tid); err != nil || n != 1 {
				t.Fatalf("members = %d %v, want 1 (no duplicate)", n, err)
			}

			// Idempotent: a re-run seats nothing new.
			hum2, created2, err := mp.ProvisionMember(ctx, in, now.Add(2*time.Hour))
			if err != nil || hum2 != hum || created2 {
				t.Fatalf("re-run: hum=%q created=%v err=%v (want same human, created=false)", hum2, created2, err)
			}
			if n, _ := s.CountMembers(ctx, tid); n != 1 {
				t.Fatalf("re-run added a member: %d", n)
			}

			// Postgres carries the native credential: the chosen password
			// verifies (native login would succeed), a wrong one does not.
			if drv == "postgres" {
				cs := auth.PgCredStore{Pool: s.(*Postgres).Pool()}
				cred, err := cs.GetCredential(ctx, email)
				if err != nil {
					t.Fatalf("credential not created: %v", err)
				}
				if cred.EmailVerifiedAt == nil {
					t.Fatal("credential must be pre-verified (no verification mail)")
				}
				if err := auth.VerifyPassword(cred.PasswordHash, "a-chosen-pass"); err != nil {
					t.Fatalf("chosen password should verify: %v", err)
				}
				if err := auth.VerifyPassword(cred.PasswordHash, "wrong-pass"); !errors.Is(err, auth.ErrPasswordMismatch) {
					t.Fatalf("wrong password must fail: %v", err)
				}
			}
		})
	}
}
