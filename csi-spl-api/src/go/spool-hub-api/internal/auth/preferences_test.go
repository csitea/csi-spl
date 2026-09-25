package auth_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// fakePrefs keeps preferred_locale per HUM-*, resolving identities through
// the rig's recording Registrar (store.AuthHooks in the hub).
type fakePrefs struct {
	mu   sync.Mutex
	reg  *recReg
	loc  map[string]string
	diag map[string]bool   // CLE-34963 "Debug pane", nil until first set
	name map[string]string // CLE-34968 display name, nil until first set
	fail error             // non-nil: DiagnosticsEnabled answers it
}

func (p *fakePrefs) known(hum string) bool {
	p.reg.mu.Lock()
	defer p.reg.mu.Unlock()
	for _, h := range p.reg.ids {
		if h == hum {
			return true
		}
	}
	return false
}

func (p *fakePrefs) PreferredLocale(_ context.Context, hum string) (string, error) {
	if !p.known(hum) {
		return "", auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.loc[hum], nil
}

func (p *fakePrefs) SetPreferredLocale(_ context.Context, hum, loc string) error {
	if !p.known(hum) {
		return auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.loc[hum] = loc
	return nil
}

func (p *fakePrefs) DiagnosticsEnabled(_ context.Context, hum string) (bool, error) {
	if !p.known(hum) {
		return false, auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.fail != nil {
		return true, p.fail
	}
	return p.diag[hum], nil
}

func (p *fakePrefs) SetDiagnosticsEnabled(_ context.Context, hum string, on bool) error {
	if !p.known(hum) {
		return auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.diag == nil {
		p.diag = map[string]bool{}
	}
	p.diag[hum] = on
	return nil
}

func (p *fakePrefs) DisplayName(_ context.Context, hum string) (string, error) {
	if !p.known(hum) {
		return "", auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.name[hum], nil
}

func (p *fakePrefs) SetDisplayName(_ context.Context, hum, name string) error {
	if !p.known(hum) {
		return auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.name == nil {
		p.name = map[string]string{}
	}
	p.name[hum] = name
	return nil
}

func (p *fakePrefs) IdentityLocale(_ context.Context, provider, subject string) (string, error) {
	p.reg.mu.Lock()
	hum := p.reg.ids[provider+"/"+subject]
	p.reg.mu.Unlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.loc[hum], nil
}

// newPRig is newNRig with Preferences and a configurable default locale.
func newPRig(t *testing.T, defLocale string, withRegistrar bool) (*nrig, *fakePrefs) {
	t.Helper()
	r := &nrig{box: &mail.Recorder{}, reg: &recReg{}, store: auth.NewMemoryCredStore(),
		t: time.Date(2026, 9, 19, 6, 0, 0, 0, time.UTC)}
	prefs := &fakePrefs{reg: r.reg, loc: map[string]string{}}
	var hubH http.Handler
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) { hubH.ServeHTTP(w, q) }))
	t.Cleanup(srv.Close)
	r.url = srv.URL
	cfg, err := auth.LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_SESSION_KEY":   strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":       "http://app.example.test",
		"SPOOL_HUB_AUTH_COOKIE_SECURE": "false",
	})
	if err != nil {
		t.Fatal(err)
	}
	nc, err := auth.LoadNativeFrom("lde", nativeBase)
	if err != nil {
		t.Fatal(err)
	}
	o := auth.Options{Preferences: prefs, DefaultLocale: defLocale, Now: r.now}
	if withRegistrar {
		o.Registrar = r.reg
	}
	r.h = auth.New(cfg, zerolog.Nop(), o)
	if err := r.h.EnableNative(nc, auth.NativeDeps{Store: r.store, Sender: r.box, Delivers: true}); err != nil {
		t.Fatal(err)
	}
	hubH = r.h
	return r, prefs
}

// call sends one request with optional headers ("K", "V", ...).
func (r *nrig) call(t *testing.T, c *http.Client, method, path, body string, hdr ...string) resp {
	t.Helper()
	req, _ := http.NewRequest(method, r.url+"/api/v1/auth/"+path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	if c == nil {
		c = http.DefaultClient
	}
	res, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	out := resp{code: res.StatusCode, hdr: res.Header, raw: string(raw)}
	_ = json.Unmarshal(raw, &out.body)
	return out
}

func jsonBody(v any) string { b, _ := json.Marshal(v); return string(b) }

func (r *nrig) lastMail(t *testing.T, template string) mail.Message {
	t.Helper()
	msgs := r.box.Messages()
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].Template == template {
			return msgs[i]
		}
	}
	t.Fatalf("no %s mail", template)
	return mail.Message{}
}

