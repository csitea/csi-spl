package auth_test

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
)

var oidcProviders = []string{auth.ProviderMicrosoft, auth.ProviderLinkedIn, auth.ProviderXAI}

// unlinker records the (provider, subject) pairs the Meta callbacks sever.
type unlinker struct {
	mu   sync.Mutex
	got  []string
	fail bool
}

func (u *unlinker) Unlink(_ context.Context, provider, subject string) error {
	u.mu.Lock()
	defer u.mu.Unlock()
	u.got = append(u.got, provider+"|"+subject)
	if u.fail {
		return context.DeadlineExceeded
	}
	return nil
}

func (u *unlinker) calls() []string {
	u.mu.Lock()
	defer u.mu.Unlock()
	return append([]string(nil), u.got...)
}

// newRigAll is newRigWith with every provider enabled against one fake IdP;
// Microsoft's fake userinfo omits email_verified like the real one.
func newRigAll(t *testing.T, opts auth.Options, extra map[string]string) *rig {
	t.Helper()
	var hubH http.Handler
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hubH.ServeHTTP(w, r) }))
	t.Cleanup(hub.Close)
	wui := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("wui " + r.URL.RequestURI())) //nolint:errcheck
	}))
	t.Cleanup(wui.Close)
	cb := func(p string) string { return hub.URL + "/api/v1/auth/" + p + "/callback" }
	g := fakeidp.Client{ID: "gid", Secret: "gsecret", RedirectURI: cb("google")}
	f := fakeidp.Client{ID: "fid", Secret: "fsecret", RedirectURI: cb("facebook")}
	fake := fakeidp.New(g, f, alice).
		AddOIDC("microsoft", fakeidp.Client{ID: "mid", Secret: "msecret", RedirectURI: cb("microsoft"), NoEmailVerifiedClaim: true}).
		AddOIDC("linkedin", fakeidp.Client{ID: "lid", Secret: "lsecret", RedirectURI: cb("linkedin")}).
		AddOIDC("xai", fakeidp.Client{ID: "xid", Secret: "xsecret", RedirectURI: cb("xai")})
	idp := httptest.NewServer(fake.Handler())
	t.Cleanup(idp.Close)
	vars := map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":               "google,facebook,microsoft,linkedin,xai",
		"SPOOL_HUB_AUTH_SESSION_KEY":             strings.Repeat("s", 32),
		"SPOOL_HUB_AUTH_APP_URL":                 wui.URL,
		"SPOOL_HUB_AUTH_COOKIE_SECURE":           "false",
		"SPOOL_HUB_AUTH_IDP_BASE_URL":            idp.URL,
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID":        "gid",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET":    "gsecret",
		"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI":     cb("google"),
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID":      "fid",
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET":  "fsecret",
		"SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI":   cb("facebook"),
		"SPOOL_HUB_AUTH_MICROSOFT_CLIENT_ID":     "mid",
		"SPOOL_HUB_AUTH_MICROSOFT_CLIENT_SECRET": "msecret",
		"SPOOL_HUB_AUTH_MICROSOFT_REDIRECT_URI":  cb("microsoft"),
		"SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID":      "lid",
		"SPOOL_HUB_AUTH_LINKEDIN_CLIENT_SECRET":  "lsecret",
		"SPOOL_HUB_AUTH_LINKEDIN_REDIRECT_URI":   cb("linkedin"),
		"SPOOL_HUB_AUTH_XAI_CLIENT_ID":           "xid",
		"SPOOL_HUB_AUTH_XAI_CLIENT_SECRET":       "xsecret",
		"SPOOL_HUB_AUTH_XAI_REDIRECT_URI":        cb("xai"),
		"SPOOL_HUB_AUTH_XAI_AUTH_URL":            "https://idp.example.com/oauth2/authorize",
		"SPOOL_HUB_AUTH_XAI_TOKEN_URL":           "https://idp.example.com/oauth2/token",
		"SPOOL_HUB_AUTH_XAI_USERINFO_URL":        "https://idp.example.com/oauth2/userinfo",
	}
	for k, v := range extra {
		vars[k] = v
	}
	cfg, err := auth.LoadFrom("lde", vars)
	if err != nil {
		t.Fatal(err)
	}
	h := auth.New(cfg, zerolog.Nop(), opts)
	hubH = h
	return &rig{hub: hub.URL, wui: wui.URL, fake: fake, h: h}
}

