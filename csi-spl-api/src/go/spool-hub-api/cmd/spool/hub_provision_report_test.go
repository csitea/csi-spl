package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-6182 defect 2 (R7 W1): `spool hub-provision-member` says what the
// transaction changed, never what was asked. With SPOOL_TEST_PG_DSN:
//   - an address holding an unverified register credential: member_added,
//     credential=replaced, email_verified_now, sessions_revoked, and the
//     human's session_revocations row is written;
//   - a second seat of the same member (store.ProvisionMemberReport):
//     MemberAdded false, CredReplaced, VerifiedNow false;
//   - CONTROL, a fresh address: credential=created, sessions_revoked false,
//     no session_revocations row.
func TestHubProvisionMemberReportsWhatChanged(t *testing.T) {
	dsn, sqlDir := os.Getenv("SPOOL_TEST_PG_DSN"), os.Getenv("SPOOL_TEST_SQL_DIR")
	if dsn == "" || sqlDir == "" {
		t.Skip("SPOOL_TEST_PG_DSN / SPOOL_TEST_SQL_DIR not set")
	}
	ctx := context.Background()
	pg, err := store.OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pg.Close()
	if _, err := store.Migrate(ctx, pg.Pool(), sqlDir); err != nil {
		t.Fatal(err)
	}
	stamp := time.Now().UnixNano()
	tid := fmt.Sprintf("t-prov-%d", stamp)
	if err := pg.CreateTenant(ctx, store.Tenant{ID: tid, RootPubKey: make([]byte, 32)}); err != nil {
		t.Fatal(err)
	}
	weak := auth.Argon2Params{MemoryKiB: 64, Iterations: 1}
	regHash, _ := auth.HashPassword("the-register-pass", weak)
	before := time.Now().UTC().Add(-time.Hour)
	email := fmt.Sprintf("seat-%d@example.com", stamp)
	if _, err := (auth.PgCredStore{Pool: pg.Pool()}).CreateCredential(ctx, auth.Credential{Subject: email, PasswordHash: regHash}, before); err != nil {
		t.Fatal(err)
	}
	seat := func(addr, pw string) map[string]any {
		t.Helper()
		var rc int
		var out, errOut string
		withStdin(t, pw+"\n", func() {
			rc, out, errOut = captureRun(t, []string{"hub-provision-member", "--tenant", tid, "--email", addr,
				"--role", store.RoleTenantOwner, "--name", "FirstName LastName", "--password-stdin", "--db", dsn})
		})
		var v map[string]any
		if rc != 0 || json.Unmarshal([]byte(out), &v) != nil {
			t.Fatalf("rc %d out %q err %q", rc, out, errOut)
		}
		return v
	}
	v := seat(email, "the-operator-pass")
	for k, want := range map[string]any{"member_added": true, "credential": store.CredReplaced, "email_verified_now": true, "sessions_revoked": true} {
		if v[k] != want {
			t.Fatalf("over a register credential: %s = %v, want %v (%v)", k, v[k], want, v)
		}
	}
	hum, _ := v["human_id"].(string)
	cut, err := pg.SessionRevocations(ctx, before)
	if err != nil || !cut[hum].After(before) {
		t.Fatalf("a replaced credential wrote no session_revocations row for %s: %v %v", hum, cut, err)
	}
	opHash, _ := auth.HashPassword("a-second-operator-pass", weak)
	res, err := pg.ProvisionMemberReport(ctx, store.ProvisionInput{Tenant: tid, Email: email, Role: store.RoleTenantOwner, PasswordHash: opHash}, time.Now().UTC())
	if err != nil || res.HumanID != hum || res.MemberAdded || res.Credential != store.CredReplaced || res.VerifiedNow {
		t.Fatalf("second seat: %+v %v, want the same human, MemberAdded false, replaced, VerifiedNow false", res, err)
	}
	fresh := fmt.Sprintf("fresh-%d@example.com", stamp)
	v = seat(fresh, "a-fresh-operator-pass")
	if v["member_added"] != true || v["credential"] != store.CredCreated || v["email_verified_now"] != true || v["sessions_revoked"] != false {
		t.Fatalf("CONTROL, a fresh address: %v", v)
	}
	cut, err = pg.SessionRevocations(ctx, before)
	if fh, _ := v["human_id"].(string); err != nil || !cut[fh].IsZero() {
		t.Fatalf("CONTROL: a created credential revoked sessions: %v %v", cut, err)
	}
}
