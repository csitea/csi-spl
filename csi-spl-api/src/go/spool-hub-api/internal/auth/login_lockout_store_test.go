package auth_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-6182 defect 5: the per-email ceiling lived in one instance's memory,
// so two instances over one database counted apart (and only a redeploy
// cleared it). The count is now in the CredStore.

// guess spends n wrong passwords on email.
func guess(t *testing.T, r *nrig, email string, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		if g := r.post(t, nil, "login", map[string]string{"email": email, "password": "guess-" + strings.Repeat("x", i+8)}); g.code != http.StatusUnauthorized {
			t.Fatalf("guess %d: %d %s", i, g.code, g.raw)
		}
	}
}

// Ten wrong guesses on instance A lock instance B too; CONTROL: another
// address is still free on B.
func TestNativeLockoutIsSharedAcrossInstances(t *testing.T) {
	st := auth.NewMemoryCredStore()
	a := newNRigOn(t, nil, nil, true, nil, st)
	b := newNRigOn(t, nil, nil, true, nil, st)
	a.registerVerified(t, "target@example.com", pwA)
	b.registerVerified(t, "other@example.com", pwA)
	guess(t, a, "target@example.com", 10)
	if g := b.post(t, nil, "login", map[string]string{"email": "target@example.com", "password": pwA}); g.code != http.StatusTooManyRequests || g.hdr.Get("Retry-After") == "" {
		t.Fatalf("defect 5: instance B did not see instance A's lockout: %d %s", g.code, g.raw)
	}
	if g := b.post(t, nil, "login", map[string]string{"email": "other@example.com", "password": pwA}); g.code != http.StatusOK {
		t.Fatalf("CONTROL: another address on B: %d %s", g.code, g.raw)
	}
}

// The operator's clear (spool hub-clear-lockout) lets the person in without
// a redeploy; a right password never counts toward the lockout.
func TestNativeLockoutOperatorClear(t *testing.T) {
	st := auth.NewMemoryCredStore()
	r := newNRigOn(t, nil, nil, true, nil, st)
	r.registerVerified(t, "member@example.com", pwA)
	for i := 0; i < 12; i++ {
		if g := r.post(t, nil, "login", map[string]string{"email": "member@example.com", "password": pwA}); g.code != http.StatusOK {
			t.Fatalf("right password %d: %d %s", i, g.code, g.raw)
		}
	}
	guess(t, r, "member@example.com", 10)
	if g := r.post(t, nil, "login", map[string]string{"email": "member@example.com", "password": pwA}); g.code != http.StatusTooManyRequests {
		t.Fatalf("CONTROL: locked after 10 guesses: %d %s", g.code, g.raw)
	}
	n, err := st.ClearLoginFailures(context.Background(), "member@example.com")
	if err != nil || n != 10 {
		t.Fatalf("clear: %d %v, want 10", n, err)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "member@example.com", "password": pwA}); g.code != http.StatusOK {
		t.Fatalf("after the operator's clear: %d %s", g.code, g.raw)
	}
}

type lockoutCreds struct {
	*auth.MemoryCredStore
	countErr, recordErr error
	gets                int
}

func (l *lockoutCreds) LoginFailures(ctx context.Context, s, ip string, since time.Time) (int, int, error) {
	if l.countErr != nil {
		return 0, 0, l.countErr
	}
	return l.MemoryCredStore.LoginFailures(ctx, s, ip, since)
}

func (l *lockoutCreds) RecordLoginFailure(ctx context.Context, s, ip string, now, prune time.Time) error {
	if l.recordErr != nil {
		return l.recordErr
	}
	return l.MemoryCredStore.RecordLoginFailure(ctx, s, ip, now, prune)
}

func (l *lockoutCreds) GetCredential(ctx context.Context, s string) (auth.Credential, error) {
	l.gets++
	return l.MemoryCredStore.GetCredential(ctx, s)
}

// A store that cannot count or record a failure fails closed (503, no
// cookie), and the count comes before the credential is read.
func TestNativeLockoutStoreDownFailsClosed(t *testing.T) {
	mem := auth.NewMemoryCredStore()
	seedVerified(t, mem, "ok@example.com")
	st := &lockoutCreds{MemoryCredStore: mem, countErr: errors.New("db down")}
	r := newLoginRig(t, nil, st, &recReg{})
	g := r.post(t, nil, "login", map[string]string{"email": "ok@example.com", "password": pwA})
	if g.code != http.StatusServiceUnavailable || g.body["error"] != "unavailable" || g.hdr.Get("Set-Cookie") != "" || st.gets != 0 {
		t.Fatalf("count down: %d %s (credential reads %d, want 0)", g.code, g.raw, st.gets)
	}
	st = &lockoutCreds{MemoryCredStore: mem, recordErr: errors.New("db down")}
	r = newLoginRig(t, nil, st, &recReg{})
	if g := r.post(t, nil, "login", map[string]string{"email": "ok@example.com", "password": pwB}); g.code != http.StatusServiceUnavailable {
		t.Fatalf("record down: %d %s", g.code, g.raw)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "ok@example.com", "password": pwA}); g.code != http.StatusOK {
		t.Fatalf("CONTROL: a right password needs no record: %d %s", g.code, g.raw)
	}
}
