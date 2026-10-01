package auth_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
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

// nrig is one hub (native sign-in only, no social provider), a controllable
// clock, a recording mailbox and a recording Registrar.
type nrig struct {
	url   string
	h     *auth.Handler
	box   *mail.Recorder
	reg   *recReg
	store *auth.MemoryCredStore
	mu    sync.Mutex
	t     time.Time
}

func (r *nrig) now() time.Time { r.mu.Lock(); defer r.mu.Unlock(); return r.t }
func (r *nrig) advance(d time.Duration) {
	r.mu.Lock()
	r.t = r.t.Add(d)
	r.mu.Unlock()
}

// recReg admits everyone as HUM-<n> per identity, unless refuse; it records
// every call so a test can prove who reached it.
type recReg struct {
	mu     sync.Mutex
	refuse bool
	calls  []auth.Identity
	ids    map[string]string
	// SPL-1230: land is what InvitedTenant answers ("" = no live invite);
	// refuseTenant refuses a Register into that one tenant (a seat cap);
	// tenants records the tenant every Register was asked for.
	land, refuseTenant string
	tenants            []string
}

func (g *recReg) InvitedTenant(_ context.Context, _ string) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.land, nil
}

func (g *recReg) Register(_ context.Context, id auth.Identity, tenant string) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls = append(g.calls, id)
	g.tenants = append(g.tenants, tenant)
	if g.refuse || (tenant != "" && tenant == g.refuseTenant) {
		return "", auth.ErrNotAllowed
	}
	if g.ids == nil {
		g.ids = map[string]string{}
	}
	k := id.Provider + "/" + id.Subject
	if g.ids[k] == "" {
		g.ids[k] = "HUM-" + string(rune('1'+len(g.ids)))
	}
	return g.ids[k], nil
}

func (g *recReg) n() int { g.mu.Lock(); defer g.mu.Unlock(); return len(g.calls) }

var nativeBase = map[string]string{
	"SPOOL_HUB_AUTH_NATIVE_ENABLED":           "true",
	"SPOOL_HUB_AUTH_NATIVE_ARGON2_MEMORY_KIB": "64",
	"SPOOL_HUB_AUTH_NATIVE_ARGON2_ITERATIONS": "1",
}

func newNRig(t *testing.T, extra map[string]string, members auth.Membership, delivers bool) *nrig {
	t.Helper()
	return newNRigWith(t, extra, members, delivers, nil)
}

// newNRigWith is newNRig plus the CLE-3451 federated lookup; nil = the hub
// cannot tell an IdP-only address from an unknown one, which is how every
// rig above it runs.
func newNRigWith(t *testing.T, extra map[string]string, members auth.Membership, delivers bool, fed auth.FederatedLookup) *nrig {
	t.Helper()
	r := &nrig{box: &mail.Recorder{}, reg: &recReg{}, store: auth.NewMemoryCredStore(),
		t: time.Date(2026, 9, 19, 6, 0, 0, 0, time.UTC)}
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
	r.h = auth.New(cfg, zerolog.Nop(), auth.Options{Registrar: r.reg, Membership: members, Federated: fed, Now: r.now})
	if err := r.h.EnableNative(nc, auth.NativeDeps{Store: r.store, Sender: r.box, Delivers: delivers}); err != nil {
		t.Fatal(err)
	}
	hubH = r.h
	return r
}

type resp struct {
	code int
	body map[string]any
	hdr  http.Header
	raw  string
}

func (r *nrig) post(t *testing.T, c *http.Client, path string, body any) resp {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, r.url+"/api/v1/auth/"+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
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

// lastToken pulls the token out of the newest mail's link.
func (r *nrig) lastToken(t *testing.T, template string) string {
	t.Helper()
	msgs := r.box.Messages()
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].Template != template {
			continue
		}
		for _, line := range strings.Split(msgs[i].TextBody, "\n") {
			if strings.HasPrefix(line, "http") {
				u, err := url.Parse(line)
				if err != nil {
					t.Fatal(err)
				}
				return u.Query().Get("token")
			}
		}
	}
	t.Fatalf("no %s mail", template)
	return ""
}

func (r *nrig) mails(template string) int {
	n := 0
	for _, m := range r.box.Messages() {
		if m.Template == template {
			n++
		}
	}
	return n
}

