package auth_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// 005 T035 / 010 auth-v1 section 3: the hub tells the WUI whether THIS human
// was granted the diagnostics panel. The grant is an operator decision held in
// cnf (SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS), read on every session call, and
// never a claim of the signed cookie.

const diagVar = "SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS"

// sessionJSON reads GET /session as the wire sees it: a map, not auth.Session,
// so a claim the struct does not have is still visible to the assertion.
func sessionJSON(t *testing.T, c *http.Client, hub string) (int, map[string]any) {
	t.Helper()
	resp, err := c.Get(hub + "/api/v1/auth/session")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

func TestDiagnosticsConfigGrant(t *testing.T) {
	base := map[string]string{
		"SPOOL_HUB_AUTH_SESSION_KEY":   strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":       "http://app.example.test",
		"SPOOL_HUB_AUTH_COOKIE_SECURE": "false",
	}
	load := func(t *testing.T, list string) *auth.Config {
		t.Helper()
		vars := map[string]string{diagVar: list}
		for k, v := range base {
			vars[k] = v
		}
		cfg, err := auth.LoadFrom("lde", vars)
		if err != nil {
			t.Fatalf("%s=%q: %v", diagVar, list, err)
		}
		return cfg
	}

	t.Run("unset grants nobody", func(t *testing.T) {
		cfg := load(t, "")
		for _, e := range []string{"", "alice@example.com", "anyone@example.com"} {
			if cfg.DiagnosticsGranted(e) {
				t.Fatalf("empty list granted %q", e)
			}
		}
	})

	t.Run("listed addresses only", func(t *testing.T) {
		// Case and surrounding whitespace are the operator's typing, not part
		// of the identity: the hub compares the normalised address either way.
		cfg := load(t, " Alice@Example.COM , ops@example.net ")
		for _, e := range []string{"alice@example.com", "ALICE@example.com", " alice@example.com ", "ops@example.net"} {
			if !cfg.DiagnosticsGranted(e) {
				t.Fatalf("listed address %q was not granted", e)
			}
		}
		for _, e := range []string{"", "mallory@example.com", "alice@example.com.evil.test", "example.com", "alice"} {
			if cfg.DiagnosticsGranted(e) {
				t.Fatalf("unlisted %q was granted", e)
			}
		}
	})

	// CONTROL: the boot refuses anything that is not one real address, so a
	// list can never mean more people than the operator wrote down.
	t.Run("fails fast on a non-address", func(t *testing.T) {
		for _, bad := range []string{"*", "*@example.com", "@example.com", "example.com",
			"alice@example.com;ops@example.net", "FirstName LastName <a@example.com>"} {
			vars := map[string]string{diagVar: bad}
			for k, v := range base {
				vars[k] = v
			}
			if _, err := auth.LoadFrom("lde", vars); err == nil {
				t.Fatalf("%s=%q was accepted", diagVar, bad)
			}
		}
	})
}

func TestSessionCarriesDiagnosticsGrant(t *testing.T) {
	// alice@example.com is the fake IdP's person (flow_test.go).
	t.Run("granted", func(t *testing.T) {
		r := newRigFront(t, auth.Options{Registrar: registrar{}}, map[string]string{diagVar: "Alice@Example.com"}, "")
		c := browser(t)
		signIn(t, c, r, "google", "?redirect=/c/general")
		code, got := sessionJSON(t, c, r.hub)
		if code != http.StatusOK || got["diagnostics_enabled"] != true {
			t.Fatalf("session = %d %v", code, got)
		}
	})

	t.Run("not granted", func(t *testing.T) {
		r := newRigFront(t, auth.Options{Registrar: registrar{}}, map[string]string{diagVar: "someone.else@example.com"}, "")
		c := browser(t)
		signIn(t, c, r, "google", "?redirect=/c/general")
		code, got := sessionJSON(t, c, r.hub)
		// The key is always present and always a boolean: the WUI's gate
		// admits only the literal `true`, and a missing key would read the
		// same as false — but then a hub that lost the feature would look
		// exactly like a hub that refused this person.
		if code != http.StatusOK || got["diagnostics_enabled"] != false {
			t.Fatalf("session = %d %v", code, got)
		}
	})

	t.Run("no list grants nobody", func(t *testing.T) {
		r := newRig(t, registrar{})
		c := browser(t)
		signIn(t, c, r, "google", "?redirect=/c/general")
		if _, got := sessionJSON(t, c, r.hub); got["diagnostics_enabled"] != false {
			t.Fatalf("default granted the panel: %v", got)
		}
	})

	// Revocation does not wait for the cookie to expire: the same cookie reads
	// false against a hub whose list no longer names the address. This is the
	// property that keeps the grant out of the signed claims.
	t.Run("revoked mid-session", func(t *testing.T) {
		on := newRigFront(t, auth.Options{Registrar: registrar{}}, map[string]string{diagVar: "alice@example.com"}, "")
		c := browser(t)
		signIn(t, c, on, "google", "?redirect=/")
		if _, got := sessionJSON(t, c, on.hub); got["diagnostics_enabled"] != true {
			t.Fatalf("granted session: %v", got)
		}
		// The same session key, so the cookie the browser holds still verifies
		// — only the operator's list changed.
		off := newRigFront(t, auth.Options{Registrar: registrar{}}, map[string]string{diagVar: ""}, "")
		u, _ := url.Parse(off.hub)
		c.Jar.SetCookies(u, c.Jar.Cookies(mustParse(t, on.hub)))
		code, got := sessionJSON(t, c, off.hub)
		if code != http.StatusOK {
			t.Fatalf("the cookie stopped verifying (%d) — this test proves nothing then", code)
		}
		if got["diagnostics_enabled"] != false {
			t.Fatalf("a revoked grant survived in the cookie: %v", got)
		}
	})
}

func mustParse(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

// CONTROL: nothing the browser sends can assert the grant.
func TestDiagnosticsNotSettableFromTheBrowser(t *testing.T) {
	r := newRigFront(t, auth.Options{Registrar: registrar{}}, map[string]string{diagVar: "ops@example.net"}, "")

	// A cookie the hub itself would accept — right key, valid MAC, unexpired —
	// whose payload carries the claim for an address nobody granted. The
	// Session struct has no such field, so it is dropped on the way in.
	t.Run("a validly signed cookie that names the claim", func(t *testing.T) {
		ck := auth.MintSessionCookie(r.h, map[string]any{
			"v": 1, "p": "google", "sub": "sub-123", "email": "mallory@example.com",
			"diagnostics_enabled": true,
			"iat":                 time.Now().Unix(), "exp": time.Now().Add(time.Hour).Unix(),
		})
		c := browser(t)
		c.Jar.SetCookies(mustParse(t, r.hub), []*http.Cookie{ck})
		code, got := sessionJSON(t, c, r.hub)
		if code != http.StatusOK {
			t.Fatalf("the crafted cookie was not accepted at all (%d) — the control needs it to be", code)
		}
		if got["email"] != "mallory@example.com" {
			t.Fatalf("wrong session read back: %v", got)
		}
		if got["diagnostics_enabled"] != false {
			t.Fatalf("a browser-supplied claim was echoed back: %v", got)
		}
	})

	// The same signed-in reader, asking for it in every way a browser can.
	t.Run("query, header and cookie tricks", func(t *testing.T) {
		c := browser(t)
		signIn(t, c, r, "google", "?redirect=/")
		for _, q := range []string{"?diagnostics_enabled=true", "?debug=1", "?diagnostics_enabled=1&debug=true"} {
			resp, err := c.Get(r.hub + "/api/v1/auth/session" + q)
			if err != nil {
				t.Fatal(err)
			}
			out := map[string]any{}
			json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
			resp.Body.Close()
			if out["diagnostics_enabled"] != false {
				t.Fatalf("query %q granted the panel: %v", q, out)
			}
		}
		req, _ := http.NewRequest(http.MethodGet, r.hub+"/api/v1/auth/session", nil)
		req.Header.Set("X-Diagnostics-Enabled", "true")
		req.Header.Set("X-Spool-Diagnostics", "true")
		req.AddCookie(&http.Cookie{Name: "diagnostics_enabled", Value: "true"})
		resp, err := c.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]any{}
		json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
		resp.Body.Close()
		if out["diagnostics_enabled"] != false {
			t.Fatalf("a header or a second cookie granted the panel: %v", out)
		}
	})
}

// newDiagNRig is newNRig (native_test.go) with the social vars open, so the
// native leg can be run against a hub that has a diagnostics list.
func newDiagNRig(t *testing.T, social, native map[string]string) *nrig {
	t.Helper()
	r := &nrig{box: &mail.Recorder{}, reg: &recReg{}, store: auth.NewMemoryCredStore(),
		t: time.Date(2026, 9, 19, 6, 0, 0, 0, time.UTC)}
	var hubH http.Handler
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) { hubH.ServeHTTP(w, q) }))
	t.Cleanup(srv.Close)
	r.url = srv.URL
	vars := map[string]string{
		"SPOOL_HUB_AUTH_SESSION_KEY":   strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":       "http://app.example.test",
		"SPOOL_HUB_AUTH_COOKIE_SECURE": "false",
	}
	for k, v := range social {
		vars[k] = v
	}
	cfg, err := auth.LoadFrom("lde", vars)
	if err != nil {
		t.Fatal(err)
	}
	nv := map[string]string{"SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS": "true"}
	for k, v := range nativeBase {
		nv[k] = v
	}
	for k, v := range native {
		nv[k] = v
	}
	nc, err := auth.LoadNativeFrom("lde", nv)
	if err != nil {
		t.Fatal(err)
	}
	r.h = auth.New(cfg, zerolog.Nop(), auth.Options{Registrar: r.reg, Now: r.now})
	if err := r.h.EnableNative(nc, auth.NativeDeps{Store: r.store, Sender: r.box, Delivers: true}); err != nil {
		t.Fatal(err)
	}
	hubH = r.h
	return r
}

