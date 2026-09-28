package auth_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// Pins of POST /login taken before handleLogin was split into named steps
// (SPL-1029 round 2): the per-IP ceiling, a failing credential store, a
// failing registrar, and a failing login stamp (which must not fail the login).

type flakyCreds struct {
	*auth.MemoryCredStore
	getErr, touchErr error
}

func (f *flakyCreds) GetCredential(ctx context.Context, s string) (auth.Credential, error) {
	if f.getErr != nil {
		return auth.Credential{}, f.getErr
	}
	return f.MemoryCredStore.GetCredential(ctx, s)
}

func (f *flakyCreds) TouchLogin(ctx context.Context, s string, now time.Time) error {
	if f.touchErr != nil {
		return f.touchErr
	}
	return f.MemoryCredStore.TouchLogin(ctx, s, now)
}

type brokenReg struct{}

func (brokenReg) Register(context.Context, auth.Identity, string) (string, error) {
	return "", errors.New("registrar down")
}

// newLoginRig is newNRig with the credential store and registrar given.
func newLoginRig(t *testing.T, extra map[string]string, st auth.CredStore, reg auth.Registrar) *nrig {
	t.Helper()
	r := &nrig{box: &mail.Recorder{}, reg: &recReg{}, t: time.Date(2026, 9, 19, 6, 0, 0, 0, time.UTC)}
	cfg, err := auth.LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_SESSION_KEY":   strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":       "http://app.example.test",
		"SPOOL_HUB_AUTH_COOKIE_SECURE": "false",
	})
	if err != nil {
		t.Fatal(err)
	}
	vars := map[string]string{}
	for k, v := range nativeBase {
		vars[k] = v
	}
	for k, v := range extra {
		vars[k] = v
	}
	nc, err := auth.LoadNativeFrom("lde", vars)
	if err != nil {
		t.Fatal(err)
	}
	r.h = auth.New(cfg, zerolog.Nop(), auth.Options{Registrar: reg, Now: r.now})
	if err := r.h.EnableNative(nc, auth.NativeDeps{Store: st, Sender: r.box, Delivers: true}); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(r.h)
	t.Cleanup(srv.Close)
	r.url = srv.URL
	return r
}

func seedVerified(t *testing.T, st *auth.MemoryCredStore, email string) {
	t.Helper()
	now := time.Date(2026, 9, 19, 6, 0, 0, 0, time.UTC)
	if _, err := st.CreateCredential(context.Background(), auth.Credential{Subject: email, PasswordHash: mustHash(t, pwA), EmailVerifiedAt: &now}, now); err != nil {
		t.Fatal(err)
	}
}

func TestNativeLoginPerIPCeiling(t *testing.T) {
	r := newLoginRig(t, map[string]string{"SPOOL_HUB_AUTH_NATIVE_LOGIN_PER_IP": "2"}, auth.NewMemoryCredStore(), &recReg{})
	for i, email := range []string{"a@example.com", "b@example.com"} {
		if g := r.post(t, nil, "login", map[string]string{"email": email, "password": pwB}); g.code != http.StatusUnauthorized {
			t.Fatalf("attempt %d: %d %s", i, g.code, g.raw)
		}
	}
	// a third address from the same IP is over the per-IP ceiling
	g := r.post(t, nil, "login", map[string]string{"email": "c@example.com", "password": pwB})
	if g.code != http.StatusTooManyRequests || g.body["error"] != "rate_limited" || g.hdr.Get("Retry-After") == "" {
		t.Fatalf("per-IP ceiling: %d %s", g.code, g.raw)
	}
}

func TestNativeLoginStoreAndRegistrarFailures(t *testing.T) {
	mem := auth.NewMemoryCredStore()
	seedVerified(t, mem, "ok@example.com")
	login := func(r *nrig) resp {
		return r.post(t, nil, "login", map[string]string{"email": "ok@example.com", "password": pwA, "tenant": "acme"})
	}
	// the credential store fails: 503, no cookie
	g := login(newLoginRig(t, nil, &flakyCreds{MemoryCredStore: mem, getErr: errors.New("db down")}, &recReg{}))
	if g.code != http.StatusServiceUnavailable || g.body["error"] != "unavailable" || g.hdr.Get("Set-Cookie") != "" {
		t.Fatalf("store failure: %d %s", g.code, g.raw)
	}
	// the registrar fails (not a refusal): 503, no cookie
	g = login(newLoginRig(t, nil, mem, brokenReg{}))
	if g.code != http.StatusServiceUnavailable || g.body["error"] != "unavailable" || g.hdr.Get("Set-Cookie") != "" {
		t.Fatalf("registrar failure: %d %s", g.code, g.raw)
	}
	// the login stamp fails: still signed in
	g = login(newLoginRig(t, nil, &flakyCreds{MemoryCredStore: mem, touchErr: errors.New("db down")}, &recReg{}))
	if g.code != http.StatusOK || g.hdr.Get("Set-Cookie") == "" || g.body["hum"] == nil {
		t.Fatalf("touch failure must not fail the login: %d %s", g.code, g.raw)
	}
}
