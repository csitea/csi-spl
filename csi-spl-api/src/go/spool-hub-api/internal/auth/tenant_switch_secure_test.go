package auth_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-1285/1287: the session cookie the tenant switch re-issues carries Secure
// (CookieSecure true) and HttpOnly, and the switch still answers with the new
// tenant. The answer is produced from an internal request cookie
// (r2.Header.Set("Cookie", ...)) rather than an http.Cookie literal, so the
// SAST cookie-missing-secure / -httponly rules no longer flag a request cookie
// that never becomes a Set-Cookie. This test fails if the response cookie loses
// a flag or the internal read stops working.
func TestTenantSwitchReissuesSecureCookie(t *testing.T) {
	now := time.Date(2026, 9, 19, 6, 0, 0, 0, time.UTC)
	cfg, err := auth.LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_SESSION_KEY":   strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":       "https://app.example.test",
		"SPOOL_HUB_AUTH_COOKIE_SECURE": "true",
	})
	if err != nil {
		t.Fatal(err)
	}
	h := auth.New(cfg, zerolog.Nop(), auth.Options{
		Membership: memberOf{"HUM-1": "beta"},
		Now:        func() time.Time { return now },
	})
	// Enabling native wires the session key (subkey of SPOOL_HUB_AUTH_SESSION_KEY);
	// the switch itself needs no provider, only a verifiable session.
	nc, err := auth.LoadNativeFrom("lde", map[string]string{"SPOOL_HUB_AUTH_NATIVE_ENABLED": "true"})
	if err != nil {
		t.Fatal(err)
	}
	if err := h.EnableNative(nc, auth.NativeDeps{Store: auth.NewMemoryCredStore()}); err != nil {
		t.Fatal(err)
	}

	sc := auth.MintSessionCookie(h, auth.Session{
		V: 1, Provider: "google", Subject: "sub-1", HumanID: "HUM-1",
		Tenant: "acme", IssuedAt: now.Unix(), Exp: now.Add(time.Hour).Unix(),
	})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/tenant", strings.NewReader(`{"tenant":"beta"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(sc)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("switch: %d %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Tenant string `json:"t"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode answer: %v (%s)", err, rec.Body.String())
	}
	if out.Tenant != "beta" {
		t.Fatalf("answer tenant = %q, want beta (internal request-cookie read broke)", out.Tenant)
	}

	var reissued *http.Cookie
	for _, c := range rec.Result().Cookies() {
		if c.Name == cfg.CookieName {
			reissued = c
		}
	}
	if reissued == nil {
		t.Fatal("no session cookie re-issued by the switch")
	}
	if !reissued.Secure {
		t.Error("re-issued session cookie missing Secure (SPL-1285)")
	}
	if !reissued.HttpOnly {
		t.Error("re-issued session cookie missing HttpOnly (SPL-1287)")
	}
	if reissued.SameSite != http.SameSiteLaxMode {
		t.Errorf("re-issued session cookie SameSite = %v, want Lax", reissued.SameSite)
	}
}
