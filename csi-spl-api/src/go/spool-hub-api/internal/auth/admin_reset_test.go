package auth_test

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// memRevoker is a SessionRevoker two handlers can share, like two hub
// instances on one database.
type memRevoker struct {
	mu sync.Mutex
	at map[string]time.Time
}

func (m *memRevoker) RevokeSessions(_ context.Context, hum string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.at == nil {
		m.at = map[string]time.Time{}
	}
	m.at[hum] = at
	return nil
}

func (m *memRevoker) SessionRevocations(_ context.Context, since time.Time) (map[string]time.Time, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := map[string]time.Time{}
	for k, v := range m.at {
		if v.After(since) {
			out[k] = v
		}
	}
	return out, nil
}

// syncBuf is a log sink the handler writes and the test reads.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

// resetRig is newNRig with a readable log and a shared revoker.
func newResetRig(t *testing.T, delivers bool, logs *syncBuf, rev auth.SessionRevoker) *nrig {
	t.Helper()
	r := &nrig{box: &mail.Recorder{}, reg: &recReg{}, store: auth.NewMemoryCredStore(),
		t: time.Date(2026, 10, 7, 6, 0, 0, 0, time.UTC)}
	var hubH http.Handler
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) { hubH.ServeHTTP(w, q) }))
	t.Cleanup(srv.Close)
	r.url = srv.URL
	r.h = resetHandler(t, r, logs, rev)
	if err := r.h.EnableNative(nativeCfg(t), auth.NativeDeps{Store: r.store, Sender: r.box, Delivers: delivers}); err != nil {
		t.Fatal(err)
	}
	hubH = r.h
	return r
}

func resetHandler(t *testing.T, r *nrig, logs *syncBuf, rev auth.SessionRevoker) *auth.Handler {
	t.Helper()
	cfg, err := auth.LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_SESSION_KEY":   strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":       "http://app.example.test",
		"SPOOL_HUB_AUTH_COOKIE_SECURE": "false",
	})
	if err != nil {
		t.Fatal(err)
	}
	return auth.New(cfg, zerolog.New(logs), auth.Options{Registrar: r.reg, Now: r.now, Revocations: rev})
}

func nativeCfg(t *testing.T) *auth.NativeConfig {
	t.Helper()
	nc, err := auth.LoadNativeFrom("lde", nativeBase)
	if err != nil {
		t.Fatal(err)
	}
	return nc
}

func (r *nrig) login(t *testing.T, c *http.Client, email, pw string) resp {
	t.Helper()
	return r.post(t, c, "login", map[string]string{"email": email, "password": pw})
}

