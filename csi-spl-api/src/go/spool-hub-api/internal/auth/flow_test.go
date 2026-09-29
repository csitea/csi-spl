package auth_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
)

// rig is one browser, one hub (the auth routes), one WUI and one fake IdP
// standing in for Google and Facebook, all on loopback.
type rig struct {
	hub, wui string
	fake     *fakeidp.IdP
	h        *auth.Handler
}

type registrar struct{ refuse bool }

func (r registrar) Register(_ context.Context, id auth.Identity, tenant string) (string, error) {
	if r.refuse {
		return "", auth.ErrNotAllowed
	}
	return "HUM-" + id.Provider + "-" + id.Subject + "@" + tenant, nil
}

var alice = fakeidp.Person{Subject: "sub-123", Email: "Alice@Example.com", EmailVerified: true, Name: "FirstName LastName"}

func newRig(t *testing.T, reg auth.Registrar) *rig {
	t.Helper()
	return newRigWith(t, auth.Options{Registrar: reg})
}

func newRigWith(t *testing.T, opts auth.Options) *rig {
	t.Helper()
	return newRigFront(t, opts, nil, "")
}

// newRigFront: extra env over the rig's, and the IdP callbacks may go to
// another origin (callbackBase, e.g. a Firebase-like front); "" = the hub.
func newRigFront(t *testing.T, opts auth.Options, extra map[string]string, callbackBase string) *rig {
	t.Helper()
	var hubH http.Handler
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hubH.ServeHTTP(w, r) }))
	t.Cleanup(hub.Close)
	if callbackBase == "" {
		callbackBase = hub.URL
	}
	wui := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "wui "+r.URL.RequestURI()) //nolint:errcheck
	}))
	t.Cleanup(wui.Close)
	g := fakeidp.Client{ID: "gid", Secret: "gsecret", RedirectURI: callbackBase + "/api/v1/auth/google/callback"}
	f := fakeidp.Client{ID: "fid", Secret: "fsecret", RedirectURI: callbackBase + "/api/v1/auth/facebook/callback"}
	fake := fakeidp.New(g, f, alice)
	idp := httptest.NewServer(fake.Handler())
	t.Cleanup(idp.Close)

	env := map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":              "google,facebook",
		"SPOOL_HUB_AUTH_SESSION_KEY":            strings.Repeat("s", 32),
		"SPOOL_HUB_AUTH_APP_URL":                wui.URL,
		"SPOOL_HUB_AUTH_COOKIE_SECURE":          "false",
		"SPOOL_HUB_AUTH_IDP_BASE_URL":           idp.URL,
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID":       g.ID,
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET":   g.Secret,
		"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI":    g.RedirectURI,
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID":     f.ID,
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET": f.Secret,
		"SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI":  f.RedirectURI,
	}
	for k, v := range extra {
		env[k] = v
	}
	cfg, err := auth.LoadFrom("lde", env)
	if err != nil {
		t.Fatal(err)
	}
	h := auth.New(cfg, zerolog.Nop(), opts)
	hubH = h
	return &rig{hub: hub.URL, wui: wui.URL, fake: fake, h: h}
}

func browser(t *testing.T) *http.Client {
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	return &http.Client{Jar: jar}
}

