package auth_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// fixedExpiry is an Impersonation whose clone expires at exp.
type fixedExpiry struct{ exp time.Time }

func (f fixedExpiry) StartActAs(_ context.Context, _, _, _, target string) (auth.ActAsResult, error) {
	return auth.ActAsResult{CloneHum: "HUM-9", TargetHum: target, ExpiresAt: f.exp}, nil
}
func (fixedExpiry) StopActAs(context.Context, string, string) error { return nil }
func (fixedExpiry) IsClone(context.Context, string, string) (bool, error) {
	return true, nil
}

// specs/054: the clone cookie lives as long as the clone, and never less than
// one second — an expiry already passed must not become MaxAge <= 0 (delete).
func TestActAsCookieMaxAgeClamped(t *testing.T) {
	now := time.Date(2026, 10, 4, 6, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		name string
		exp  time.Time
		want int
	}{
		{"future", now.Add(30 * time.Minute), 1800},
		{"past", now.Add(-time.Minute), 1},
	} {
		cfg, err := auth.LoadFrom("lde", map[string]string{
			"SPOOL_HUB_AUTH_SESSION_KEY": strings.Repeat("k", 32),
			"SPOOL_HUB_AUTH_APP_URL":     "https://app.example.test",
		})
		if err != nil {
			t.Fatal(err)
		}
		h := auth.New(cfg, zerolog.Nop(), auth.Options{
			Membership:    memberOf{"HUM-1": "acme"},
			Now:           func() time.Time { return now },
			Impersonation: fixedExpiry{c.exp},
		})
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
		req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/act-as", strings.NewReader(`{"human_id":"HUM-2"}`))
		req.Header.Set("Content-Type", "application/json")
		req.AddCookie(sc)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: act-as %d %s", c.name, rec.Code, rec.Body.String())
		}
		var got *http.Cookie
		for _, ck := range rec.Result().Cookies() {
			if ck.Name == cfg.CookieName {
				got = ck
			}
		}
		if got == nil {
			t.Fatalf("%s: no session cookie", c.name)
		}
		if got.MaxAge != c.want {
			t.Errorf("%s: MaxAge = %d, want %d", c.name, got.MaxAge, c.want)
		}
	}
}