// t1 ea0af569: the admin reset mails the forgot link, kills the old password
// and every session (on this instance AND on another one sharing the store),
// the link then sets a new password that signs in, and no log line carries
// the token. CONTROLS: the session is alive before the reset; sign_out=false
// leaves the password and the session working.
func TestAdminPasswordResetSignsOutEverywhere(t *testing.T) {
	logs, rev := &syncBuf{}, &memRevoker{}
	r := newResetRig(t, true, logs, rev)
	const email = "member@example.com"
	r.registerVerified(t, email, pwA)
	c := browser(t)
	if got := r.login(t, c, email, pwA); got.code != http.StatusOK {
		t.Fatalf("login: %d %s", got.code, got.raw)
	}
	code, s := sessionAt(t, c, r.url)
	if code != http.StatusOK || s.HumanID == "" {
		t.Fatalf("CONTROL: the session must be alive before the reset: %d %+v", code, s)
	}
	r.advance(time.Second)
	res, err := r.h.AdminPasswordReset(context.Background(), auth.AdminResetRequest{Subject: email, HumanID: s.HumanID,
		ActorID: "HUM-90", Locale: "en", SignOut: true})
	if err != nil || !res.SignedOut || res.Email != email {
		t.Fatalf("reset: %+v %v", res, err)
	}
	msgs := r.box.Messages()
	if last := msgs[len(msgs)-1]; last.Template != mail.TemplatePasswordReset || last.To != email ||
		!strings.Contains(last.TextBody, "http://app.example.test/reset-password?token=") {
		t.Fatalf("reset mail: %+v", last)
	}
	if code, _ := sessionAt(t, c, r.url); code == http.StatusOK {
		t.Fatal("the member's session survived the reset")
	}
	if got := r.login(t, nil, email, pwA); got.code != http.StatusUnauthorized {
		t.Fatalf("the old password still signs in: %d %s", got.code, got.raw)
	}
	// another hub instance on the same store refuses the old cookie too
	other := resetHandler(t, r, &syncBuf{}, rev)
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	for _, ck := range c.Jar.Cookies(mustURL(t, r.url)) {
		req.AddCookie(ck)
	}
	if _, ok := other.SessionFromRequest(req); ok {
		t.Fatal("another instance still honours the revoked session")
	}
	tok := r.lastToken(t, mail.TemplatePasswordReset)
	if strings.Contains(logs.String(), tok) {
		t.Fatal("the reset token reached a log line")
	}
	if !strings.Contains(logs.String(), "auth.native_admin_reset") {
		t.Fatalf("no admin reset log line: %s", logs.String())
	}
	r.advance(2 * time.Second)
	if got := r.post(t, nil, "password/reset", map[string]string{"token": tok, "password": pwB}); got.code != http.StatusOK {
		t.Fatalf("the link did not set a password: %d %s", got.code, got.raw)
	}
	c2 := browser(t)
	if got := r.login(t, c2, email, pwB); got.code != http.StatusOK {
		t.Fatalf("new password: %d %s", got.code, got.raw)
	}
	if code, _ := sessionAt(t, c2, r.url); code != http.StatusOK {
		t.Fatalf("a session after the reset is refused: %d", code)
	}
}

// CONTROL: sign_out=false only mails the link; the password and the open
// session keep working. A second reset inside the mail floor is refused and
// changes nothing.
func TestAdminPasswordResetKeepSessionAndFloor(t *testing.T) {
	r := newResetRig(t, true, &syncBuf{}, &memRevoker{})
	const email = "keep@example.com"
	r.registerVerified(t, email, pwA)
	c := browser(t)
	r.login(t, c, email, pwA)
	_, s := sessionAt(t, c, r.url)
	res, err := r.h.AdminPasswordReset(context.Background(), auth.AdminResetRequest{Subject: email, HumanID: s.HumanID, ActorID: "HUM-90"})
	if err != nil || res.SignedOut {
		t.Fatalf("reset: %+v %v", res, err)
	}
	if r.mails(mail.TemplatePasswordReset) != 1 {
		t.Fatal("no reset mail")
	}
	if code, _ := sessionAt(t, c, r.url); code != http.StatusOK {
		t.Fatalf("sign_out=false ended the session: %d", code)
	}
	if got := r.login(t, nil, email, pwA); got.code != http.StatusOK {
		t.Fatalf("sign_out=false killed the password: %d", got.code)
	}
	_, err = r.h.AdminPasswordReset(context.Background(), auth.AdminResetRequest{Subject: email, HumanID: s.HumanID, ActorID: "HUM-90", SignOut: true})
	if !errors.Is(err, auth.ErrResetRateLimited) {
		t.Fatalf("a second reset inside the floor: %v", err)
	}
	if got := r.login(t, nil, email, pwA); got.code != http.StatusOK || r.mails(mail.TemplatePasswordReset) != 1 {
		t.Fatalf("a refused reset changed something: %d, %d mails", got.code, r.mails(mail.TemplatePasswordReset))
	}
}

