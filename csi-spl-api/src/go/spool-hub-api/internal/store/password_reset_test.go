package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-1635: the operator resets a forgotten native password (the local hub
// has no mail for the reset link). The new password works, the old one fails,
// every session issued before the reset is cut off, and a reset that cannot
// apply (no credential, the human is in another tenant) changes nothing.
// Memory always; Postgres (incl. the hash) with a DSN.
func TestResetNativePassword(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)
	const oldPW, newPW = "the-old-forgotten-pass", "the-new-chosen-pass"
	weak := auth.Argon2Params{MemoryKiB: 64, Iterations: 1}
	oldHash, err := auth.HashPassword(oldPW, weak)
	if err != nil {
		t.Fatal(err)
	}
	newHash, err := auth.HashPassword(newPW, weak)
	if err != nil {
		t.Fatal(err)
	}
	for drv, s := range drivers(t) {
		r, ok := s.(PasswordResetter)
		if !ok {
			t.Fatalf("%s: store is not a PasswordResetter", drv)
		}
		rev := s.(auth.SessionRevoker)
		t.Run(drv, func(t *testing.T) {
			tid := newTenant(t, s)
			email := uid("owner-") + "@example.com"

			// No owner seated yet: no credential, nothing to reset.
			if _, err := r.ResetNativePassword(ctx, tid, email, newHash, now); !errors.Is(err, auth.ErrCredNotFound) {
				t.Fatalf("reset with no credential: %v, want ErrCredNotFound", err)
			}

			hum, _, err := s.(MemberProvisioner).ProvisionMember(ctx, ProvisionInput{Tenant: tid, Email: email,
				Role: RoleTenantOwner, PasswordHash: oldHash}, now.Add(-time.Hour))
			if err != nil {
				t.Fatal(err)
			}

			// Scoped to another tenant: refused, no cut-off written.
			other := newTenant(t, s)
			if _, err := r.ResetNativePassword(ctx, other, email, newHash, now); !errors.Is(err, ErrNotTenantMember) {
				t.Fatalf("reset scoped to another tenant: %v, want ErrNotTenantMember", err)
			}
			if cut, _ := rev.SessionRevocations(ctx, time.Time{}); !cut[hum].IsZero() {
				t.Fatalf("a refused reset revoked sessions: %v", cut[hum])
			}

			got, err := r.ResetNativePassword(ctx, tid, " "+email+" ", newHash, now)
			if err != nil || got != hum {
				t.Fatalf("reset: hum=%q err=%v, want %s", got, err, hum)
			}
			cut, err := rev.SessionRevocations(ctx, time.Time{})
			if err != nil || !cut[hum].Equal(now) {
				t.Fatalf("cut-off = %v %v, want %v (every earlier session dead)", cut[hum], err, now)
			}

			if drv == "postgres" {
				cs := auth.PgCredStore{Pool: s.(*Postgres).Pool()}
				cred, err := cs.GetCredential(ctx, email)
				if err != nil {
					t.Fatal(err)
				}
				if err := auth.VerifyPassword(cred.PasswordHash, newPW); err != nil {
					t.Fatalf("the new password must verify: %v", err)
				}
				if err := auth.VerifyPassword(cred.PasswordHash, oldPW); !errors.Is(err, auth.ErrPasswordMismatch) {
					t.Fatalf("the old password must fail: %v", err)
				}
			}
		})
	}
}