// register + verify + login, with the debug token standing in for the mail.
func nativeSignIn(t *testing.T, r *nrig, c *http.Client, email string, verify bool) resp {
	t.Helper()
	g := r.post(t, c, "register", map[string]string{"email": email, "password": pwA})
	if g.code != http.StatusAccepted {
		t.Fatalf("register: %d %s", g.code, g.raw)
	}
	if verify {
		tok, _ := g.body["debug_token"].(string)
		if v := r.post(t, c, "email/verify", map[string]string{"token": tok}); v.code != http.StatusNoContent {
			t.Fatalf("verify: %d %s", v.code, v.raw)
		}
	}
	return r.post(t, c, "login", map[string]string{"email": email, "password": pwA})
}

// The native login answers with the claims the WUI adopts without a second
// probe (015 native-auth-v1 section 2), so the grant has to be in THAT body too.
func TestNativeLoginCarriesDiagnosticsGrant(t *testing.T) {
	t.Run("granted", func(t *testing.T) {
		r := newDiagNRig(t, map[string]string{diagVar: "ops@example.net"}, nil)
		g := nativeSignIn(t, r, nil, "ops@example.net", true)
		if g.code != http.StatusOK || g.body["diagnostics_enabled"] != true {
			t.Fatalf("login: %d %s", g.code, g.raw)
		}
	})

	t.Run("not granted", func(t *testing.T) {
		r := newDiagNRig(t, map[string]string{diagVar: "ops@example.net"}, nil)
		g := nativeSignIn(t, r, nil, "someone@example.net", true)
		if g.code != http.StatusOK || g.body["diagnostics_enabled"] != false {
			t.Fatalf("login: %d %s", g.code, g.raw)
		}
	})

	// CONTROL: the grant follows a PROVEN address. Where the hub admits an
	// unverified credential (lde only — native_config refuses it elsewhere),
	// anyone could register the granted address and read the panel, so that
	// session is refused the grant no matter what the list says.
	t.Run("an unverified address is never granted", func(t *testing.T) {
		r := newDiagNRig(t, map[string]string{diagVar: "ops@example.net"},
			map[string]string{"SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED": "false"})
		c := browser(t)
		g := nativeSignIn(t, r, c, "ops@example.net", false)
		if g.code != http.StatusOK {
			t.Fatalf("login: %d %s", g.code, g.raw)
		}
		if g.body["diagnostics_enabled"] != false {
			t.Fatalf("an unverified address was granted: %s", g.raw)
		}
		// and the session read agrees with the login body
		if _, got := sessionJSON(t, c, r.url); got["diagnostics_enabled"] != false {
			t.Fatalf("session granted what login refused: %v", got)
		}
	})
}