func TestOIDCSignInEachProvider(t *testing.T) {
	r := newRigAll(t, auth.Options{Registrar: registrar{}}, nil)
	resp, err := http.Get(r.hub + "/api/v1/auth/providers")
	if err != nil {
		t.Fatal(err)
	}
	var body struct{ Providers []string }
	json.NewDecoder(resp.Body).Decode(&body) //nolint:errcheck
	resp.Body.Close()
	if got := strings.Join(body.Providers, ","); got != "google,facebook,microsoft,linkedin,xai" {
		t.Fatalf("providers %s", got)
	}
	for _, p := range oidcProviders {
		t.Run(p, func(t *testing.T) {
			c := browser(t)
			if landed := signIn(t, c, r, p, "?redirect=/c/general&tenant=t1"); landed.Path != "/c/general" {
				t.Fatalf("landed on %s", landed)
			}
			code, s := session(t, c, r)
			sub := "sub-123"
			if p == auth.ProviderMicrosoft { // spec 018 FR-004: <tid>/<oid>
				sub = auth.MicrosoftConsumersTenantID + "/" + fakeidp.MicrosoftOID("sub-123")
			}
			if code != http.StatusOK || s.Provider != p || s.Email != "alice@example.com" || s.Subject != sub ||
				s.HumanID != "HUM-"+p+"-"+sub+"@t1" {
				t.Fatalf("session %d %+v", code, s)
			}
		})
	}
}

func TestOIDCStartCarriesNonceAndClient(t *testing.T) {
	r := newRigAll(t, auth.Options{}, nil)
	for _, p := range oidcProviders {
		resp, err := noFollow(browser(t)).Get(r.hub + "/api/v1/auth/" + p + "/start")
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		loc, _ := url.Parse(resp.Header.Get("Location"))
		q := loc.Query()
		path := auth.OIDCAuthPath(p)
		if p == auth.ProviderMicrosoft { // spec 018: Microsoft-shaped authority path
			path = "/" + auth.MicrosoftAuthPath(auth.MicrosoftCommon)
		}
		if loc.Path != path || q.Get("client_id") == "" || q.Get("nonce") == "" ||
			q.Get("response_type") != "code" || q.Get("redirect_uri") != r.hub+"/api/v1/auth/"+p+"/callback" ||
			!strings.Contains(q.Get("scope"), "openid") {
			t.Fatalf("%s authorize URL %s", p, loc)
		}
	}
}

// email_verified is required for LinkedIn and xAI; Microsoft (consumers
// tenant) has no such claim and is trusted by construction (OQ-I1 (a)).
func TestOIDCEmailVerification(t *testing.T) {
	unverified := alice
	unverified.EmailVerified = false
	for _, p := range []string{auth.ProviderLinkedIn, auth.ProviderXAI} {
		t.Run(p, func(t *testing.T) {
			r := newRigAll(t, auth.Options{}, nil)
			r.fake.Set(unverified, false)
			c := browser(t)
			if got := authError(signIn(t, c, r, p, "")); got != auth.ErrCodeUnverified {
				t.Fatalf("auth_error = %q", got)
			}
			if code, _ := session(t, c, r); code != http.StatusUnauthorized {
				t.Fatal("unverified email left a session")
			}
		})
	}
	t.Run("microsoft consumers", func(t *testing.T) {
		r := newRigAll(t, auth.Options{}, nil)
		r.fake.Set(unverified, false) // claim is omitted by the fake anyway
		c := browser(t)
		signIn(t, c, r, auth.ProviderMicrosoft, "")
		if code, _ := session(t, c, r); code != http.StatusOK {
			t.Fatalf("microsoft consumers sign-in: session %d", code)
		}
	})
	t.Run("no email at all", func(t *testing.T) {
		r := newRigAll(t, auth.Options{}, nil)
		noMail := alice
		noMail.Email = ""
		r.fake.Set(noMail, false)
		if got := authError(signIn(t, browser(t), r, auth.ProviderMicrosoft, "")); got != auth.ErrCodeUnverified {
			t.Fatalf("auth_error = %q", got)
		}
	})
}

