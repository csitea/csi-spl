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
	mu    sync.Mutex
	reg   *recReg
	loc   map[string]string
	theme map[string]string
	key   map[string]string         // SPL-976 submit_key, nil until first set
	rail  map[string][]string       // SPL-979 rail_order, nil until first set
	view  map[string]string         // topic c6994436, keyed "<HUM>/<key>", nil until first set
	cols  map[string]map[string]int // SPL-1132 issues_columns, nil until first set
	diag  map[string]bool           // CLE-34963 "Debug pane", nil until first set
	name  map[string]string         // CLE-34968 display name, nil until first set
	fail  error                     // non-nil: DiagnosticsEnabled answers it
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

func (p *fakePrefs) PreferredTheme(_ context.Context, hum string) (string, error) {
	if !p.known(hum) {
		return "", auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.theme[hum], nil
}

func (p *fakePrefs) SetPreferredTheme(_ context.Context, hum, theme string) error {
	if !p.known(hum) {
		return auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.theme == nil {
		p.theme = map[string]string{}
	}
	p.theme[hum] = theme
	return nil
}

func (p *fakePrefs) SubmitKey(_ context.Context, hum string) (string, error) {
	if !p.known(hum) {
		return "", auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.key[hum], nil
}

func (p *fakePrefs) SetSubmitKey(_ context.Context, hum, key string) error {
	if !p.known(hum) {
		return auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.key == nil {
		p.key = map[string]string{}
	}
	p.key[hum] = key
	return nil
}

func (p *fakePrefs) RailOrder(_ context.Context, hum string) ([]string, error) {
	if !p.known(hum) {
		return nil, auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.rail[hum], nil
}

func (p *fakePrefs) SetRailOrder(_ context.Context, hum string, order []string) error {
	if !p.known(hum) {
		return auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.rail == nil {
		p.rail = map[string][]string{}
	}
	p.rail[hum] = order
	return nil
}

func (p *fakePrefs) ViewPref(_ context.Context, hum, key string) (string, error) {
	if !p.known(hum) {
		return "", auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.view[hum+"/"+key], nil
}

func (p *fakePrefs) SetViewPref(_ context.Context, hum, key, value string) error {
	if !p.known(hum) {
		return auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.view == nil {
		p.view = map[string]string{}
	}
	p.view[hum+"/"+key] = value
	return nil
}

func (p *fakePrefs) IssueColumns(_ context.Context, hum string) (map[string]int, error) {
	if !p.known(hum) {
		return nil, auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.cols[hum], nil
}

func (p *fakePrefs) SetIssueColumns(_ context.Context, hum string, cols map[string]int) error {
	if !p.known(hum) {
		return auth.ErrNoHuman
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cols == nil {
		p.cols = map[string]map[string]int{}
	}
	p.cols[hum] = cols
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
	return newPRigWrapped(t, defLocale, withRegistrar, nil)
}

// newPRigWrapped is newPRig whose hub reads the fake through wrap (nil = as is).
func newPRigWrapped(t *testing.T, defLocale string, withRegistrar bool, wrap func(*fakePrefs) auth.Preferences) (*nrig, *fakePrefs) {
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
	if wrap != nil {
		o.Preferences = wrap(prefs)
	}
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

// the palette picker keeps the choice on the account, so an
// operator default (do_spl_human_theme) and the person's own pick share one
// field, and the session answers it back.
func TestPreferencesTheme(t *testing.T) {
	r, prefs := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["preferred_theme"] != nil {
		t.Fatalf("session before: %s", got.raw)
	}
	for _, id := range auth.ThemeIDs {
		got := r.call(t, c, http.MethodPut, "preferences", jsonBody(map[string]string{"preferred_theme": id}))
		if got.code != http.StatusOK || got.body["preferred_theme"] != id || len(got.body) != 1 {
			t.Fatalf("put %s: %d %s", id, got.code, got.raw)
		}
		if got = r.call(t, c, http.MethodGet, "session", ""); got.body["preferred_theme"] != id {
			t.Fatalf("session after %s: %s", id, got.raw)
		}
	}
	// the native login answer carries it too: the WUI adopts that answer with
	// no second probe, so without it the stored theme never applied
	c2 := browser(t)
	if got := r.post(t, c2, "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK ||
		got.body["preferred_theme"] != auth.ThemeIDs[len(auth.ThemeIDs)-1] {
		t.Fatalf("login answer: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodPut, "preferences", `{"preferred_theme":null}`); got.code != http.StatusOK || got.body["preferred_theme"] != nil {
		t.Fatalf("clear: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["preferred_theme"] != nil {
		t.Fatalf("session after clear: %s", got.raw)
	}
	if got := r.post(t, browser(t), "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK {
		t.Fatalf("login after clear: %d %s", got.code, got.raw)
	} else if v, ok := got.body["preferred_theme"]; !ok || v != nil {
		t.Fatalf("login after clear must answer preferred_theme null: %s", got.raw)
	}
	before := map[string]string{}
	for k, v := range prefs.theme {
		before[k] = v
	}
	for _, body := range []string{`{"preferred_theme":"navy"}`, `{"preferred_theme":"Light"}`, `{"preferred_theme":""}`,
		`{"preferred_theme":7}`, `{"preferred_theme":"light","preferred_locale":"de"}`} {
		if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != http.StatusBadRequest {
			t.Errorf("%s: %d %s", body, got.code, got.raw)
		}
	}
	if got := r.call(t, c, http.MethodPut, "preferences", `{"preferred_theme":"navy"}`); got.body["error"] != "unsupported_theme" {
		t.Errorf("error token: %s", got.raw)
	}
	for k, v := range prefs.theme {
		if before[k] != v {
			t.Fatalf("a refused PUT stored a theme: %v", prefs.theme)
		}
	}
	// no session, no write
	if got := r.call(t, nil, http.MethodPut, "preferences", `{"preferred_theme":"light"}`); got.code != http.StatusUnauthorized {
		t.Fatalf("no session: %d %s", got.code, got.raw)
	}
}

// SPL-976: Settings -> Behaviour "Text fields" is kept on the account like
// the theme, answered by the session and the native login, and only the two
// ids are admitted.
func TestPreferencesSubmitKey(t *testing.T) {
	r, prefs := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["submit_key"] != nil {
		t.Fatalf("session before: %s", got.raw)
	}
	for _, id := range auth.SubmitKeys {
		got := r.call(t, c, http.MethodPut, "preferences", jsonBody(map[string]string{"submit_key": id}))
		if got.code != http.StatusOK || got.body["submit_key"] != id || len(got.body) != 1 {
			t.Fatalf("put %s: %d %s", id, got.code, got.raw)
		}
		if got = r.call(t, c, http.MethodGet, "session", ""); got.body["submit_key"] != id {
			t.Fatalf("session after %s: %s", id, got.raw)
		}
	}
	if got := r.post(t, browser(t), "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK ||
		got.body["submit_key"] != "ctrl-enter" {
		t.Fatalf("login answer: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodPut, "preferences", `{"submit_key":null}`); got.code != http.StatusOK || got.body["submit_key"] != nil {
		t.Fatalf("clear: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["submit_key"] != nil {
		t.Fatalf("session after clear: %s", got.raw)
	}
	if err := prefs.SetSubmitKey(context.Background(), firstHum(prefs), "enter"); err != nil {
		t.Fatal(err)
	}
	for _, body := range []string{`{"submit_key":"ctrl"}`, `{"submit_key":"Enter"}`, `{"submit_key":""}`,
		`{"submit_key":true}`, `{"submit_key":"ctrl-enter","preferred_theme":"navy"}`} {
		if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != http.StatusBadRequest {
			t.Errorf("%s: %d %s", body, got.code, got.raw)
		}
	}
	if got := r.call(t, c, http.MethodPut, "preferences", `{"submit_key":"cmd-enter"}`); got.body["error"] != "unsupported_submit_key" {
		t.Errorf("error token: %s", got.raw)
	}
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["submit_key"] != "enter" {
		t.Fatalf("a refused PUT stored a key: %s", got.raw)
	}
	if got := r.call(t, nil, http.MethodPut, "preferences", `{"submit_key":"enter"}`); got.code != http.StatusUnauthorized {
		t.Fatalf("no session: %d %s", got.code, got.raw)
	}
}

// SPL-979: the left-rail order is kept on the account; only a permutation of
// auth.RailTabs is admitted, null clears it, and both answers carry it.
func TestPreferencesRailOrder(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["rail_order"] != nil {
		t.Fatalf("session before: %s", got.raw)
	}
	want := `["archive","events","flow","topics","issues","channels","dm"]`
	got := r.call(t, c, http.MethodPut, "preferences", `{"rail_order":`+want+`}`)
	if got.code != http.StatusOK || len(got.body) != 1 {
		t.Fatalf("put: %d %s", got.code, got.raw)
	}
	if b, _ := json.Marshal(got.body["rail_order"]); string(b) != want {
		t.Fatalf("put echo %s", b)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); true {
		if b, _ := json.Marshal(got.body["rail_order"]); string(b) != want {
			t.Fatalf("session after: %s", got.raw)
		}
	}
	if got := r.post(t, browser(t), "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK {
		t.Fatalf("login: %d %s", got.code, got.raw)
	} else if b, _ := json.Marshal(got.body["rail_order"]); string(b) != want {
		t.Fatalf("login answer: %s", got.raw)
	}
	for _, body := range []string{
		`{"rail_order":["dm","channels","issues","topics","flow"]}`,
		`{"rail_order":["dm","dm","issues","topics","flow","events"]}`,
		`{"rail_order":["dm","channels","issues","topics","flow","users"]}`,
		`{"rail_order":["dm","channels","issues","topics","flow","events","events"]}`,
		`{"rail_order":["dm","channels","issues","topics","flow","archive"]}`,
		`{"rail_order":["dm","channels","issues","topics","flow","events","archive","archive"]}`,
		`{"rail_order":"dm,channels"}`, `{"rail_order":[]}`, `{"rail_order":7}`,
	} {
		if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != http.StatusBadRequest || got.body["error"] != "unsupported_rail_order" {
			t.Errorf("%s: %d %s", body, got.code, got.raw)
		}
	}
	if got := r.call(t, c, http.MethodGet, "session", ""); true {
		if b, _ := json.Marshal(got.body["rail_order"]); string(b) != want {
			t.Fatalf("a refused PUT changed the order: %s", got.raw)
		}
	}
	// SPL-983: an order from before archive existed (a cached WUI) still stores
	legacy := `["events","flow","topics","issues","channels","dm"]`
	if got := r.call(t, c, http.MethodPut, "preferences", `{"rail_order":`+legacy+`}`); got.code != http.StatusOK {
		t.Fatalf("legacy six: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodPut, "preferences", `{"rail_order":null}`); got.code != http.StatusOK || got.body["rail_order"] != nil {
		t.Fatalf("clear: %d %s", got.code, got.raw)
	}
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["rail_order"] != nil {
		t.Fatalf("session after clear: %s", got.raw)
	}
	if got := r.call(t, nil, http.MethodPut, "preferences", `{"rail_order":null}`); got.code != http.StatusUnauthorized {
		t.Fatalf("no session: %d %s", got.code, got.raw)
	}
}

// Topic c6994436: message_order and composer_position are kept on the
// account, each admits only its own values, null clears, the two keys are
// independent, and GET /session plus the native login answer carry both.
func TestPreferencesViewPrefs(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	got := r.call(t, c, http.MethodGet, "session", "")
	for _, k := range []string{"message_order", "composer_position"} {
		if v, ok := got.body[k]; !ok || v != nil {
			t.Fatalf("session before: %s must answer %s null", got.raw, k)
		}
	}
	got = r.call(t, c, http.MethodPut, "preferences", `{"message_order":"newest-last"}`)
	if got.code != http.StatusOK || len(got.body) != 1 || got.body["message_order"] != "newest-last" {
		t.Fatalf("put order: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["message_order"] != "newest-last" || got.body["composer_position"] != nil {
		t.Fatalf("the order must not set the position: %s", got.raw)
	}
	got = r.call(t, c, http.MethodPut, "preferences", `{"composer_position":"bottom","message_order":"newest-first"}`)
	if got.code != http.StatusOK || got.body["composer_position"] != "bottom" || got.body["message_order"] != "newest-first" {
		t.Fatalf("put both: %d %s", got.code, got.raw)
	}
	if got := r.post(t, browser(t), "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK ||
		got.body["composer_position"] != "bottom" || got.body["message_order"] != "newest-first" {
		t.Fatalf("login answer: %d %s", got.code, got.raw)
	}
	for body, code := range map[string]string{
		`{"message_order":"oldest-first"}`:                           "unsupported_message_order",
		`{"message_order":"top"}`:                                    "unsupported_message_order",
		`{"message_order":""}`:                                       "unsupported_message_order",
		`{"message_order":true}`:                                     "unsupported_message_order",
		`{"composer_position":"newest-last"}`:                        "unsupported_composer_position",
		`{"composer_position":"Bottom"}`:                             "unsupported_composer_position",
		`{"composer_position":"top","message_order":"sideways"}`:     "unsupported_message_order",
		`{"message_order":"newest-last","composer_position":"left"}`: "unsupported_composer_position",
	} {
		if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != http.StatusBadRequest || got.body["error"] != code {
			t.Errorf("%s: %d %s", body, got.code, got.raw)
		}
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["message_order"] != "newest-first" || got.body["composer_position"] != "bottom" {
		t.Fatalf("a refused PUT stored something: %s", got.raw)
	}
	got = r.call(t, c, http.MethodPut, "preferences", `{"message_order":null,"composer_position":null}`)
	if got.code != http.StatusOK || got.body["message_order"] != nil || got.body["composer_position"] != nil || len(got.body) != 2 {
		t.Fatalf("clear: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["message_order"] != nil || got.body["composer_position"] != nil {
		t.Fatalf("session after clear: %s", got.raw)
	}
	if got := r.call(t, nil, http.MethodPut, "preferences", `{"message_order":"newest-last"}`); got.code != http.StatusUnauthorized {
		t.Fatalf("no session: %d %s", got.code, got.raw)
	}
	// Defaults are the first value of each list: today's layout.
	if auth.ViewPrefs[auth.PrefMessageOrder][0] != "newest-first" || auth.ViewPrefs[auth.PrefComposerPosition][0] != "top" ||
		auth.ViewPrefs[auth.PrefIssuesView][0] != "list" {
		t.Fatalf("defaults drifted: %v", auth.ViewPrefs)
	}
}

// SPL-1028: issues_view is kept on the account like the other layout keys:
// only list / status, null clears, independent of the others, and GET
// /session plus the native login answer carry it.
func TestPreferencesIssuesView(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["issues_view"] != nil {
		t.Fatalf("session before: %s", got.raw)
	} else if _, ok := got.body["issues_view"]; !ok {
		t.Fatalf("session must answer issues_view null: %s", got.raw)
	}
	got := r.call(t, c, http.MethodPut, "preferences", `{"issues_view":"status"}`)
	if got.code != http.StatusOK || len(got.body) != 1 || got.body["issues_view"] != "status" {
		t.Fatalf("put: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["issues_view"] != "status" || got.body["message_order"] != nil {
		t.Fatalf("session after: %s", got.raw)
	}
	if got := r.post(t, browser(t), "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK || got.body["issues_view"] != "status" {
		t.Fatalf("login answer: %d %s", got.code, got.raw)
	}
	for _, body := range []string{`{"issues_view":"board"}`, `{"issues_view":"Status"}`, `{"issues_view":""}`, `{"issues_view":"top"}`} {
		if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != http.StatusBadRequest || got.body["error"] != "unsupported_issues_view" {
			t.Errorf("%s: %d %s", body, got.code, got.raw)
		}
	}
	got = r.call(t, c, http.MethodPut, "preferences", `{"issues_view":null}`)
	if got.code != http.StatusOK || got.body["issues_view"] != nil || len(got.body) != 1 {
		t.Fatalf("clear: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["issues_view"] != nil {
		t.Fatalf("session after clear: %s", got.raw)
	}
}

// SPL-1132: issues_columns is kept on the account: an object of known sheet
// columns -> whole px, null or {} clears, independent of the other keys, and
// GET /session plus the native login answer carry it.
func TestPreferencesIssuesColumns(t *testing.T) {
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["issues_columns"] != nil {
		t.Fatalf("session before: %s", got.raw)
	} else if _, ok := got.body["issues_columns"]; !ok {
		t.Fatalf("session must answer issues_columns null: %s", got.raw)
	}
	got := r.call(t, c, http.MethodPut, "preferences", `{"issues_columns":{"key":96,"title":420,"status":140}}`)
	if got.code != http.StatusOK || len(got.body) != 1 || jsonBody(got.body["issues_columns"]) != `{"key":96,"status":140,"title":420}` {
		t.Fatalf("put: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); jsonBody(got.body["issues_columns"]) != `{"key":96,"status":140,"title":420}` || got.body["issues_view"] != nil {
		t.Fatalf("session after: %s", got.raw)
	}
	if got := r.post(t, browser(t), "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK ||
		jsonBody(got.body["issues_columns"]) != `{"key":96,"status":140,"title":420}` {
		t.Fatalf("login answer: %d %s", got.code, got.raw)
	}
	for _, body := range []string{
		`{"issues_columns":{"epic":100}}`, `{"issues_columns":{"key":10}}`, `{"issues_columns":{"key":2001}}`,
		`{"issues_columns":{"key":96.5}}`, `{"issues_columns":{"key":"96"}}`, `{"issues_columns":[96]}`,
		`{"issues_columns":"key"}`, `{"issues_columns":{"Key":96}}`,
	} {
		if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != http.StatusBadRequest || got.body["error"] != "unsupported_issues_columns" {
			t.Errorf("%s: %d %s", body, got.code, got.raw)
		}
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); jsonBody(got.body["issues_columns"]) != `{"key":96,"status":140,"title":420}` {
		t.Fatalf("a refused PUT changed the widths: %s", got.raw)
	}
	for _, clear := range []string{`{"issues_columns":{}}`, `{"issues_columns":null}`} {
		got = r.call(t, c, http.MethodPut, "preferences", clear)
		if got.code != http.StatusOK || got.body["issues_columns"] != nil || len(got.body) != 1 {
			t.Fatalf("clear %s: %d %s", clear, got.code, got.raw)
		}
		if got = r.call(t, c, http.MethodGet, "session", ""); got.body["issues_columns"] != nil {
			t.Fatalf("session after clear %s: %s", clear, got.raw)
		}
	}
}

// SPL-1133: close_buttons is kept on the account like the other layout keys:
// only mac / windows, null clears, independent of the others, and GET
// /session plus the native login answer carry it. Mac is the default.
func TestPreferencesCloseButtons(t *testing.T) {
	if auth.ViewPrefs[auth.PrefCloseButtons][0] != "mac" {
		t.Fatalf("default drifted: %v", auth.ViewPrefs[auth.PrefCloseButtons])
	}
	r, _ := newPRig(t, "", true)
	c := browser(t)
	r.signedIn(t, c, "person@example.com")
	if got := r.call(t, c, http.MethodGet, "session", ""); got.body["close_buttons"] != nil {
		t.Fatalf("session before: %s", got.raw)
	} else if _, ok := got.body["close_buttons"]; !ok {
		t.Fatalf("session must answer close_buttons null: %s", got.raw)
	}
	got := r.call(t, c, http.MethodPut, "preferences", `{"close_buttons":"windows"}`)
	if got.code != http.StatusOK || len(got.body) != 1 || got.body["close_buttons"] != "windows" {
		t.Fatalf("put: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["close_buttons"] != "windows" || got.body["issues_view"] != nil {
		t.Fatalf("session after: %s", got.raw)
	}
	if got := r.post(t, browser(t), "login", map[string]string{"email": "person@example.com", "password": pwA, "tenant": "acme"}); got.code != http.StatusOK || got.body["close_buttons"] != "windows" {
		t.Fatalf("login answer: %d %s", got.code, got.raw)
	}
	for _, body := range []string{`{"close_buttons":"linux"}`, `{"close_buttons":"Mac"}`, `{"close_buttons":""}`, `{"close_buttons":"list"}`} {
		if got := r.call(t, c, http.MethodPut, "preferences", body); got.code != http.StatusBadRequest || got.body["error"] != "unsupported_close_buttons" {
			t.Errorf("%s: %d %s", body, got.code, got.raw)
		}
	}
	got = r.call(t, c, http.MethodPut, "preferences", `{"close_buttons":null}`)
	if got.code != http.StatusOK || got.body["close_buttons"] != nil || len(got.body) != 1 {
		t.Fatalf("clear: %d %s", got.code, got.raw)
	}
	if got = r.call(t, c, http.MethodGet, "session", ""); got.body["close_buttons"] != nil {
		t.Fatalf("session after clear: %s", got.raw)
	}
}

// firstHum is the one HUM-* the rig registered.
func firstHum(p *fakePrefs) string {
	p.reg.mu.Lock()
	defer p.reg.mu.Unlock()
	for _, h := range p.reg.ids {
		return h
	}
	return ""
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