const (
	pwA = "first-password-123"
	pwB = "second-password-456"
)

// registerVerified walks register → mail → verify for email with pw.
func (r *nrig) registerVerified(t *testing.T, email, pw string) {
	t.Helper()
	if got := r.post(t, nil, "register", map[string]string{"email": email, "password": pw}); got.code != http.StatusAccepted {
		t.Fatalf("register: %d %s", got.code, got.raw)
	}
	if got := r.post(t, nil, "email/verify", map[string]string{"token": r.lastToken(t, mail.TemplateEmailVerification), "password": pw}); got.code != http.StatusNoContent {
		t.Fatalf("verify: %d %s", got.code, got.raw)
	}
}

func TestNativeRegisterVerifyLoginFlow(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	c := browser(t)
	got := r.post(t, c, "register", map[string]string{"email": "  Person@Example.COM ", "password": pwA, "name": "FirstName LastName"})
	if got.code != http.StatusAccepted || got.body["status"] != "verification_required" || got.body["debug_token"] != nil {
		t.Fatalf("register: %d %s", got.code, got.raw)
	}
	msgs := r.box.Messages()
	if len(msgs) != 1 || msgs[0].To != "person@example.com" ||
		!strings.Contains(msgs[0].TextBody, "http://app.example.test/verify-email?token=") {
		t.Fatalf("mail: %+v", msgs)
	}
	if got := r.post(t, c, "email/verify", map[string]string{"token": r.lastToken(t, mail.TemplateEmailVerification), "password": pwA}); got.code != http.StatusNoContent {
		t.Fatalf("verify: %d %s", got.code, got.raw)
	}
	got = r.post(t, c, "login", map[string]string{"email": "PERSON@example.com", "password": pwA, "tenant": "acme", "redirect": "//evil.example"})
	if got.code != http.StatusOK || got.body["p"] != "password" || got.body["sub"] != "person@example.com" ||
		got.body["hum"] != "HUM-1" || got.body["t"] != "acme" || got.body["redirect"] != "/" {
		t.Fatalf("login: %d %s", got.code, got.raw)
	}
	if code, s := sessionAt(t, c, r.url); code != http.StatusOK || s.Provider != "password" || s.HumanID != "HUM-1" || s.Name != "FirstName LastName" {
		t.Fatalf("session: %d %+v", code, s)
	}
	if r.reg.n() != 1 || r.reg.calls[0].Provider != "password" || r.reg.calls[0].Email != "person@example.com" {
		t.Fatalf("registrar calls: %+v", r.reg.calls)
	}
	res, _ := http.Get(r.url + "/api/v1/auth/providers")
	b, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if !strings.Contains(string(b), `"native":true`) {
		t.Fatalf("providers: %s", b)
	}
}

func sessionAt(t *testing.T, c *http.Client, base string) (int, auth.Session) {
	t.Helper()
	res, err := c.Get(base + "/api/v1/auth/session")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var s auth.Session
	json.NewDecoder(res.Body).Decode(&s) //nolint:errcheck
	return res.StatusCode, s
}

// CONTROL: a wrong password is refused with exactly the answer an unknown email gets.
func TestNativeLoginWrongPasswordAndUnknownEmailSame401(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.registerVerified(t, "known@example.com", pwA)
	wrong := r.post(t, nil, "login", map[string]string{"email": "known@example.com", "password": pwB})
	unknown := r.post(t, nil, "login", map[string]string{"email": "nobody@example.com", "password": pwB})
	junk := r.post(t, nil, "login", map[string]string{"email": "not an email", "password": pwB})
	for _, g := range []resp{wrong, unknown, junk} {
		if g.code != http.StatusUnauthorized || g.body["error"] != "invalid_credentials" || g.hdr.Get("Set-Cookie") != "" {
			t.Fatalf("want 401 invalid_credentials, no cookie: %d %s", g.code, g.raw)
		}
	}
	if wrong.raw != unknown.raw {
		t.Fatalf("bodies differ: %q vs %q", wrong.raw, unknown.raw)
	}
	if r.reg.n() != 0 {
		t.Fatal("a refused login reached the Registrar")
	}
}

