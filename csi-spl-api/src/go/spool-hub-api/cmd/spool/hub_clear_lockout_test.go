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

// SPL-6182 defect 5: `spool hub-clear-lockout` refuses a missing email or DSN.
func TestHubClearLockoutRefusals(t *testing.T) {
	for _, args := range [][]string{{"--db", "postgres://x"}, {"--email", "not-an-address", "--db", "postgres://x"}} {
		t.Setenv("SPOOL_HUB_DB_DSN", "")
		rc, out, errOut := captureRun(t, append([]string{"hub-clear-lockout"}, args...))
		if rc != 1 || !strings.Contains(errOut, "--email") || strings.Contains(out, "cleared") {
			t.Fatalf("%v: rc %d out %q err %q", args, rc, out, errOut)
		}
	}
	t.Setenv("SPOOL_HUB_DB_DSN", "")
	if rc, _, errOut := captureRun(t, []string{"hub-clear-lockout", "--email", "o@example.com"}); rc != 1 || !strings.Contains(errOut, "--db") {
		t.Fatalf("no DSN: rc %d err %q", rc, errOut)
	}
}

// With SPOOL_TEST_PG_DSN: the clear drops the address's counted failures
// from every client address, leaves another address's, and the verdict
// carries the count, never the email.
func TestHubClearLockoutPostgres(t *testing.T) {
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
	email, other := fmt.Sprintf("locked-%d@example.com", stamp), fmt.Sprintf("free-%d@example.com", stamp)
	cs := auth.PgCredStore{Pool: pg.Pool()}
	now := time.Now().UTC()
	for i, s := range []string{email, email, email, other} {
		if ok, err := cs.ClaimLoginAttempt(ctx, s, fmt.Sprintf("198.51.100.%d", i), now, now.Add(-time.Hour), 100, 100); err != nil || !ok {
			t.Fatal(err)
		}
	}
	rc, out, errOut := captureRun(t, []string{"hub-clear-lockout", "--email", strings.ToUpper(email), "--db", dsn})
	if rc != 0 || !strings.Contains(out, `"cleared":3`) || strings.Contains(out, email) {
		t.Fatalf("rc %d out %q err %q", rc, out, errOut)
	}
	if _, all, err := cs.LoginFailures(ctx, email, "x", now.Add(-time.Hour)); err != nil || all != 0 {
		t.Fatalf("left %d %v", all, err)
	}
	if _, all, err := cs.LoginFailures(ctx, other, "x", now.Add(-time.Hour)); err != nil || all != 1 {
		t.Fatalf("CONTROL: another address: %d %v", all, err)
	}
}