// noFollow stops at the first redirect so a test can read Location.
func noFollow(c *http.Client) *http.Client {
	return &http.Client{Jar: c.Jar, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
}

// signIn runs start -> IdP -> callback -> WUI and returns where it landed.
func signIn(t *testing.T, c *http.Client, r *rig, provider, query string) *url.URL {
	t.Helper()
	resp, err := c.Get(r.hub + "/api/v1/auth/" + provider + "/start" + query)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if !strings.HasPrefix(resp.Request.URL.String(), r.wui) {
		t.Fatalf("landed on %s (status %d), want the WUI", resp.Request.URL, resp.StatusCode)
	}
	return resp.Request.URL
}

func session(t *testing.T, c *http.Client, r *rig) (int, auth.Session) {
	t.Helper()
	resp, err := c.Get(r.hub + "/api/v1/auth/session")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var s auth.Session
	json.NewDecoder(resp.Body).Decode(&s) //nolint:errcheck
	return resp.StatusCode, s
}

func TestSignInEachProvider(t *testing.T) {
	for _, p := range []string{auth.ProviderGoogle, auth.ProviderFacebook} {
		t.Run(p, func(t *testing.T) {
			r := newRig(t, registrar{})
			c := browser(t)
			if code, _ := session(t, c, r); code != http.StatusUnauthorized {
				t.Fatalf("session before sign-in = %d", code)
			}
			landed := signIn(t, c, r, p, "?redirect=/c/general&tenant=t1")
			if landed.Path != "/c/general" {
				t.Fatalf("landed on %s", landed)
			}
			code, s := session(t, c, r)
			if code != http.StatusOK {
				t.Fatalf("session = %d", code)
			}
			if s.Provider != p || s.Email != "alice@example.com" || s.Subject != "sub-123" || s.Tenant != "t1" ||
				s.HumanID != "HUM-"+p+"-sub-123@t1" || s.Exp <= s.IssuedAt {
				t.Fatalf("session claims %+v", s)
			}
			// logout clears it
			req, _ := http.NewRequest(http.MethodPost, r.hub+"/api/v1/auth/logout", nil)
			resp, err := c.Do(req)
			if err != nil || resp.StatusCode != http.StatusNoContent {
				t.Fatalf("logout: %v %v", err, resp)
			}
			if code, _ := session(t, c, r); code != http.StatusUnauthorized {
				t.Fatalf("session after logout = %d", code)
			}
		})
	}
}

func authError(u *url.URL) string {
	if u.Path != "/login" {
		return "landed on " + u.String()
	}
	return u.Query().Get("auth_error")
}

func TestCallbackFailuresLandOnLogin(t *testing.T) {
	t.Run("consent denied", func(t *testing.T) {
		r := newRig(t, registrar{})
		r.fake.Set(alice, true)
		if got := authError(signIn(t, browser(t), r, "google", "?redirect=/c/x")); got != auth.ErrCodeCancelled {
			t.Fatalf("auth_error = %q", got)
		}
	})
	for _, p := range []string{"google", "facebook"} {
		t.Run("unverified email "+p, func(t *testing.T) {
			r := newRig(t, registrar{})
			unverified := alice
			unverified.EmailVerified = false
			r.fake.Set(unverified, false)
			c := browser(t)
			if got := authError(signIn(t, c, r, p, "")); got != auth.ErrCodeUnverified {
				t.Fatalf("auth_error = %q", got)
			}
			if code, _ := session(t, c, r); code != http.StatusUnauthorized {
				t.Fatal("a refused sign-in left a session")
			}
		})
	}
	// spec 049 FR-F4: Facebook's own denial shape, on a state that is valid
	// (the control: the same rig signs in when consent is given).
	t.Run("consent denied facebook (Graph parameters)", func(t *testing.T) {
		r := newRig(t, registrar{})
		c := browser(t)
		st := startState(t, c, r, "facebook")
		resp, err := c.Get(r.hub + "/api/v1/auth/facebook/callback?" + url.Values{"state": {st},
			"error": {"access_denied"}, "error_code": {"200"}, "error_description": {"Permissions error"},
			"error_reason": {"user_denied"}}.Encode())
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if got := authError(resp.Request.URL); got != auth.ErrCodeCancelled {
			t.Fatalf("auth_error = %q", got)
		}
		if code, _ := session(t, c, r); code != http.StatusUnauthorized {
			t.Fatal("a denied sign-in left a session")
		}
		signIn(t, c, r, "facebook", "")
		if code, s := session(t, c, r); code != http.StatusOK || s.Provider != auth.ProviderFacebook {
			t.Fatalf("control: consent given, session %d %+v", code, s)
		}
	})
	t.Run("registrar refuses", func(t *testing.T) {
		r := newRig(t, registrar{refuse: true})
		if got := authError(signIn(t, browser(t), r, "facebook", "")); got != auth.ErrCodeNotAllowed {
			t.Fatalf("auth_error = %q", got)
		}
	})
}

// startState begins a flow without following it and returns the signed state
// the hub sent to the IdP (the browser jar now holds the state cookie).
func startState(t *testing.T, c *http.Client, r *rig, provider string) string {
	t.Helper()
	resp, err := noFollow(c).Get(r.hub + "/api/v1/auth/" + provider + "/start")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	loc, err := url.Parse(resp.Header.Get("Location"))
	if err != nil || resp.StatusCode != http.StatusFound {
		t.Fatalf("start: %d %v", resp.StatusCode, err)
	}
	return loc.Query().Get("state")
}

func callback(t *testing.T, c *http.Client, r *rig, provider, state, code string) string {
	t.Helper()
	resp, err := c.Get(r.hub + "/api/v1/auth/" + provider + "/callback?" +
		url.Values{"state": {state}, "code": {code}}.Encode())
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return authError(resp.Request.URL)
}

func TestStateCSRF(t *testing.T) {
	r := newRig(t, registrar{})

	t.Run("forged state", func(t *testing.T) {
		c := browser(t)
		startState(t, c, r, "google")
		if got := callback(t, c, r, "google", "eyJwIjoiZ29vZ2xlIn0.AAAA", "x"); got != auth.ErrCodeState {
			t.Fatalf("auth_error = %q", got)
		}
	})
	t.Run("state from another browser", func(t *testing.T) {
		st := startState(t, browser(t), r, "google")
		if got := callback(t, browser(t), r, "google", st, "x"); got != auth.ErrCodeState {
			t.Fatalf("auth_error = %q", got)
		}
	})
	t.Run("cross-provider replay", func(t *testing.T) {
		c := browser(t)
		st := startState(t, c, r, "google")
		if got := callback(t, c, r, "facebook", st, "x"); got != auth.ErrCodeState {
			t.Fatalf("auth_error = %q", got)
		}
	})
	t.Run("state cookie is single use", func(t *testing.T) {
		c := browser(t)
		st := startState(t, c, r, "facebook")
		callback(t, c, r, "facebook", st, "bogus")
		if got := callback(t, c, r, "facebook", st, "bogus"); got != auth.ErrCodeState {
			t.Fatalf("replayed state: auth_error = %q", got)
		}
	})
	t.Run("valid state, bad code", func(t *testing.T) {
		c := browser(t)
		st := startState(t, c, r, "google")
		if got := callback(t, c, r, "google", st, "not-a-code"); got != auth.ErrCodeExchange {
			t.Fatalf("auth_error = %q", got)
		}
	})
}

func TestStartRedirectsToProvider(t *testing.T) {
	r := newRig(t, registrar{})
	c := browser(t)
	resp, err := noFollow(c).Get(r.hub + "/api/v1/auth/facebook/start?redirect=https://evil.example")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	loc, _ := url.Parse(resp.Header.Get("Location"))
	q := loc.Query()
	if loc.Path != auth.FacebookDialogPath || q.Get("client_id") != "fid" || q.Get("scope") != "email,public_profile" ||
		q.Get("redirect_uri") != r.hub+"/api/v1/auth/facebook/callback" || q.Get("state") == "" {
		t.Fatalf("dialog URL %s", loc)
	}
	var sawCookie bool
	for _, ck := range resp.Cookies() {
		sawCookie = sawCookie || (ck.Name == "spool_oauth_state" && ck.HttpOnly && ck.Value != "")
	}
	if !sawCookie {
		t.Fatal("no HttpOnly state cookie")
	}
	// the open redirect was dropped: the landing is "/"
	if landed := signIn(t, browser(t), r, "google", "?redirect=//evil.example"); landed.Path != "/" {
		t.Fatalf("landed on %s", landed)
	}
}

func TestProvidersAndUnknown(t *testing.T) {
	r := newRig(t, registrar{})
	resp, err := http.Get(r.hub + "/api/v1/auth/providers")
	if err != nil {
		t.Fatal(err)
	}
	var body struct{ Providers []string }
	json.NewDecoder(resp.Body).Decode(&body) //nolint:errcheck
	resp.Body.Close()
	if strings.Join(body.Providers, ",") != "google,facebook" {
		t.Fatalf("providers %v", body.Providers)
	}
	for _, p := range []string{"microsoft", "nope"} {
		resp, _ := noFollow(browser(t)).Get(r.hub + "/api/v1/auth/" + p + "/start")
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("%s start = %d", p, resp.StatusCode)
		}
	}
}