// No credential = nothing to reset; no mail transport = refused before
// anything changes (a reset never locks a member out with no way back).
func TestAdminPasswordResetRefusals(t *testing.T) {
	r := newResetRig(t, true, &syncBuf{}, nil)
	if _, err := r.h.AdminPasswordReset(context.Background(), auth.AdminResetRequest{Subject: "nobody@example.com", ActorID: "HUM-90", SignOut: true}); !errors.Is(err, auth.ErrNoPassword) {
		t.Fatalf("no credential: %v", err)
	}
	dead := newResetRig(t, false, &syncBuf{}, nil)
	dead.store.CreateCredential(context.Background(), auth.Credential{Subject: "m@example.com", PasswordHash: mustHash(t, pwA)}, time.Now()) //nolint:errcheck
	if _, err := dead.h.AdminPasswordReset(context.Background(), auth.AdminResetRequest{Subject: "m@example.com", ActorID: "HUM-90", SignOut: true}); !errors.Is(err, auth.ErrMailUndeliverable) {
		t.Fatalf("no transport: %v", err)
	}
	if c, _ := dead.store.GetCredential(context.Background(), "m@example.com"); auth.VerifyPassword(c.PasswordHash, pwA) != nil {
		t.Fatal("an undeliverable reset replaced the password")
	}
	off := &auth.Handler{}
	if _, err := off.AdminPasswordReset(context.Background(), auth.AdminResetRequest{Subject: "m@example.com"}); !errors.Is(err, auth.ErrNativeOff) {
		t.Fatalf("native off: %v", err)
	}
}

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

// t1 ea0af569 msg 2a57fe20 (owner "c", part A): setting a password with a
// reset link signs the person in - the self-service forgot link here (the
// admin's mails the same link) - and the new session is the only one: a
// browser signed in before the reset is out. CONTROLS: the spent token and
// an expired one set no password and open no session.
func TestResetLinkSignsIn(t *testing.T) {
	r := newResetRig(t, true, &syncBuf{}, &memRevoker{})
	const email = "self@example.com"
	r.registerVerified(t, email, pwA)
	before := browser(t)
	r.login(t, before, email, pwA)
	if code, _ := sessionAt(t, before, r.url); code != http.StatusOK {
		t.Fatalf("CONTROL: the earlier session is alive: %d", code)
	}
	r.advance(time.Second)
	r.post(t, nil, "password/forgot", map[string]string{"email": email})
	tok := r.lastToken(t, mail.TemplatePasswordReset)
	c := browser(t)
	got := r.post(t, c, "password/reset", map[string]string{"token": tok, "password": pwB})
	if got.code != http.StatusOK || got.body["sub"] != email || got.body["hum"] == nil || got.hdr.Get("Set-Cookie") == "" {
		t.Fatalf("reset should sign in: %d %s", got.code, got.raw)
	}
	if code, s := sessionAt(t, c, r.url); code != http.StatusOK || s.Subject != email || s.HumanID == "" {
		t.Fatalf("no session after the reset: %d %+v", code, s)
	}
	if code, _ := sessionAt(t, before, r.url); code == http.StatusOK {
		t.Fatal("a session from before the reset survived it")
	}
	if strings.Contains(got.raw, tok) || strings.Contains(got.raw, pwB) {
		t.Fatalf("the answer echoes the token or the password: %s", got.raw)
	}
	// CONTROL: the spent token opens nothing
	again := r.post(t, browser(t), "password/reset", map[string]string{"token": tok, "password": "third-password-789"})
	if again.code != http.StatusUnauthorized || again.hdr.Get("Set-Cookie") != "" {
		t.Fatalf("a spent token: %d %s", again.code, again.raw)
	}
	// CONTROL: an expired token opens nothing and leaves the password
	r.advance(2 * time.Minute)
	r.post(t, nil, "password/forgot", map[string]string{"email": email})
	old := r.lastToken(t, mail.TemplatePasswordReset)
	r.advance(48 * time.Hour)
	late := r.post(t, browser(t), "password/reset", map[string]string{"token": old, "password": "fourth-password-000"})
	if late.code != http.StatusUnauthorized || late.hdr.Get("Set-Cookie") != "" {
		t.Fatalf("an expired token: %d %s", late.code, late.raw)
	}
	if ok := r.login(t, nil, email, pwB); ok.code != http.StatusOK {
		t.Fatalf("a refused reset changed the password: %d", ok.code)
	}
}