// CONTROL: a callback whose state is forged, bound to another browser's
// nonce, carries a tampered nonce cookie, or was minted for another provider
// is refused and sets no session — while the same browser with its own state
// and cookie is admitted (the positive half of the control).
func TestOIDCBadStateOrNonceRefused(t *testing.T) {
	r := newRigAll(t, auth.Options{}, nil)
	hubURL, _ := url.Parse(r.hub)
	for _, p := range oidcProviders {
		t.Run(p+" forged state", func(t *testing.T) {
			c := browser(t)
			startState(t, c, r, p)
			if got := callback(t, c, r, p, "eyJwIjoieGFpIn0.AAAA", "x"); got != auth.ErrCodeState {
				t.Fatalf("auth_error = %q", got)
			}
		})
		t.Run(p+" other browser's nonce", func(t *testing.T) {
			st := startState(t, browser(t), r, p)
			c := browser(t)
			startState(t, c, r, p) // c holds a nonce cookie, just not this state's
			if got := callback(t, c, r, p, st, "x"); got != auth.ErrCodeState {
				t.Fatalf("auth_error = %q", got)
			}
			if code, _ := session(t, c, r); code != http.StatusUnauthorized {
				t.Fatal("refused callback left a session")
			}
		})
		t.Run(p+" tampered nonce cookie", func(t *testing.T) {
			c := browser(t)
			st := startState(t, c, r, p)
			c.Jar.SetCookies(&url.URL{Scheme: "http", Host: hubURL.Host, Path: "/api/v1/auth/"},
				[]*http.Cookie{{Name: "spool_oauth_state", Value: "not-the-nonce", Path: "/api/v1/auth/"}})
			if got := callback(t, c, r, p, st, "x"); got != auth.ErrCodeState {
				t.Fatalf("auth_error = %q", got)
			}
		})
		t.Run(p+" state minted for google", func(t *testing.T) {
			c := browser(t)
			st := startState(t, c, r, auth.ProviderGoogle)
			if got := callback(t, c, r, p, st, "x"); got != auth.ErrCodeState {
				t.Fatalf("auth_error = %q", got)
			}
		})
		t.Run(p+" positive control", func(t *testing.T) {
			c := browser(t)
			signIn(t, c, r, p, "")
			if code, _ := session(t, c, r); code != http.StatusOK {
				t.Fatalf("genuine flow refused: %d", code)
			}
		})
	}
}

// signedRequest builds Meta's `<b64url sig>.<b64url payload>` envelope.
func signedRequest(secret string, payload map[string]any) string {
	raw, _ := json.Marshal(payload)
	p := base64.RawURLEncoding.EncodeToString(raw)
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(p))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil)) + "." + p
}

func postForm(t *testing.T, u string, v url.Values) (*http.Response, map[string]string) {
	t.Helper()
	resp, err := http.PostForm(u, v)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body) //nolint:errcheck
	return resp, body
}

func TestFacebookMetaCallbacks(t *testing.T) {
	good := signedRequest("fsecret", map[string]any{"algorithm": "HMAC-SHA256", "issued_at": 1789759591, "user_id": "fb-42"})
	refused := map[string]string{
		"missing":         "",
		"wrong secret":    signedRequest("not-the-secret", map[string]any{"algorithm": "HMAC-SHA256", "user_id": "fb-42"}),
		"wrong algorithm": signedRequest("fsecret", map[string]any{"algorithm": "none", "user_id": "fb-42"}),
		"no user":         signedRequest("fsecret", map[string]any{"algorithm": "HMAC-SHA256"}),
		"tampered":        good[:len(good)-2] + "AA",
		"no separator":    "abc",
	}
	for _, route := range []string{"deauthorize", "data-deletion"} {
		u := &unlinker{}
		r := newRigAll(t, auth.Options{Unlinker: u}, nil)
		base := r.hub + "/api/v1/auth/facebook/" + route
		for name, sr := range refused {
			if resp, _ := postForm(t, base, url.Values{"signed_request": {sr}}); resp.StatusCode != http.StatusBadRequest {
				t.Errorf("%s %s: status %d, want 400", route, name, resp.StatusCode)
			}
		}
		if n := len(u.calls()); n != 0 {
			t.Fatalf("%s: a refused request reached the unlinker (%d calls)", route, n)
		}
		resp, body := postForm(t, base, url.Values{"signed_request": {good}})
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("%s valid: %d", route, resp.StatusCode)
		}
		if got := u.calls(); len(got) != 1 || got[0] != "facebook|fb-42" {
			t.Fatalf("%s unlinked %v", route, got)
		}
		if route != "data-deletion" {
			continue
		}
		code := body["confirmation_code"]
		if code == "" || !strings.HasPrefix(body["url"], r.wui+"/api/v1/auth/facebook/data-deletion?code=") {
			t.Fatalf("data-deletion body %v", body)
		}
		// the WUI origin rewrites /api/v1/auth/** to the hub (FR-010): ask the hub
		st, err := http.Get(r.hub + "/api/v1/auth/facebook/data-deletion?code=" + url.QueryEscape(code))
		if err != nil || st.StatusCode != http.StatusOK {
			t.Fatalf("status for issued code: %v %v", err, st)
		}
		st.Body.Close()
		// flip the last MAC hex digit to one that always differs from it
		last := "0"
		if code[len(code)-1] == '0' {
			last = "1"
		}
		forged := code[:len(code)-1] + last
		st, _ = http.Get(r.hub + "/api/v1/auth/facebook/data-deletion?code=" + url.QueryEscape(forged))
		if st.StatusCode != http.StatusNotFound {
			t.Fatalf("forged code status %d, want 404", st.StatusCode)
		}
		st.Body.Close()
		// spec 049 FR-F6: the person Meta sends here gets a page, not JSON
		for c, want := range map[string]int{code: http.StatusOK, forged: http.StatusNotFound} {
			req, _ := http.NewRequest(http.MethodGet, r.hub+"/api/v1/auth/facebook/data-deletion?code="+url.QueryEscape(c), nil)
			req.Header.Set("Accept", "text/html,application/xhtml+xml,*/*;q=0.8")
			pg, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			b, _ := io.ReadAll(pg.Body)
			pg.Body.Close()
			shows := strings.Contains(string(b), "Status: completed") && strings.Contains(string(b), code)
			if pg.StatusCode != want || !strings.HasPrefix(pg.Header.Get("Content-Type"), "text/html") ||
				!strings.HasPrefix(pg.Header.Get("Content-Security-Policy"), "default-src 'none'") ||
				shows != (want == http.StatusOK) || strings.Contains(string(b), "<script") {
				t.Fatalf("status page for %s: %d %q %s", c, pg.StatusCode, pg.Header.Get("Content-Type"), b)
			}
		}
	}

	t.Run("unlinker failure is a 500, not a silent ok", func(t *testing.T) {
		r := newRigAll(t, auth.Options{Unlinker: &unlinker{fail: true}}, nil)
		if resp, _ := postForm(t, r.hub+"/api/v1/auth/facebook/deauthorize", url.Values{"signed_request": {good}}); resp.StatusCode != http.StatusInternalServerError {
			t.Fatalf("status %d", resp.StatusCode)
		}
	})
	t.Run("facebook disabled", func(t *testing.T) {
		r := newRigAll(t, auth.Options{}, map[string]string{"SPOOL_HUB_AUTH_PROVIDERS": "google"})
		for _, route := range []string{"deauthorize", "data-deletion"} {
			if resp, _ := postForm(t, r.hub+"/api/v1/auth/facebook/"+route, url.Values{"signed_request": {good}}); resp.StatusCode != http.StatusNotFound {
				t.Fatalf("%s with facebook off: %d", route, resp.StatusCode)
			}
		}
	})
}

