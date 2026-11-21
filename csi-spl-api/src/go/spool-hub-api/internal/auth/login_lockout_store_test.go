package auth_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
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

// Twenty overlapping wrong sign-ins from one address (under the per-IP
// cap of 30) answer exactly ten 401 and ten 429: the count and the record
// are one step, so no burst passes a stale count (R7 W1 on 439a8387e, where
// all twenty answered 401 and stored twenty). FR-006b: the 11th is 429.
func TestNativeLockoutBurstCannotOvershoot(t *testing.T) {
	st := auth.NewMemoryCredStore()
	r := newNRigOn(t, nil, nil, true, nil, st)
	r.registerVerified(t, "burst@example.com", pwA)
	const n = 20
	codes := make(chan int, n)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			b, _ := json.Marshal(map[string]string{"email": "burst@example.com", "password": fmt.Sprintf("guess-%08d", i)})
			<-start
			res, err := http.Post(r.url+"/api/v1/auth/login", "application/json", bytes.NewReader(b))
			if err != nil {
				codes <- 0
				return
			}
			_, _ = io.Copy(io.Discard, res.Body)
			res.Body.Close()
			codes <- res.StatusCode
		}(i)
	}
	close(start)
	wg.Wait()
	close(codes)
	got := map[int]int{}
	for c := range codes {
		got[c]++
	}
	if got[http.StatusUnauthorized] != 10 || got[http.StatusTooManyRequests] != 10 {
		t.Fatalf("burst of %d: %v, want 10x401 and 10x429", n, got)
	}
	if _, all, err := st.LoginFailures(context.Background(), "burst@example.com", "", time.Time{}); err != nil || all != 10 {
		t.Fatalf("stored %d %v, want 10", all, err)
	}
}

type lockoutCreds struct {
	*auth.MemoryCredStore
	claimErr, releaseErr error
	gets                 int
}

func (l *lockoutCreds) ClaimLoginAttempt(ctx context.Context, s, ip string, now, since time.Time, perIP, perAll int) (bool, error) {
	if l.claimErr != nil {
		return false, l.claimErr
	}
	return l.MemoryCredStore.ClaimLoginAttempt(ctx, s, ip, now, since, perIP, perAll)
}

func (l *lockoutCreds) ReleaseLoginAttempt(ctx context.Context, s, ip string, at time.Time) error {
	if l.releaseErr != nil {
		return l.releaseErr
	}
	return l.MemoryCredStore.ReleaseLoginAttempt(ctx, s, ip, at)
}

func (l *lockoutCreds) GetCredential(ctx context.Context, s string) (auth.Credential, error) {
	l.gets++
	return l.MemoryCredStore.GetCredential(ctx, s)
}

// A store that cannot claim the attempt fails closed (503, no cookie) before
// the credential is read; a store that cannot release a right password's
// claim still signs the person in and leaves the attempt counted.
func TestNativeLockoutStoreDownFailsClosed(t *testing.T) {
	mem := auth.NewMemoryCredStore()
	seedVerified(t, mem, "ok@example.com")
	st := &lockoutCreds{MemoryCredStore: mem, claimErr: errors.New("db down")}
	r := newLoginRig(t, nil, st, &recReg{})
	g := r.post(t, nil, "login", map[string]string{"email": "ok@example.com", "password": pwA})
	if g.code != http.StatusServiceUnavailable || g.body["error"] != "unavailable" || g.hdr.Get("Set-Cookie") != "" || st.gets != 0 {
		t.Fatalf("claim down: %d %s (credential reads %d, want 0)", g.code, g.raw, st.gets)
	}
	st = &lockoutCreds{MemoryCredStore: mem, releaseErr: errors.New("db down")}
	r = newLoginRig(t, nil, st, &recReg{})
	if g := r.post(t, nil, "login", map[string]string{"email": "ok@example.com", "password": pwA}); g.code != http.StatusOK {
		t.Fatalf("release down: a right password still signs in: %d %s", g.code, g.raw)
	}
	if _, all, err := mem.LoginFailures(context.Background(), "ok@example.com", "", time.Time{}); err != nil || all != 1 {
		t.Fatalf("release down: counted %d %v, want 1 (the safe side)", all, err)
	}
}