// CONTROL: an unverified email cannot log in; the 403 only follows a right password.
func TestNativeLoginUnverifiedRefused(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.post(t, nil, "register", map[string]string{"email": "fresh@example.com", "password": pwA})
	if g := r.post(t, nil, "login", map[string]string{"email": "fresh@example.com", "password": pwA}); g.code != http.StatusForbidden || g.body["error"] != "email_unverified" || g.hdr.Get("Set-Cookie") != "" {
		t.Fatalf("unverified right password: %d %s", g.code, g.raw)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "fresh@example.com", "password": pwB}); g.code != http.StatusUnauthorized {
		t.Fatalf("unverified wrong password: %d %s", g.code, g.raw)
	}
	if r.reg.n() != 0 {
		t.Fatal("unverified login reached the Registrar")
	}
}

// CONTROL: with verification off (lde only) a login works but never reaches
// the Registrar, which would match invites on the unproven email.
func TestNativeUnverifiedNeverReachesRegistrar(t *testing.T) {
	r := newNRig(t, map[string]string{"SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED": "false"}, nil, false)
	if g := r.post(t, nil, "register", map[string]string{"email": "claim@example.com", "password": pwA}); g.code != http.StatusAccepted || g.body["status"] != "registered" {
		t.Fatalf("register: %d %s", g.code, g.raw)
	}
	g := r.post(t, nil, "login", map[string]string{"email": "claim@example.com", "password": pwA, "tenant": "acme"})
	if g.code != http.StatusOK || g.body["hum"] != nil {
		t.Fatalf("login: %d %s", g.code, g.raw)
	}
	if r.reg.n() != 0 {
		t.Fatalf("unverified lde login reached the Registrar %d time(s)", r.reg.n())
	}
	// With verification required, an unverified credential is refused outright.
	r2 := newNRig(t, nil, nil, true)
	now := r2.now()
	_, _ = r2.store.CreateCredential(context.Background(), auth.Credential{Subject: "raw@example.com", PasswordHash: mustHash(t, pwA)}, now)
	r3 := r2.post(t, nil, "login", map[string]string{"email": "raw@example.com", "password": pwA})
	if r3.code != http.StatusForbidden || r2.reg.n() != 0 {
		t.Fatalf("unverified credential: %d %s, registrar calls %d", r3.code, r3.raw, r2.reg.n())
	}
}

func mustHash(t *testing.T, pw string) string {
	t.Helper()
	h, err := auth.HashPassword(pw, auth.Argon2Params{MemoryKiB: 64, Iterations: 1})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func TestNativeLoginRegistrarRefuses(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.registerVerified(t, "outsider@example.com", pwA)
	r.reg.refuse = true
	g := r.post(t, nil, "login", map[string]string{"email": "outsider@example.com", "password": pwA, "tenant": "acme"})
	if g.code != http.StatusForbidden || g.body["error"] != "not_allowed" || g.hdr.Get("Set-Cookie") != "" {
		t.Fatalf("refused login: %d %s", g.code, g.raw)
	}
}

type memberOf map[string]string // HUM → tenant

func (m memberOf) Member(_ context.Context, hum, tenant string) (bool, error) {
	return m[hum] == tenant, nil
}

// CONTROL: a native session reads only a tenant the human is a member of.
func TestNativeSessionNonMemberRefusedByDoor(t *testing.T) {
	r := newNRig(t, nil, memberOf{"HUM-1": "acme"}, true)
	r.registerVerified(t, "member@example.com", pwA)
	c := browser(t)
	if g := r.post(t, c, "login", map[string]string{"email": "member@example.com", "password": pwA}); g.code != http.StatusOK {
		t.Fatalf("login: %d %s", g.code, g.raw)
	}
	u, _ := url.Parse(r.url)
	req := httptest.NewRequest(http.MethodGet, "/v1/view/x", nil)
	for _, ck := range c.Jar.Cookies(u) {
		req.AddCookie(ck)
	}
	if _, err := r.h.SessionForTenant(req, "acme"); err != nil {
		t.Fatalf("member refused: %v", err)
	}
	if _, err := r.h.SessionForTenant(req, "other"); !errors.Is(err, auth.ErrNotMember) {
		t.Fatalf("non-member: want ErrNotMember, got %v", err)
	}
}

// CONTROL: register answers alike for a new, an unverified and a verified address.
func TestNativeRegisterEnumerationSafe(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.registerVerified(t, "taken@example.com", pwA)
	r.advance(2 * time.Minute)
	a := r.post(t, nil, "register", map[string]string{"email": "taken@example.com", "password": pwB})
	b := r.post(t, nil, "register", map[string]string{"email": "brand-new@example.com", "password": pwB})
	if a.code != b.code || a.raw != b.raw || a.code != http.StatusAccepted {
		t.Fatalf("differ: %d %s vs %d %s", a.code, a.raw, b.code, b.raw)
	}
	// The verified account's password is untouched.
	if g := r.post(t, nil, "login", map[string]string{"email": "taken@example.com", "password": pwA}); g.code != http.StatusOK {
		t.Fatalf("original password: %d", g.code)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "taken@example.com", "password": pwB}); g.code != http.StatusUnauthorized {
		t.Fatalf("squatter password: %d", g.code)
	}
}