func TestTamperedSessionCookie(t *testing.T) {
	r := newRig(t, registrar{})
	c := browser(t)
	signIn(t, c, r, "google", "")
	hubURL, _ := url.Parse(r.hub)
	var tok string
	for _, ck := range c.Jar.Cookies(hubURL) {
		if ck.Name == "spool_session" {
			tok = ck.Value
		}
	}
	if tok == "" {
		t.Fatal("no session cookie")
	}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.AddCookie(&http.Cookie{Name: "spool_session", Value: tok})
	if _, ok := r.h.SessionFromRequest(req); !ok {
		t.Fatal("genuine cookie rejected")
	}
	req = httptest.NewRequest(http.MethodGet, "/", nil)
	req.AddCookie(&http.Cookie{Name: "spool_session", Value: "x" + tok})
	if _, ok := r.h.SessionFromRequest(req); ok {
		t.Fatal("tampered cookie accepted")
	}
}

func TestAuthOffServesEmptyList(t *testing.T) {
	cfg, err := auth.LoadFrom("prd", map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(auth.New(cfg, zerolog.Nop(), auth.Options{}))
	defer srv.Close()
	resp, _ := http.Get(srv.URL + "/api/v1/auth/providers")
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if strings.TrimSpace(string(b)) != `{"providers":[]}` {
		t.Fatalf("providers body %s", b)
	}
	// CLE-35076: the browser keeps the list 5 minutes; nothing shared keeps it
	if cc := resp.Header.Get("Cache-Control"); cc != "private, max-age=300" {
		t.Fatalf("providers Cache-Control %q, want private, max-age=300", cc)
	}
	resp, _ = http.Get(srv.URL + "/api/v1/auth/session")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("session with auth off = %d", resp.StatusCode)
	}
}

