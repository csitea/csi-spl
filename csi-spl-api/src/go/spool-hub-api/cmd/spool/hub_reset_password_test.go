package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// withStdin runs f with os.Stdin reading s.
func withStdin(t *testing.T, s string, f func()) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	w.WriteString(s) //nolint:errcheck
	w.Close()
	old := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = old }()
	f()
}

// SPL-1635: `spool hub-reset-password` takes the new password on STDIN only
// and refuses what it cannot apply, exit 1, nothing changed.
func TestHubResetPasswordRefusals(t *testing.T) {
	cases := []struct {
		name, stdin, want string
		args              []string
	}{
		{"no --password-stdin", "a-new-pass-123\n", "--password-stdin", []string{"--email", "o@example.com", "--db", "memory:"}},
		{"no --email", "a-new-pass-123\n", "--email", []string{"--password-stdin", "--db", "memory:"}},
		{"bad --tenant", "a-new-pass-123\n", "--tenant", []string{"--tenant", "Not A Slug", "--email", "o@example.com", "--password-stdin", "--db", "memory:"}},
		{"empty STDIN", "\n", "STDIN was empty", []string{"--email", "o@example.com", "--password-stdin", "--db", "memory:"}},
		{"no credential (no owner seated)", "a-new-pass-123\n", "no password credential for that email", []string{"--email", "o@example.com", "--password-stdin", "--db", "memory:"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var rc int
			var out, errOut string
			withStdin(t, c.stdin, func() {
				rc, out, errOut = captureRun(t, append([]string{"hub-reset-password"}, c.args...))
			})
			if rc != 1 || !strings.Contains(errOut, c.want) || strings.Contains(out, `"status":"reset"`) {
				t.Fatalf("rc %d out %q err %q, want rc 1 naming %q", rc, out, errOut, c.want)
			}
		})
	}
}

// With SPOOL_TEST_PG_DSN: the real path. The new password verifies, the old
// one fails, the human's sessions are cut off at the reset.
func TestHubResetPasswordPostgres(t *testing.T) {
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
	tid := fmt.Sprintf("t-reset-%d", stamp)
	if err := pg.CreateTenant(ctx, store.Tenant{ID: tid, RootPubKey: make([]byte, 32)}); err != nil {
		t.Fatal(err)
	}
	email := fmt.Sprintf("owner-%d@example.com", stamp)
	oldHash, _ := auth.HashPassword("the-old-forgotten-pass", auth.Argon2Params{MemoryKiB: 64, Iterations: 1})
	before := time.Now().UTC().Add(-time.Hour)
	hum, _, err := pg.ProvisionMember(ctx, store.ProvisionInput{Tenant: tid, Email: email,
		Role: store.RoleTenantOwner, PasswordHash: oldHash}, before)
	if err != nil {
		t.Fatal(err)
	}
	var rc int
	var out, errOut string
	withStdin(t, "the-new-chosen-pass\n", func() {
		rc, out, errOut = captureRun(t, []string{"hub-reset-password", "--tenant", tid, "--email", email,
			"--password-stdin", "--db", dsn})
	})
	if rc != 0 || !strings.Contains(out, `"status":"reset"`) || !strings.Contains(out, hum) {
		t.Fatalf("rc %d out %q err %q", rc, out, errOut)
	}
	if strings.Contains(out, "the-new-chosen-pass") || strings.Contains(out, email) {
		t.Fatalf("the verdict carries the password or the email: %q", out)
	}
	cred, err := (auth.PgCredStore{Pool: pg.Pool()}).GetCredential(ctx, email)
	if err != nil {
		t.Fatal(err)
	}
	if auth.VerifyPassword(cred.PasswordHash, "the-new-chosen-pass") != nil {
		t.Fatal("the new password must verify")
	}
	if auth.VerifyPassword(cred.PasswordHash, "the-old-forgotten-pass") == nil {
		t.Fatal("the old password must fail")
	}
	cut, err := pg.SessionRevocations(ctx, before)
	if err != nil || !cut[hum].After(before) {
		t.Fatalf("no session cut-off for %s: %v %v", hum, cut, err)
	}
}