// CONTROL (FR-015): someone who registers another person's address first
// cannot end up owning it: the owner's link installs the owner's password,
// and the squatter's older link is dead.
func TestNativePreAccountTakeover(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.post(t, nil, "register", map[string]string{"email": "victim@example.com", "password": pwA}) // squatter
	squatterLink := r.lastToken(t, mail.TemplateEmailVerification)
	r.advance(2 * time.Minute)
	r.post(t, nil, "register", map[string]string{"email": "victim@example.com", "password": pwB}) // owner
	ownerLink := r.lastToken(t, mail.TemplateEmailVerification)
	if g := r.post(t, nil, "email/verify", map[string]string{"token": squatterLink, "password": pwA}); g.code != http.StatusUnauthorized {
		t.Fatalf("retired squatter link: %d %s", g.code, g.raw)
	}
	if g := r.post(t, nil, "email/verify", map[string]string{"token": ownerLink, "password": pwB}); g.code != http.StatusNoContent {
		t.Fatalf("owner link: %d %s", g.code, g.raw)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "victim@example.com", "password": pwA}); g.code != http.StatusUnauthorized {
		t.Fatalf("squatter password after verify: %d", g.code)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "victim@example.com", "password": pwB}); g.code != http.StatusOK {
		t.Fatalf("owner password after verify: %d %s", g.code, g.raw)
	}
}

// the ONE-CLICK takeover. The squatter registers the victim's
// address with the squatter's password and the victim - who never
// registered - clicks the genuine mail. The click proves the mailbox, not
// who chose the password: without the password the link was issued for it
// verifies nothing, a wrong one consumes nothing, and the squatter's
// password never becomes a verified sign-in.
func TestNativeVerifyNeedsTheRegisteredPassword(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.post(t, nil, "register", map[string]string{"email": "victim@example.com", "password": pwA}) // squatter
	link := r.lastToken(t, mail.TemplateEmailVerification)
	for what, body := range map[string]map[string]string{
		"no password":    {"token": link},
		"victim's own":   {"token": link, "password": pwB},
		"over the bound": {"token": link, "password": strings.Repeat("x", 1025)},
	} {
		if g := r.post(t, nil, "email/verify", body); g.code != http.StatusUnauthorized || g.body["error"] != "invalid_credentials" {
			t.Fatalf("%s: %d %s", what, g.code, g.raw)
		}
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "victim@example.com", "password": pwA}); g.code == http.StatusOK {
		t.Fatalf("squatter signed in after the victim's click: %s", g.raw)
	}
	// Control: nothing was consumed; the person who chose pwA verifies.
	if g := r.post(t, nil, "email/verify", map[string]string{"token": link, "password": pwA}); g.code != http.StatusNoContent {
		t.Fatalf("matching password: %d %s", g.code, g.raw)
	}
}

