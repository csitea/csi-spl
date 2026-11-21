package auth_test

import (
	"context"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// credStores yields the memory store always and the Postgres store when
// hub-pg.tst.sh has migrated a database into $SPOOL_TEST_PG_DSN (rdb 0009).
func credStores(t *testing.T) map[string]auth.CredStore {
	t.Helper()
	out := map[string]auth.CredStore{"memory": auth.NewMemoryCredStore()}
	if dsn := os.Getenv("SPOOL_TEST_PG_DSN"); dsn != "" {
		cfg, err := pgxpool.ParseConfig(dsn)
		if err != nil {
			t.Fatal(err)
		}
		pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(pool.Close)
		out["postgres"] = auth.PgCredStore{Pool: pool}
	}
	return out
}

func th(i int) string { return fmt.Sprintf("%064x", i) }

// TestCredStoreContract is one behaviour for both drivers: floors, single
// use, expiry, newest-link-wins, reset consumes every live token.
func TestCredStoreContract(t *testing.T) {
	for name, st := range credStores(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			// Unique subjects so a shared Postgres run never collides.
			sfx := strings.ToLower(fmt.Sprintf("%d", time.Now().UnixNano()))
			subj := "contract-" + sfx + "@example.com"
			now := time.Date(2026, 9, 19, 6, 0, 0, 0, time.UTC)
			h1, h2 := mustHash(t, pwA), mustHash(t, pwB)
			floor := auth.MailFloor{MinInterval: time.Minute, MaxPerDay: 3}

			if _, err := st.GetCredential(ctx, subj); !errors.Is(err, auth.ErrCredNotFound) {
				t.Fatalf("absent: %v", err)
			}
			if ok, err := st.CreateCredential(ctx, auth.Credential{Subject: subj, PasswordHash: h1, Locale: "fi"}, now); !ok || err != nil {
				t.Fatalf("create: %v %v", ok, err)
			}
			if ok, err := st.CreateCredential(ctx, auth.Credential{Subject: subj, PasswordHash: h2, Locale: "sv"}, now); ok || err != nil {
				t.Fatalf("re-create: %v %v", ok, err)
			}
			c, err := st.GetCredential(ctx, subj)
			// the registration locale (rdb 0017) is kept; a repeat register leaves it
			if err != nil || c.PasswordHash != h1 || c.Verified() || c.Locale != "fi" {
				t.Fatalf("get: %+v %v", c, err)
			}
			yes := func(string) bool { return true }
			base := int(now.UnixNano()%1e6) * 100
			if name == "postgres" {
				base = int(time.Now().UnixNano() % 1e12)
			}
			if _, err := st.IssueToken(ctx, auth.TokenIssue{Kind: auth.TokenVerify, Subject: subj, TokenHash: th(base + 1), PwHash: "", Now: now, Expires: now.Add(time.Hour), Floor: floor}); err == nil {
				t.Fatal("verify token without a password hash accepted")
			}
			if ok, err := st.IssueToken(ctx, auth.TokenIssue{Kind: auth.TokenVerify, Subject: subj, TokenHash: th(base + 1), PwHash: h1, Now: now, Expires: now.Add(time.Hour), Floor: floor}); !ok || err != nil {
				t.Fatalf("issue 1: %v %v", ok, err)
			}
			if ok, _ := st.IssueToken(ctx, auth.TokenIssue{Kind: auth.TokenVerify, Subject: subj, TokenHash: th(base + 2), PwHash: h1, Now: now.Add(30 * time.Second), Expires: now.Add(time.Hour), Floor: floor}); ok {
				t.Fatal("floor interval not enforced")
			}
			t2 := now.Add(2 * time.Minute)
			if ok, err := st.IssueToken(ctx, auth.TokenIssue{Kind: auth.TokenVerify, Subject: subj, TokenHash: th(base + 3), PwHash: h2, Now: t2, Expires: t2.Add(time.Hour), Floor: floor}); !ok || err != nil {
				t.Fatalf("issue 3: %v %v", ok, err)
			}
			if _, err := st.ConsumeVerification(ctx, th(base+1), t2, yes); !errors.Is(err, auth.ErrTokenInvalid) {
				t.Fatalf("older link after a newer one: %v", err)
			}
			if _, err := st.ConsumeVerification(ctx, th(base+3), t2.Add(2*time.Hour), yes); !errors.Is(err, auth.ErrTokenExpired) {
				t.Fatalf("expired: %v", err)
			}
			t4 := now.Add(4 * time.Minute)
			if ok, _ := st.IssueToken(ctx, auth.TokenIssue{Kind: auth.TokenVerify, Subject: subj, TokenHash: th(base + 4), PwHash: h2, Now: t4, Expires: t4.Add(time.Hour), Floor: floor}); !ok {
				t.Fatal("issue 4")
			}
			t6 := now.Add(6 * time.Minute)
			if ok, _ := st.IssueToken(ctx, auth.TokenIssue{Kind: auth.TokenVerify, Subject: subj, TokenHash: th(base + 5), PwHash: h2, Now: t6, Expires: t6.Add(time.Hour), Floor: floor}); ok {
				t.Fatal("daily cap (3) not enforced")
			}
			// accept sees the link's hash; a refusal writes nothing.
			var seen string
			no := func(h string) bool { seen = h; return false }
			if _, err := st.ConsumeVerification(ctx, th(base+4), t4, no); !errors.Is(err, auth.ErrVerifyPasswordMismatch) || seen != h2 {
				t.Fatalf("mismatch: %v (accept saw the link hash: %v)", err, seen == h2)
			}
			if c, _ := st.GetCredential(ctx, subj); c.Verified() || c.PasswordHash != h1 {
				t.Fatalf("a refused click wrote the credential: %+v", c)
			}
			if _, err := st.ConsumeVerification(ctx, th(base+4), t4, yes); err != nil {
				t.Fatal(err)
			}
			if c, _ := st.GetCredential(ctx, subj); !c.Verified() || c.PasswordHash != h2 {
				t.Fatalf("verify must install the token's hash: %+v", c)
			}
			if _, err := st.ConsumeVerification(ctx, th(base+4), t4, yes); err != nil {
				t.Fatalf("repeat click: %v", err)
			}
			// Reset: single use, consumes every live reset token.
			for i, at := range []time.Time{t4, t6} {
				if ok, _ := st.IssueToken(ctx, auth.TokenIssue{Kind: auth.TokenReset, Subject: subj, TokenHash: th(base + 10 + i), PwHash: "", Now: at, Expires: at.Add(time.Hour), Floor: floor}); !ok {
					t.Fatalf("reset issue %d", i)
				}
			}
			if s, err := st.ConsumeReset(ctx, th(base+10), h1, t6); err != nil || s != subj {
				t.Fatalf("reset: %q %v", s, err)
			}
			for _, tok := range []string{th(base + 10), th(base + 11), th(9)} {
				if _, err := st.ConsumeReset(ctx, tok, h2, t6); !errors.Is(err, auth.ErrTokenInvalid) {
					t.Fatalf("token %s after reset: %v", tok[60:], err)
				}
			}
			if c, _ := st.GetCredential(ctx, subj); c.PasswordHash != h1 {
				t.Fatal("reset did not set the hash")
			}
			if err := st.SetPassword(ctx, subj, h2, t6); err != nil {
				t.Fatal(err)
			}
			if err := st.SetPassword(ctx, "absent-"+subj, h2, t6); !errors.Is(err, auth.ErrCredNotFound) {
				t.Fatalf("set absent: %v", err)
			}
			if err := st.TouchLogin(ctx, subj, t6); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestClientIPHops(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.9:5555"
	r.Header.Set("X-Forwarded-For", "6.6.6.6, 203.0.113.7, 10.1.1.1")
	for hops, want := range map[int]string{0: "10.0.0.9", 1: "10.1.1.1", 2: "203.0.113.7", 3: "6.6.6.6", 9: "10.0.0.9"} {
		if got := auth.ClientIP(r, hops); got != want {
			t.Errorf("hops=%d: %s, want %s", hops, got, want)
		}
	}
}

// TestLoginFailuresContract: both drivers count per address and over all
// addresses inside the window, prune past it, and clear one subject only
// (rdb 0308, SPL-6182 defect 5).
func TestLoginFailuresContract(t *testing.T) {
	for name, st := range credStores(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			sfx := fmt.Sprintf("%d", time.Now().UnixNano())
			subj, other := "lock-"+sfx+"@example.com", "lock-other-"+sfx+"@example.com"
			t0 := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
			win := 15 * time.Minute
			rec := func(s, ip string, at time.Time) {
				t.Helper()
				if err := st.RecordLoginFailure(ctx, s, ip, at, at.Add(-win)); err != nil {
					t.Fatal(err)
				}
			}
			rec(subj, "198.51.100.1", t0)
			rec(subj, "198.51.100.1", t0.Add(time.Minute))
			rec(subj, "203.0.113.2", t0.Add(2*time.Minute))
			rec(other, "198.51.100.1", t0.Add(2*time.Minute))
			if ip, all, err := st.LoginFailures(ctx, subj, "198.51.100.1", t0.Add(-win)); err != nil || ip != 2 || all != 3 {
				t.Fatalf("count: %d %d %v, want 2 3", ip, all, err)
			}
			if ip, all, err := st.LoginFailures(ctx, subj, "198.51.100.1", t0.Add(30*time.Second)); err != nil || ip != 1 || all != 2 {
				t.Fatalf("window: %d %d %v, want 1 2", ip, all, err)
			}
			// a write past the window prunes the old rows of every subject
			rec(subj, "203.0.113.2", t0.Add(time.Hour))
			if ip, all, err := st.LoginFailures(ctx, other, "198.51.100.1", t0.Add(-time.Hour)); err != nil || ip != 0 || all != 0 {
				t.Fatalf("prune: %d %d %v, want 0 0", ip, all, err)
			}
			rec(other, "198.51.100.1", t0.Add(time.Hour))
			if n, err := st.ClearLoginFailures(ctx, subj); err != nil || n != 1 {
				t.Fatalf("clear: %d %v, want 1", n, err)
			}
			if _, all, err := st.LoginFailures(ctx, other, "x", t0); err != nil || all != 1 {
				t.Fatalf("CONTROL: the clear left another subject alone: %d %v", all, err)
			}
		})
	}
}