type members map[string]bool // "hum|tenant" -> member

func (m members) Member(_ context.Context, hum, tenant string) (bool, error) {
	return m[hum+"|"+tenant], nil
}

// SessionForTenant: membership decides, never session.t, and it fails closed.
func TestSessionForTenant(t *testing.T) {
	signedIn := func(t *testing.T, reg auth.Registrar, m auth.Membership) (*rig, *http.Request) {
		r := newRigWith(t, auth.Options{Registrar: reg, Membership: m})
		c := browser(t)
		signIn(t, c, r, "google", "?tenant=t1")
		hubURL, _ := url.Parse(r.hub)
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		for _, ck := range c.Jar.Cookies(hubURL) {
			req.AddCookie(ck)
		}
		return r, req
	}
	hum := "HUM-google-sub-123@t1"

	r, req := signedIn(t, registrar{}, members{hum + "|t2": true})
	if s, err := r.h.SessionForTenant(req, "t2"); err != nil || s.HumanID != hum {
		t.Fatalf("member of t2: %v %+v", err, s)
	}
	if _, err := r.h.SessionForTenant(req, "t1"); err != auth.ErrNotMember {
		t.Fatalf("session.t=t1 must not grant t1: %v", err)
	}
	if _, err := r.h.SessionForTenant(httptest.NewRequest(http.MethodGet, "/", nil), "t2"); err != auth.ErrNoSession {
		t.Fatalf("no cookie: %v", err)
	}

	r, req = signedIn(t, registrar{}, nil)
	if _, err := r.h.SessionForTenant(req, "t1"); err != auth.ErrNoMembership {
		t.Fatalf("no Membership configured: %v", err)
	}

	r, req = signedIn(t, nil, members{"|t1": true})
	if _, err := r.h.SessionForTenant(req, "t1"); err != auth.ErrNoHuman {
		t.Fatalf("session without HUM-*: %v", err)
	}
}