func TestNativeVerifyExpiredAndRepeat(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.post(t, nil, "register", map[string]string{"email": "late@example.com", "password": pwA})
	tok := r.lastToken(t, mail.TemplateEmailVerification)
	r.advance(25 * time.Hour)
	if g := r.post(t, nil, "email/verify", map[string]string{"token": tok, "password": pwA}); g.code != http.StatusGone || g.body["error"] != "verification_token_expired" {
		t.Fatalf("expired: %d %s", g.code, g.raw)
	}
	r.post(t, nil, "register", map[string]string{"email": "late@example.com", "password": pwA})
	tok = r.lastToken(t, mail.TemplateEmailVerification)
	for i := 0; i < 2; i++ {
		if g := r.post(t, nil, "email/verify", map[string]string{"token": tok, "password": pwA}); g.code != http.StatusNoContent {
			t.Fatalf("click %d: %d %s", i, g.code, g.raw)
		}
	}
	if g := r.post(t, nil, "email/verify", map[string]string{"token": strings.Repeat("0", 64), "password": pwA}); g.code != http.StatusUnauthorized {
		t.Fatalf("unknown token: %d", g.code)
	}
}

func forgot(t *testing.T, r *nrig, email string) {
	t.Helper()
	if g := r.post(t, nil, "password/forgot", map[string]string{"email": email}); g.code != http.StatusNoContent {
		t.Fatalf("forgot %s: %d %s", email, g.code, g.raw)
	}
}

// CONTROL: a reset token works once; the old password dies with it.
func TestNativeResetTokenSingleUse(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.registerVerified(t, "reset@example.com", pwA)
	forgot(t, r, "reset@example.com")
	tok := r.lastToken(t, mail.TemplatePasswordReset)
	if !strings.Contains(r.box.Messages()[len(r.box.Messages())-1].TextBody, "http://app.example.test/reset-password?token=") {
		t.Fatal("reset link")
	}
	if g := r.post(t, nil, "password/reset", map[string]string{"token": tok, "password": "short"}); g.code != http.StatusBadRequest {
		t.Fatalf("short: %d", g.code)
	}
	if g := r.post(t, nil, "password/reset", map[string]string{"token": tok, "password": pwB}); g.code != http.StatusNoContent || g.hdr.Get("Set-Cookie") != "" {
		t.Fatalf("reset: %d %s", g.code, g.raw)
	}
	if g := r.post(t, nil, "password/reset", map[string]string{"token": tok, "password": "third-password-789"}); g.code != http.StatusUnauthorized || g.body["error"] != "reset_token_invalid" {
		t.Fatalf("reused: %d %s", g.code, g.raw)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "reset@example.com", "password": pwA}); g.code != http.StatusUnauthorized {
		t.Fatalf("old password: %d", g.code)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "reset@example.com", "password": pwB}); g.code != http.StatusOK {
		t.Fatalf("new password: %d", g.code)
	}
}

// CONTROL: an expired reset token is refused like an unknown one.
func TestNativeResetTokenExpired(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.registerVerified(t, "slow@example.com", pwA)
	forgot(t, r, "slow@example.com")
	tok := r.lastToken(t, mail.TemplatePasswordReset)
	r.advance(time.Hour + time.Second)
	if g := r.post(t, nil, "password/reset", map[string]string{"token": tok, "password": pwB}); g.code != http.StatusUnauthorized || g.body["error"] != "reset_token_invalid" {
		t.Fatalf("expired: %d %s", g.code, g.raw)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "slow@example.com", "password": pwA}); g.code != http.StatusOK {
		t.Fatalf("password changed by an expired token: %d", g.code)
	}
}

// Reset proves the inbox: an unverified credential becomes usable.
func TestNativeResetVerifiesEmail(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.post(t, nil, "register", map[string]string{"email": "lost@example.com", "password": pwA})
	forgot(t, r, "lost@example.com")
	r.post(t, nil, "password/reset", map[string]string{"token": r.lastToken(t, mail.TemplatePasswordReset), "password": pwB})
	if g := r.post(t, nil, "login", map[string]string{"email": "lost@example.com", "password": pwB}); g.code != http.StatusOK {
		t.Fatalf("login after reset: %d %s", g.code, g.raw)
	}
}

func TestNativeForgotEnumerationSafe(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.registerVerified(t, "exists@example.com", pwA)
	a := r.post(t, nil, "password/forgot", map[string]string{"email": "exists@example.com"})
	b := r.post(t, nil, "password/forgot", map[string]string{"email": "ghost@example.com"})
	if a.code != http.StatusNoContent || a.code != b.code || a.raw != b.raw {
		t.Fatalf("differ: %d %q vs %d %q", a.code, a.raw, b.code, b.raw)
	}
	if n := r.mails(mail.TemplatePasswordReset); n != 1 {
		t.Fatalf("reset mails: %d", n)
	}
}