// signedIn registers, verifies and logs email in on c; returns the session.
func (r *nrig) signedIn(t *testing.T, c *http.Client, email string) {
	t.Helper()
	r.registerVerified(t, email, pwA)
	if got := r.post(t, c, "login", map[string]string{"email": email, "password": pwA, "tenant": "acme"}); got.code != http.StatusOK {
		t.Fatalf("login: %d %s", got.code, got.raw)
	}
}

func TestPreferencesSetReflectsInSession(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")

	got := r.call(t, c, http.MethodGet, "session", "")
	if v, ok := got.body["preferred_locale"]; got.code != http.StatusOK || !ok || v != nil || got.body["hum"] == nil {
		t.Fatalf("session before: %d %s", got.code, got.raw)
	}
	got = r.call(t, c, http.MethodPut, "preferences", `{"preferred_locale":"fi"}`)
	if got.code != http.StatusOK || got.body["preferred_locale"] != "fi" || got.hdr.Get("Cache-Control") != "no-store" {
		t.Fatalf("put: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["preferred_locale"] != "fi" {
		t.Fatalf("session after: %s", got.raw)
	}
	// null clears it again
	if got = r.call(t, c, http.MethodPut, "preferences", `{"preferred_locale":null}`); got.code != http.StatusOK || got.body["preferred_locale"] != nil {
		t.Fatalf("clear: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["preferred_locale"] != nil {
		t.Fatalf("session after clear: %s", got.raw)
	}
}

func TestPreferencesRejectsBadInput(t *testing.T) {
	r, prefs := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	for body, want := range map[string]int{
		`{"preferred_locale":"de"}`:    http.StatusBadRequest,
		`{"preferred_locale":"FI"}`:    http.StatusBadRequest,
		`{"preferred_locale":"fi-FI"}`: http.StatusBadRequest,
		`{"preferred_locale":""}`:      http.StatusBadRequest,
		`{"preferred_locale":7}`:       http.StatusBadRequest,
		`{}`:                           http.StatusBadRequest,
		`not json`:                     http.StatusBadRequest,
	} {
		if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != want {
			t.Errorf("%s: %d %s", body, got.code, got.raw)
		}
	}
	if got := r.call(t, c, http.MethodPut, "preferences", `{"preferred_locale":"de"}`); got.body["error"] != "unsupported_locale" {
		t.Errorf("error token: %s", got.raw)
	}
	// JSON only: a form post is 415 (the CSRF posture of the native POSTs)
	req, _ := http.NewRequest(http.MethodPut, r.url+"/api/v1/auth/preferences", bytes.NewReader([]byte("preferred_locale=fi")))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if res, err := c.Do(req); err != nil || res.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("form: %v %v", res, err)
	}
	if len(prefs.loc) != 0 {
		t.Fatalf("a refused PUT stored something: %v", prefs.loc)
	}
}

func TestPreferencesNeedSession(t *testing.T) {
	r, prefs := newPRig(t, "", true)
	if got := r.call(t, nil, http.MethodPut, "preferences", `{"preferred_locale":"fi"}`); got.code != http.StatusUnauthorized {
		t.Fatalf("no session: %d %s", got.code, got.raw)
	}
	// a forged cookie is no session either
	req, _ := http.NewRequest(http.MethodPut, r.url+"/api/v1/auth/preferences", strings.NewReader(`{"preferred_locale":"fi"}`))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: "spool_session", Value: "eyJ2IjoxfQ.forged"})
	if res, err := http.DefaultClient.Do(req); err != nil || res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("forged: %v %v", res, err)
	}
	if len(prefs.loc) != 0 {
		t.Fatalf("stored without a session: %v", prefs.loc)
	}
	// CONTROL: the same request with a real session is accepted.
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	if got := r.call(t, c, http.MethodPut, "preferences", `{"preferred_locale":"fi"}`); got.code != http.StatusOK {
		t.Fatalf("control: %d %s", got.code, got.raw)
	}
}

