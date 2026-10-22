package auth_test

import (
	"context"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// The dev switch, spelled out: what the compose file and .env set, checked
// against auth.DevLoginEnv and config.DevLoginEnv below.
const devLoginSwitch = "SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED"

// devSeats is a Membership + TenantLister whose every member holds role in
// tenant main.
type devSeats struct{ role string }

func (d devSeats) Member(_ context.Context, _, tenant string) (bool, error) {
	return tenant == "main", nil
}

func (d devSeats) Tenants(_ context.Context, _ string) ([]auth.TenantRole, error) {
	return []auth.TenantRole{{TenantID: "main", Role: d.role}}, nil
}

func TestDevLoginSignsInAsWorkspaceOwner(t *testing.T) {
	t.Setenv(devLoginSwitch, "true")
	r := newNRig(t, nil, devSeats{role: "biz_owner"}, false)
	jar, _ := cookiejar.New(nil)
	c := &http.Client{Jar: jar}
	got := r.post(t, c, "dev-login", map[string]string{"redirect": "/t/main"})
	if got.code != http.StatusOK {
		t.Fatalf("dev-login: %d %s", got.code, got.raw)
	}
	if got.body["email"] != "dev-owner@spool.local" || got.body["t"] != "main" || got.body["p"] != "dev" ||
		got.body["hum"] == "" || got.body["redirect"] != "/t/main" {
		t.Fatalf("dev-login answer: %s", got.raw)
	}
	if r.reg.n() != 1 || r.reg.tenants[0] != "main" || r.reg.calls[0].Email != "dev-owner@spool.local" {
		t.Fatalf("registrar calls: %+v tenants %v", r.reg.calls, r.reg.tenants)
	}
	// The cookie it set is a real session: GET session answers the owner.
	res, err := c.Get(r.url + "/api/v1/auth/session")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusOK || !strings.Contains(string(raw), `"email":"dev-owner@spool.local"`) {
		t.Fatalf("session after dev-login: %d %s", res.StatusCode, raw)
	}
}

func TestDevLoginOffByDefault(t *testing.T) {
	for _, v := range []string{"", "false", "0", "yes-please"} {
		t.Setenv(devLoginSwitch, v)
		r := newNRig(t, nil, devSeats{role: "biz_owner"}, false)
		if got := r.post(t, nil, "dev-login", map[string]string{}); got.code != http.StatusNotFound {
			t.Fatalf("switch %q: %d %s, want 404", v, got.code, got.raw)
		}
		if r.reg.n() != 0 || r.post(t, nil, "dev-login", nil).hdr.Get("Set-Cookie") != "" {
			t.Fatalf("switch %q reached the registrar or set a cookie", v)
		}
	}
}

// Spec 148 §2.3.2 per-request refusal: on a dev or prd hub (and any env that
// is not lde) the route is 404 even with the switch on, and nothing is signed.
func TestDevLoginRefusedOutsideLocalDev(t *testing.T) {
	t.Setenv(devLoginSwitch, "true")
	for _, env := range []string{"dev", "prd", ""} {
		cfg, err := auth.LoadFrom(env, map[string]string{
			"SPOOL_HUB_AUTH_PROVIDERS":            "google",
			"SPOOL_HUB_AUTH_SESSION_KEY":          strings.Repeat("k", 32),
			"SPOOL_HUB_AUTH_APP_URL":              "https://app.example.test",
			"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID":     "cid-test",
			"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET": "csecret-test",
			"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI":  "https://app.example.test/api/v1/auth/google/callback",
		})
		if err != nil {
			t.Fatalf("%q: %v", env, err)
		}
		reg := &recReg{}
		h := auth.New(cfg, zerolog.Nop(), auth.Options{Registrar: reg, Membership: devSeats{role: "biz_owner"}})
		req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/dev-login", strings.NewReader(`{}`))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != http.StatusNotFound || w.Header().Get("Set-Cookie") != "" || reg.n() != 0 {
			t.Fatalf("env %q: %d cookie=%q registrar calls=%d, want 404, none, 0",
				env, w.Code, w.Header().Get("Set-Cookie"), reg.n())
		}
	}
}

func TestDevLoginRefusesANonOwnerSeat(t *testing.T) {
	t.Setenv(devLoginSwitch, "true")
	r := newNRig(t, nil, devSeats{role: "developer"}, false)
	got := r.post(t, nil, "dev-login", map[string]string{})
	if got.code != http.StatusConflict || got.hdr.Get("Set-Cookie") != "" || !strings.Contains(got.raw, "dev_login_not_owner") {
		t.Fatalf("non-owner seat: %d %q %s, want 409 with no cookie", got.code, got.hdr.Get("Set-Cookie"), got.raw)
	}
}

// JSON only: a cross-site form post never signs a local browser in.
func TestDevLoginRefusesAFormPost(t *testing.T) {
	t.Setenv(devLoginSwitch, "true")
	r := newNRig(t, nil, devSeats{role: "biz_owner"}, false)
	res, err := http.Post(r.url+"/api/v1/auth/dev-login", "application/x-www-form-urlencoded", strings.NewReader("a=1"))
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusUnsupportedMediaType || res.Header.Get("Set-Cookie") != "" || r.reg.n() != 0 {
		t.Fatalf("form post: %d, want 415 and no sign-in", res.StatusCode)
	}
}

// Row B4 refuses the same switch at startup (config.DevLoginEnv): the two
// names must never drift, or the startup guard checks a switch nobody reads.
func TestDevLoginSwitchMatchesTheStartupGuard(t *testing.T) {
	for _, name := range []string{config.DevLoginEnv, devLoginSwitch} {
		if name != auth.DevLoginEnv {
			t.Fatalf("switch %q differs from auth.DevLoginEnv %q", name, auth.DevLoginEnv)
		}
	}
}