// CONTROL (FR-006a): one reset mail per 60 s and five per day per account,
// refused with the same 204.
func TestNativeForgotAccountFloor(t *testing.T) {
	r := newNRig(t, map[string]string{"SPOOL_HUB_AUTH_NATIVE_FORM_PER_IP": "100"}, nil, true)
	r.registerVerified(t, "floor@example.com", pwA)
	forgot(t, r, "floor@example.com")
	forgot(t, r, "floor@example.com")
	if n := r.mails(mail.TemplatePasswordReset); n != 1 {
		t.Fatalf("inside 60s: %d mails", n)
	}
	for i := 0; i < 10; i++ {
		r.advance(61 * time.Second)
		forgot(t, r, "floor@example.com")
	}
	if n := r.mails(mail.TemplatePasswordReset); n != 5 {
		t.Fatalf("daily cap: %d mails, want 5", n)
	}
	r.advance(24 * time.Hour)
	forgot(t, r, "floor@example.com")
	if n := r.mails(mail.TemplatePasswordReset); n != 6 {
		t.Fatalf("next day: %d mails, want 6", n)
	}
}

// CONTROL (FR-006b): the per-email login ceiling holds even for the right
// password, answers 429 + Retry-After, and leaves other emails alone.
func TestNativeLoginRateLimited(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.registerVerified(t, "target@example.com", pwA)
	r.registerVerified(t, "bystander@example.com", pwA)
	for i := 0; i < 10; i++ {
		r.post(t, nil, "login", map[string]string{"email": "target@example.com", "password": "guess-" + strings.Repeat("x", i+8)})
	}
	g := r.post(t, nil, "login", map[string]string{"email": "target@example.com", "password": pwA})
	if g.code != http.StatusTooManyRequests || g.body["error"] != "rate_limited" || g.hdr.Get("Retry-After") == "" {
		t.Fatalf("11th attempt: %d %s", g.code, g.raw)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "bystander@example.com", "password": pwA}); g.code != http.StatusOK {
		t.Fatalf("other email: %d %s", g.code, g.raw)
	}
	r.advance(16 * time.Minute)
	if g := r.post(t, nil, "login", map[string]string{"email": "target@example.com", "password": pwA}); g.code != http.StatusOK {
		t.Fatalf("after the window: %d %s", g.code, g.raw)
	}
	// Per IP: the form routes stop at 10 per window from one address.
	r2 := newNRig(t, nil, nil, true)
	for i := 0; i < 10; i++ {
		r2.post(t, nil, "password/forgot", map[string]string{"email": "x@example.com"})
	}
	if g := r2.post(t, nil, "password/forgot", map[string]string{"email": "x@example.com"}); g.code != http.StatusTooManyRequests {
		t.Fatalf("form per IP: %d", g.code)
	}
}

func TestNativeChangePassword(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.registerVerified(t, "change@example.com", pwA)
	if g := r.post(t, nil, "password/change", map[string]string{"current_password": pwA, "new_password": pwB}); g.code != http.StatusUnauthorized || g.body["error"] != "unauthenticated" {
		t.Fatalf("no session: %d %s", g.code, g.raw)
	}
	c := browser(t)
	r.post(t, c, "login", map[string]string{"email": "change@example.com", "password": pwA})
	if g := r.post(t, c, "password/change", map[string]string{"current_password": pwB, "new_password": pwB}); g.code != http.StatusUnauthorized || g.body["error"] != "invalid_credentials" {
		t.Fatalf("wrong current: %d %s", g.code, g.raw)
	}
	if g := r.post(t, c, "password/change", map[string]string{"current_password": pwA, "new_password": pwB}); g.code != http.StatusNoContent {
		t.Fatalf("change: %d %s", g.code, g.raw)
	}
	if code, _ := sessionAt(t, c, r.url); code != http.StatusUnauthorized {
		t.Fatalf("cookie not cleared: %d", code)
	}
	if g := r.post(t, nil, "login", map[string]string{"email": "change@example.com", "password": pwB}); g.code != http.StatusOK {
		t.Fatalf("new password: %d", g.code)
	}
}