// A session with no registered human (no Registrar wired) has nowhere to keep it.
func TestPreferencesWithoutHumanIs409(t *testing.T) {
	r, _ := newPRig(t, "", false)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	if got := r.call(t, c, http.MethodPut, "preferences", `{"preferred_locale":"fi"}`); got.code != http.StatusConflict || got.body["error"] != "no_human" {
		t.Fatalf("%d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodGet, "session", ""); got.code != http.StatusOK || got.body["preferred_locale"] != nil {
		t.Fatalf("session: %d %s", got.code, got.raw)
	}
}

// The verify link carries the request locale as a prefix, except the default.
func TestRegisterMailFollowsRequestLocale(t *testing.T) {
	r, _ := newPRig(t, "", true) // default en (cnf / i18n.DefaultLocale)
	cases := []struct {
		email  string
		hdr    []string
		locale string
		prefix string
	}{
		{"a@example.com", nil, "en", ""},
		{"b@example.com", []string{"X-Locale", "fi"}, "fi", "/fi"},
		{"c@example.com", []string{"Accept-Language", "sv-SE,sv;q=0.9"}, "sv", "/sv"},
		{"d@example.com", []string{"X-Locale", "he", "Accept-Language", "sv-SE"}, "he", "/he"},
		{"e@example.com", []string{"Accept-Language", "de-DE"}, "en", ""},
	}
	for _, c := range cases {
		got := r.call(t, nil, http.MethodPost, "register", jsonBody(map[string]string{"email": c.email, "password": pwA}), c.hdr...)
		if got.code != http.StatusAccepted {
			t.Fatalf("%s: %d %s", c.email, got.code, got.raw)
		}
		m := r.lastMail(t, mail.TemplateEmailVerification)
		if m.To != c.email || m.Locale != c.locale || !strings.Contains(m.TextBody, "\nhttp://app.example.test"+c.prefix+"/verify-email?token=") {
			t.Errorf("%s: locale=%s body:\n%s", c.email, m.Locale, m.TextBody)
		}
		cred, _ := r.store.GetCredential(context.Background(), c.email)
		if cred.Locale != c.locale {
			t.Errorf("%s: stored registration locale %q", c.email, cred.Locale)
		}
	}
}

// DefaultLocale is cnf: with "en" the English link has no prefix and bg has one.
func TestDefaultLocaleIsConfigurable(t *testing.T) {
	r, _ := newPRig(t, "en", true)
	r.call(t, nil, http.MethodPost, "register", jsonBody(map[string]string{"email": "a@example.com", "password": pwA}))
	if m := r.lastMail(t, mail.TemplateEmailVerification); m.Locale != "en" || !strings.Contains(m.TextBody, "\nhttp://app.example.test/verify-email?token=") {
		t.Fatalf("en default: %s %s", m.Locale, m.TextBody)
	}
	r.call(t, nil, http.MethodPost, "register", jsonBody(map[string]string{"email": "b@example.com", "password": pwA}), "X-Locale", "bg")
	if m := r.lastMail(t, mail.TemplateEmailVerification); m.Locale != "bg" || !strings.Contains(m.TextBody, "\nhttp://app.example.test/bg/verify-email?token=") {
		t.Fatalf("bg under en default: %s %s", m.Locale, m.TextBody)
	}
}

// Reset mail: the human's pick > the registration locale > the request.
func TestResetMailLocalePrecedence(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	// registered in fi
	if got := r.call(t, nil, http.MethodPost, "register", jsonBody(map[string]string{"email": "p@example.com", "password": pwA}), "X-Locale", "fi"); got.code != http.StatusAccepted {
		t.Fatal(got.raw)
	}
	if got := r.post(t, nil, "email/verify", map[string]string{"token": r.lastToken(t, mail.TemplateEmailVerification), "password": pwA}); got.code != http.StatusNoContent {
		t.Fatal(got.raw)
	}
	// 1) no human pick yet: the registration locale beats the request's
	r.call(t, nil, http.MethodPost, "password/forgot", `{"email":"p@example.com"}`, "X-Locale", "en")
	if m := r.lastMail(t, mail.TemplatePasswordReset); m.Locale != "fi" || !strings.Contains(m.TextBody, "/fi/reset-password?token=") {
		t.Fatalf("registration locale: %s\n%s", m.Locale, m.TextBody)
	}
	// 2) the human picks uk on the settings page: it wins
	if got := r.post(t, c, "login", map[string]string{"email": "p@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK {
		t.Fatal(got.raw)
	}
	if got := r.call(t, c, http.MethodPut, "preferences", `{"preferred_locale":"uk"}`); got.code != http.StatusOK {
		t.Fatal(got.raw)
	}
	r.advance(2 * time.Minute) // past the per-account mail floor
	r.call(t, nil, http.MethodPost, "password/forgot", `{"email":"p@example.com"}`, "X-Locale", "en")
	if m := r.lastMail(t, mail.TemplatePasswordReset); m.Locale != "uk" || !strings.Contains(m.TextBody, "/uk/reset-password?token=") {
		t.Fatalf("human pick: %s\n%s", m.Locale, m.TextBody)
	}
	// 3) a credential with no stored locale (registered before rdb 0017) follows the request
	_, _ = r.store.CreateCredential(context.Background(), auth.Credential{Subject: "old@example.com", PasswordHash: mustHash(t, pwA)}, r.now())
	r.call(t, nil, http.MethodPost, "password/forgot", `{"email":"old@example.com"}`, "X-Locale", "lt")
	if m := r.lastMail(t, mail.TemplatePasswordReset); m.To != "old@example.com" || m.Locale != "lt" || !strings.Contains(m.TextBody, "/lt/reset-password?token=") {
		t.Fatalf("request locale: %s\n%s", m.Locale, m.TextBody)
	}
}