// TestExchangeKeepsDecodeError: an IdP that answers 200 with a body that does
// not decode fails the sign-in (errExchange, as before) and the decode error
// stays in the message, so an IdP outage is not logged as a status mismatch.
func TestExchangeKeepsDecodeError(t *testing.T) {
	idp := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "{")
	}))
	t.Cleanup(idp.Close)
	o := &auth.OIDC{Provider: auth.ProviderLinkedIn, TokenURL: idp.URL + "/token", HTTP: idp.Client()}
	_, err := o.Exchange(context.Background(), "code")
	if !errors.Is(err, auth.ErrExchange) {
		t.Fatalf("err %v, want errExchange", err)
	}
	// readJSON uses json.Unmarshal: a truncated body is a *json.SyntaxError
	// ("unexpected end of JSON input"), not io.ErrUnexpectedEOF.
	var syn *json.SyntaxError
	if !errors.As(err, &syn) || !strings.Contains(err.Error(), "unexpected end of JSON input") {
		t.Fatalf("err %q lost the decode cause", err)
	}
}

// TestExchangeTokenOutcomes pins exchangeToken, the token step shared by
// Google, Facebook and the generic OIDC client: only a 200 with an access
// token succeeds, every other reply wraps errExchange.
func TestExchangeTokenOutcomes(t *testing.T) {
	cases := []struct {
		name, body, want string
		status           int
	}{
		{"ok", `{"access_token":"at"}`, "", http.StatusOK},
		{"broken body", `{`, "decode: unexpected end of JSON input", http.StatusOK},
		{"idp error", `{"error":"invalid_grant"}`, "token status 400 invalid_grant", http.StatusBadRequest},
		{"no access token", `{}`, "token status 200", http.StatusOK},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			idp := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(c.status)
				_, _ = io.WriteString(w, c.body)
			}))
			t.Cleanup(idp.Close)
			req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, idp.URL, nil)
			if err != nil {
				t.Fatal(err)
			}
			tok, err := auth.ExchangeToken(idp.Client(), req)
			if c.want == "" {
				if err != nil || tok.AccessToken != "at" {
					t.Fatalf("tok %+v err %v", tok, err)
				}
				return
			}
			if !errors.Is(err, auth.ErrExchange) || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err %v, want errExchange carrying %q", err, c.want)
			}
		})
	}
}