func TestNativeRequiresJSON(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	res, err := http.PostForm(r.url+"/api/v1/auth/login", url.Values{"email": {"a@example.com"}, "password": {pwA}})
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("form post: %d", res.StatusCode)
	}
}

func TestNativeRegisterFailsClosedWithoutMail(t *testing.T) {
	r := newNRig(t, nil, nil, false)
	if g := r.post(t, nil, "register", map[string]string{"email": "a@example.com", "password": pwA}); g.code != http.StatusServiceUnavailable || g.body["error"] != "email_delivery_unavailable" {
		t.Fatalf("no transport: %d %s", g.code, g.raw)
	}
	// With debug tokens (lde/dev) the flow is completable without mail.
	d := newNRig(t, map[string]string{"SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS": "true"}, nil, false)
	g := d.post(t, nil, "register", map[string]string{"email": "a@example.com", "password": pwA})
	tok, _ := g.body["debug_token"].(string)
	if g.code != http.StatusAccepted || len(tok) != 64 {
		t.Fatalf("debug register: %d %s", g.code, g.raw)
	}
	if g := d.post(t, nil, "email/verify", map[string]string{"token": tok, "password": pwA}); g.code != http.StatusNoContent {
		t.Fatalf("debug verify: %d", g.code)
	}
}

func TestNativeOffNotMounted(t *testing.T) {
	cfg, _ := auth.LoadFrom("lde", map[string]string{})
	nc, err := auth.LoadNativeFrom("prd", map[string]string{})
	if err != nil || nc.Enabled {
		t.Fatalf("default: %+v %v", nc, err)
	}
	h := auth.New(cfg, zerolog.Nop(), auth.Options{})
	if err := h.EnableNative(nc, auth.NativeDeps{Store: auth.NewMemoryCredStore()}); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()
	res, _ := http.Post(srv.URL+"/api/v1/auth/login", "application/json", strings.NewReader(`{}`))
	res.Body.Close()
	if res.StatusCode != http.StatusNotFound && res.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("native off: login answered %d", res.StatusCode)
	}
}

// CONTROL: the prd/dev guards on the native config.
func TestNativeConfigFailFast(t *testing.T) {
	on := func(extra map[string]string) map[string]string {
		m := map[string]string{"SPOOL_HUB_AUTH_NATIVE_ENABLED": "true"}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	for _, c := range []struct {
		env  string
		vars map[string]string
	}{
		{"prd", on(map[string]string{"SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS": "true"})},
		{"dev", on(map[string]string{"SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED": "false"})},
		{"prd", on(map[string]string{"SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED": "false"})},
		{"dev", on(map[string]string{"SPOOL_HUB_AUTH_NATIVE_ARGON2_MEMORY_KIB": "4096"})},
		{"prd", on(map[string]string{"SPOOL_HUB_AUTH_NATIVE_ARGON2_ITERATIONS": "1"})},
		{"lde", on(map[string]string{"SPOOL_HUB_AUTH_NATIVE_PASSWORD_MIN_LEN": "4"})},
		{"lde", on(map[string]string{"SPOOL_HUB_AUTH_NATIVE_RESET_TTL": "0s"})},
	} {
		if _, err := auth.LoadNativeFrom(c.env, c.vars); err == nil {
			t.Errorf("%s %v accepted", c.env, c.vars)
		}
	}
	if _, err := auth.LoadNativeFrom("dev", on(map[string]string{"SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS": "true"})); err != nil {
		t.Errorf("dev debug tokens refused: %v", err)
	}
	if _, err := auth.LoadNativeFrom("prd", map[string]string{"SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS": "true"}); err != nil {
		t.Errorf("disabled native validated: %v", err)
	}
	// Native needs the 010 session key even with no social provider.
	cfg, _ := auth.LoadFrom("lde", map[string]string{"SPOOL_HUB_AUTH_APP_URL": "http://app.example.test"})
	nc, _ := auth.LoadNativeFrom("lde", on(nil))
	if err := auth.New(cfg, zerolog.Nop(), auth.Options{}).EnableNative(nc, auth.NativeDeps{Store: auth.NewMemoryCredStore()}); err == nil {
		t.Error("EnableNative without a session key accepted")
	}
}
