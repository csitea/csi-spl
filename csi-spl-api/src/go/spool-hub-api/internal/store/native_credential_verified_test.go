package store

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-6182 defects 1 and 2: the address already holds an UNVERIFIED native
// credential (a self-service register whose mail was never completed), then
// the operator seats the person with a password. The seat must leave a
// verified credential that takes the operator's password. Postgres only: the
// memory store keeps no credentials table.
func TestProvisionMemberOverUnverifiedCredential(t *testing.T) {
	ctx := context.Background()
	then := time.Date(2026, 10, 7, 9, 0, 0, 0, time.UTC)
	now := then.Add(45 * 24 * time.Hour)
	weak := auth.Argon2Params{MemoryKiB: 64, Iterations: 1}
	oldHash, _ := auth.HashPassword("the-register-pass", weak)
	newHash, _ := auth.HashPassword("the-operator-pass", weak)
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("needs SPOOL_TEST_PG_DSN")
	}
	cs := auth.PgCredStore{Pool: pg.Pool()}
	tid := newTenant(t, pg)
	email := uid("member-") + "@example.com"
	if created, err := cs.CreateCredential(ctx, auth.Credential{Subject: email, PasswordHash: oldHash}, then); err != nil || !created {
		t.Fatalf("register: created=%v err=%v", created, err)
	}
	_, _, err := pg.ProvisionMember(ctx, ProvisionInput{Tenant: tid, Email: email, DisplayName: "FirstName LastName",
		Role: RoleTenantOwner, PasswordHash: newHash}, now)
	if err != nil {
		t.Fatal(err)
	}
	cred, err := cs.GetCredential(ctx, email)
	if err != nil {
		t.Fatal(err)
	}
	if !cred.Verified() {
		t.Errorf("defect 1: the seated credential is still unverified (email_verified_at NULL)")
	}
	if auth.VerifyPassword(cred.PasswordHash, "the-operator-pass") != nil {
		t.Errorf("defect 2: the operator's password was not written (the register hash is still there)")
	}
}

// SPL-6182 defect 3: the operator reset of an unverified credential must
// leave it verified, or the person is still bounced to email confirmation.
func TestResetNativePasswordVerifies(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	weak := auth.Argon2Params{MemoryKiB: 64, Iterations: 1}
	regHash, _ := auth.HashPassword("the-register-pass", weak)
	newHash, _ := auth.HashPassword("the-reset-pass", weak)
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("needs SPOOL_TEST_PG_DSN")
	}
	cs := auth.PgCredStore{Pool: pg.Pool()}
	tid := newTenant(t, pg)
	email := uid("member-") + "@example.com"
	if _, _, err := pg.ProvisionMember(ctx, ProvisionInput{Tenant: tid, Email: email, Role: RoleTenantOwner,
		PasswordHash: regHash}, now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	// The precondition the prd row had: the credential is unverified.
	if _, err := pg.Pool().Exec(ctx, `UPDATE password_credentials SET email_verified_at = NULL
		WHERE provider = 'password' AND subject = $1`, email); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.ResetNativePassword(ctx, tid, email, newHash, now); err != nil {
		t.Fatal(err)
	}
	cred, err := cs.GetCredential(ctx, email)
	if err != nil {
		t.Fatal(err)
	}
	if !cred.Verified() {
		t.Errorf("defect 3: the operator reset left the credential unverified")
	}
}
