package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal/fakegcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 149 B5 (SPL-3208): a member connects their own Google Calendar,
// against fakegcal and a fake KMS; no test reaches Google. Cases C7-C12,
// C24, C24b, C24c of spec 149 section 5.

// gcalTestScopes is what cnf gcal.scopes would hold; deliberately not
// "openid email", so the test proves the hub sends the configured value and
// not a literal of its own.
const gcalTestScopes = "openid email https://scope.example/calendar-test"

const (
	gcalApp     = "https://app.example.com"
	gcalApexDom = "app.example.com"
	gcalCookie  = "__session"
)

// gcalClock is the hub's and the fake's shared clock.
type gcalClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *gcalClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *gcalClock) add(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

type gcalTestEnv struct {
	*env
	fake  *fakegcal.Fake
	gc    *hub.GcalConnect
	clock *gcalClock
	log   *syncBuf
	apex  string
}

// gcalEnvOf is a hub with the connect wired to a fake Google, the
// workspaces allow-listed, and tenants made for every id (the first is the
// apex workspace).
func gcalEnvOf(t *testing.T, allow []string, ids ...string) *gcalTestEnv {
	t.Helper()
	clock := &gcalClock{t: time.Now().UTC().Truncate(time.Second)}
	f := fakegcal.New(t)
	f.Now = clock.now
	google, err := gcal.New(f.Config(gcalApp+hub.GcalCallbackPath, gcalTestScopes))
	if err != nil {
		t.Fatal(err)
	}
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k",
		marketing.WithPurpose(hub.GcalPurpose))
	if err != nil {
		t.Fatal(err)
	}
	apex := ""
	if len(ids) > 0 {
		apex = ids[0]
	}
	gc := &hub.GcalConnect{Google: google, Sealer: sealer, Workspaces: allow, CookieName: gcalCookie,
		WorkspaceURL: hub.GcalWorkspaceURL("{tenant}."+gcalApexDom, apex, gcalApp)}
	buf := &syncBuf{}
	e := mktEnvWith(t, nil, func(o *hub.Options) {
		o.Gcal = gc
		o.Log = zerolog.New(buf)
		o.Now = clock.now
	}, ids...)
	return &gcalTestEnv{env: e, fake: f, gc: gc, clock: clock, log: buf, apex: apex}
}

// gcalDo sends one request as member `as` on tid's host, with the cookies
// given, and never follows a redirect.
func gcalDo(t *testing.T, e *gcalTestEnv, tid, method, path, as string, cookies ...*http.Cookie) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, e.url(tid)+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	for _, c := range cookies {
		req.AddCookie(c)
	}
	c := *e.client
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func gcalBody(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	out := map[string]any{}
	b, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("%d: not JSON: %s", resp.StatusCode, b)
	}
	return out
}

// gcalStart is C7's call: POST connect, answering the state and the nonce
// cookie the hub set.
func gcalStart(t *testing.T, e *gcalTestEnv, tid, as string) (string, *http.Cookie) {
	t.Helper()
	resp := gcalDo(t, e, tid, http.MethodPost, "/v1/me/google-calendar/connect", as)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("connect: %d %v", resp.StatusCode, gcalBody(t, resp))
	}
	au, _ := gcalBody(t, resp)["authorize_url"].(string)
	u, err := url.Parse(au)
	if err != nil || !strings.HasPrefix(au, e.fake.URL()+"/o/oauth2/v2/auth?") {
		t.Fatalf("authorize_url %q", au)
	}
	q := u.Query()
	if q.Get("access_type") != "offline" || q.Get("include_granted_scopes") != "true" || q.Get("state") == "" ||
		q.Get("scope") != gcalTestScopes || q.Get("client_id") != fakegcal.ClientID ||
		q.Get("redirect_uri") != gcalApp+hub.GcalCallbackPath {
		t.Fatalf("authorize_url query %v", q)
	}
	var nonce *http.Cookie
	for _, c := range resp.Cookies() {
		if c.Name == gcalCookie {
			nonce = c
		}
	}
	if nonce == nil || nonce.Value == "" || nonce.Path != "/v1/me/google-calendar/" || !nonce.HttpOnly {
		t.Fatalf("nonce cookie %+v", nonce)
	}
	return q.Get("state"), nonce
}

// gcalCallback is Google's redirect: no session, the code and the state, and
// the nonce cookie when the browser has it.
func gcalCallback(t *testing.T, e *gcalTestEnv, tid, code, state string, cookies ...*http.Cookie) *http.Response {
	t.Helper()
	q := url.Values{"code": {code}, "state": {state}}
	return gcalDo(t, e, tid, http.MethodGet, hub.GcalCallbackPath+"?"+q.Encode(), "", cookies...)
}

// gcalConnectMember runs the whole handshake for `as` and answers the
// callback's Location.
func gcalConnectMember(t *testing.T, e *gcalTestEnv, tid, as string) string {
	t.Helper()
	state, nonce := gcalStart(t, e, tid, as)
	resp := gcalCallback(t, e, tid, e.fake.IssueCode(fakegcal.DefaultEmail), state, nonce)
	if resp.StatusCode != http.StatusFound {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("callback: %d %s", resp.StatusCode, b)
	}
	return resp.Header.Get("Location")
}

func gcalRow(t *testing.T, e *gcalTestEnv, tid, hum string) (store.GcalConnection, error) {
	t.Helper()
	return e.st.(store.Gcal).GcalConnection(context.Background(), tid, hum)
}

// C7 + C8: connect in a listed workspace answers Google's consent URL with
// offline access and the cnf scopes; in an unlisted one, 404.
func TestGcalConnectListedAndUnlisted(t *testing.T) {
	ids := mktIDs(2)
	listed, unlisted := ids[0], ids[1]
	e := gcalEnvOf(t, []string{listed}, listed, unlisted)
	gcalStart(t, e, listed, seat(t, e.env, listed, rbac.Developer))

	out := seat(t, e.env, unlisted, rbac.Developer)
	for _, m := range []string{http.MethodPost, http.MethodGet} {
		resp := gcalDo(t, e, unlisted, m, "/v1/me/google-calendar/connect", out)
		if resp.StatusCode != http.StatusNotFound || gcalBody(t, resp)["error"] != "not_found" {
			t.Fatalf("%s connect in an unlisted workspace: %d, want 404 not_found", m, resp.StatusCode)
		}
	}
	if resp := gcalDo(t, e, unlisted, http.MethodGet, "/v1/me/google-calendar", out); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("GET in an unlisted workspace: %d, want 404", resp.StatusCode)
	}
	if e.fake.Calls("token") != 0 {
		t.Fatal("a refused connect reached Google")
	}
}

// The GET form is a plain link: 302 straight to Google, the cookie set.
func TestGcalConnectLinkRedirects(t *testing.T) {
	ids := mktIDs(1)
	e := gcalEnvOf(t, ids, ids...)
	resp := gcalDo(t, e, ids[0], http.MethodGet, "/v1/me/google-calendar/connect", seat(t, e.env, ids[0], rbac.Developer))
	if resp.StatusCode != http.StatusFound || !strings.HasPrefix(resp.Header.Get("Location"), e.fake.URL()+"/o/oauth2/v2/auth?") {
		t.Fatalf("GET connect: %d %q", resp.StatusCode, resp.Header.Get("Location"))
	}
	if len(resp.Cookies()) == 0 {
		t.Fatal("GET connect set no nonce cookie")
	}
}

// No client, no KMS key: 503 gcal_not_configured (section 2.8).
func TestGcalConnectNotConfigured(t *testing.T) {
	ids := mktIDs(1)
	e := gcalEnvOf(t, ids, ids...)
	e.gc.Google = nil
	resp := gcalDo(t, e, ids[0], http.MethodPost, "/v1/me/google-calendar/connect", seat(t, e.env, ids[0], rbac.Developer))
	if resp.StatusCode != http.StatusServiceUnavailable || gcalBody(t, resp)["error"] != "gcal_not_configured" {
		t.Fatalf("unconfigured connect: %d, want 503 gcal_not_configured", resp.StatusCode)
	}
}

// C9: a valid state without the nonce cookie is refused and stores nothing;
// twin: the same handshake with the cookie stores the row.
func TestGcalCallbackNeedsTheNonceCookie(t *testing.T) {
	ids := mktIDs(1)
	tid := ids[0]
	e := gcalEnvOf(t, ids, ids...)
	hum := seat(t, e.env, tid, rbac.Developer)
	state, nonce := gcalStart(t, e, tid, hum)

	resp := gcalCallback(t, e, tid, e.fake.IssueCode(fakegcal.DefaultEmail), state)
	if b, _ := io.ReadAll(resp.Body); resp.StatusCode != http.StatusBadRequest || !strings.Contains(string(b), "invalid_state") {
		t.Fatalf("no cookie: %d %s, want 400 invalid_state", resp.StatusCode, b)
	}
	forged := &http.Cookie{Name: gcalCookie, Value: "not-the-nonce", HttpOnly: true, Secure: true}
	if resp := gcalCallback(t, e, tid, e.fake.IssueCode(fakegcal.DefaultEmail), state, forged); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("wrong cookie: %d, want 400", resp.StatusCode)
	}
	if _, err := gcalRow(t, e, tid, hum); err != store.ErrNotFound {
		t.Fatalf("a refused callback stored a row: %v", err)
	}
	if e.fake.Calls("token") != 0 {
		t.Fatal("a refused callback exchanged the code")
	}
	resp = gcalCallback(t, e, tid, e.fake.IssueCode(fakegcal.DefaultEmail), state, nonce)
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("twin with the cookie: %d, want 302", resp.StatusCode)
	}
	c, err := gcalRow(t, e, tid, hum)
	if err != nil || c.GoogleEmail != fakegcal.DefaultEmail || c.Status != store.GcalConnected {
		t.Fatalf("twin stored %+v, %v", c, err)
	}
	if !strings.Contains(resp.Header.Get("Set-Cookie"), "Max-Age=0") {
		t.Fatalf("the callback did not clear the nonce cookie: %q", resp.Header.Get("Set-Cookie"))
	}
}

// C10: a state older than 15 minutes is refused, nothing stored.
func TestGcalCallbackExpiredState(t *testing.T) {
	ids := mktIDs(1)
	tid := ids[0]
	e := gcalEnvOf(t, ids, ids...)
	hum := seat(t, e.env, tid, rbac.Developer)
	state, nonce := gcalStart(t, e, tid, hum)
	e.clock.add(16 * time.Minute)
	if resp := gcalCallback(t, e, tid, e.fake.IssueCode(fakegcal.DefaultEmail), state, nonce); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expired state: %d, want 400", resp.StatusCode)
	}
	if _, err := gcalRow(t, e, tid, hum); err != store.ErrNotFound {
		t.Fatalf("an expired state stored a row: %v", err)
	}
}

// C11 + C12: after a connect neither Google token is in the stored row, a
// log line or the status answer, and the status JSON has no key naming a
// token or a sealed text.
func TestGcalConnectKeepsTokensSealed(t *testing.T) {
	ids := mktIDs(1)
	tid := ids[0]
	e := gcalEnvOf(t, ids, ids...)
	hum := seat(t, e.env, tid, rbac.Developer)
	resp := gcalDo(t, e, tid, http.MethodGet, "/v1/me/google-calendar", hum)
	if body := gcalBody(t, resp); resp.StatusCode != http.StatusOK || body["connected"] != false || len(body) != 1 {
		t.Fatalf("before connect: %d %v, want {connected:false}", resp.StatusCode, body)
	}
	gcalConnectMember(t, e, tid, hum)

	ctx := context.Background()
	gs := e.st.(store.Gcal)
	tok, err := gs.GcalTokens(ctx, tid, hum)
	if err != nil {
		t.Fatal(err)
	}
	access, err := e.gc.Sealer.Open(ctx, tok.AccessSealed)
	if err != nil {
		t.Fatalf("the access token does not open under the gcal purpose: %v", err)
	}
	refresh, err := e.gc.Sealer.Open(ctx, tok.RefreshSealed)
	if err != nil {
		t.Fatalf("the refresh token does not open under the gcal purpose: %v", err)
	}
	if !strings.HasPrefix(access.Reveal(), "fake-access-") || !strings.HasPrefix(refresh.Reveal(), "fake-refresh-") {
		t.Fatal("the sealed texts are not the fake's tokens")
	}
	row, _ := gcalRow(t, e, tid, hum)
	resp = gcalDo(t, e, tid, http.MethodGet, "/v1/me/google-calendar", hum)
	raw, _ := io.ReadAll(resp.Body)
	stored := fmt.Sprintf("%+v %+v", row, tok)
	for _, secret := range []string{access.Reveal(), refresh.Reveal()} {
		for where, text := range map[string]string{"stored row": stored, "log": e.log.String(), "status answer": string(raw)} {
			if strings.Contains(text, secret) {
				t.Fatalf("a Google token is in the %s", where)
			}
		}
	}
	if !strings.Contains(e.log.String(), "gcal: connected") {
		t.Fatal("the log was not captured: the check above proves nothing")
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("status: %d %s", resp.StatusCode, raw)
	}
	for k := range body {
		if strings.Contains(k, "token") || strings.Contains(k, "sealed") {
			t.Fatalf("status answer has key %q", k)
		}
	}
	if body["connected"] != true || body["google_email"] != fakegcal.DefaultEmail || body["status"] != store.GcalConnected ||
		body["calendar_title"] != "Spool Hub ("+tid+")" {
		t.Fatalf("status answer %v", body)
	}
}

// gcalMapOutgoing gives the member's connection a map row for a Spool event
// the member created (an outgoing event, no gcal: source key), as the sync
// cycle would.
func gcalMapOutgoing(t *testing.T, e *gcalTestEnv, tid, hum string) string {
	t.Helper()
	ctx := context.Background()
	at := e.clock.now().Add(24 * time.Hour)
	ev, err := e.st.(store.Calendar).CreateCalendarEvent(ctx, tid, store.CalendarEvent{Title: "planning", Kind: "other",
		StartsAt: at, EndsAt: at.Add(time.Hour), Audience: "private", CreatorType: "human", CreatorID: hum}, e.clock.now())
	if err != nil {
		t.Fatal(err)
	}
	gs := e.st.(store.Gcal)
	_, lease, err := gs.ClaimGcalConnection(ctx, e.clock.now(), 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := gs.PutGcalEventMap(ctx, lease, store.GcalEventMap{EventID: ev.ID, GoogleID: "g-" + ev.ID,
		SyncHash: strings.Repeat("a", 64)}, e.clock.now()); err != nil {
		t.Fatal(err)
	}
	return ev.ID
}

// C24: disconnect revokes the grant at Google and deletes the row; the
// member's events stay, and remove_imported=1 never trashes an event that
// did not come from Google.
func TestGcalDisconnect(t *testing.T) {
	ids := mktIDs(1)
	tid := ids[0]
	e := gcalEnvOf(t, ids, ids...)
	// a clock in the past: on Postgres the claim in gcalMapOutgoing takes the
	// connection due longest across every workspace, so only this test's
	// own connection may be due at its now
	e.clock.add(-20 * 365 * 24 * time.Hour)
	hum := seat(t, e.env, tid, rbac.Developer)
	ctx := context.Background()
	if resp := gcalDo(t, e, tid, http.MethodDelete, "/v1/me/google-calendar", hum); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("disconnect with no connection: %d, want 404", resp.StatusCode)
	}
	for _, rm := range []string{"0", "1"} {
		gcalConnectMember(t, e, tid, hum)
		tok, _ := e.st.(store.Gcal).GcalTokens(ctx, tid, hum)
		refresh, _ := e.gc.Sealer.Open(ctx, tok.RefreshSealed)
		evID := gcalMapOutgoing(t, e, tid, hum)
		e.fake.ResetCalls()

		resp := gcalDo(t, e, tid, http.MethodDelete, "/v1/me/google-calendar?remove_imported="+rm, hum)
		if resp.StatusCode != http.StatusNoContent {
			t.Fatalf("remove_imported=%s: %d, want 204", rm, resp.StatusCode)
		}
		if e.fake.Calls("revoke") != 1 || !e.fake.Revoked(refresh.Reveal()) {
			t.Fatalf("remove_imported=%s: revoke calls %d, revoked %v", rm, e.fake.Calls("revoke"), e.fake.Revoked(refresh.Reveal()))
		}
		if _, err := gcalRow(t, e, tid, hum); err != store.ErrNotFound {
			t.Fatalf("remove_imported=%s: the row is still there: %v", rm, err)
		}
		if maps, _ := e.st.(store.Gcal).GcalEventMaps(ctx, tid, hum); len(maps) != 0 {
			t.Fatalf("remove_imported=%s: %d map rows left", rm, len(maps))
		}
		ev, err := e.st.(store.Calendar).GetCalendarEvent(ctx, tid, hum, evID)
		if err != nil || !ev.DeletedAt.IsZero() {
			t.Fatalf("remove_imported=%s: the member's own event went: %v %v", rm, err, ev.DeletedAt)
		}
	}
	gcalConnectMember(t, e, tid, hum)
	if resp := gcalDo(t, e, tid, http.MethodDelete, "/v1/me/google-calendar?remove_imported=yes", hum); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("remove_imported=yes: %d, want 400", resp.StatusCode)
	}
}

// C24b: a member who started on workspace w2's host lands back on w2's
// host; twin: the apex workspace lands on the apex.
func TestGcalCallbackLandsOnTheWorkspaceHost(t *testing.T) {
	ids := mktIDs(2)
	apex, w2 := ids[0], ids[1]
	e := gcalEnvOf(t, ids, ids...)
	for tid, want := range map[string]string{
		w2:   "https://" + w2 + "." + gcalApexDom + "/?settings=calendar-google&gcal=connected",
		apex: "https://" + gcalApexDom + "/?settings=calendar-google&gcal=connected",
	} {
		if got := gcalConnectMember(t, e, tid, seat(t, e.env, tid, rbac.Developer)); got != want {
			t.Fatalf("workspace %s: Location %q, want %q", tid, got, want)
		}
	}
	// Google's "error" (the member said no) lands there too and stores nothing
	hum := seat(t, e.env, w2, rbac.Developer)
	state, nonce := gcalStart(t, e, w2, hum)
	q := url.Values{"error": {"access_denied"}, "state": {state}}
	resp := gcalDo(t, e, w2, http.MethodGet, hub.GcalCallbackPath+"?"+q.Encode(), "", nonce)
	if loc := resp.Header.Get("Location"); resp.StatusCode != http.StatusFound || !strings.HasSuffix(loc, "gcal_error=cancelled") {
		t.Fatalf("denied consent: %d %q", resp.StatusCode, loc)
	}
	if _, err := gcalRow(t, e, w2, hum); err != store.ErrNotFound {
		t.Fatalf("denied consent stored a row: %v", err)
	}
}

// C24c: the browser preflight answers 204 with the CORS headers of
// /v1/me/hours, and the methods of each path.
func TestGcalPreflight(t *testing.T) {
	ids := mktIDs(1)
	e := gcalEnvOf(t, ids, ids...)
	preflight := func(path string) *http.Response {
		req, _ := http.NewRequest(http.MethodOptions, e.url(ids[0])+path, nil)
		req.Header.Set("Origin", wuiOrigin)
		req.Header.Set("Access-Control-Request-Method", http.MethodGet)
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp
	}
	hours := preflight("/v1/me/hours")
	for path, methods := range map[string]string{"/v1/me/google-calendar": "GET, DELETE", "/v1/me/google-calendar/connect": "GET, POST"} {
		resp := preflight(path)
		if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Methods") != methods {
			t.Fatalf("OPTIONS %s: %d methods %q", path, resp.StatusCode, resp.Header.Get("Access-Control-Allow-Methods"))
		}
		for _, h := range []string{"Access-Control-Allow-Origin", "Access-Control-Allow-Credentials", "Access-Control-Allow-Headers", "Access-Control-Max-Age"} {
			if resp.Header.Get(h) != hours.Header.Get(h) {
				t.Fatalf("OPTIONS %s: %s %q, /v1/me/hours has %q", path, h, resp.Header.Get(h), hours.Header.Get(h))
			}
		}
	}
	if hours.Header.Get("Access-Control-Allow-Origin") != wuiOrigin {
		t.Fatal("the /v1/me/hours preflight allowed no origin: the comparison above proves nothing")
	}
}

// The workspace URL: a tenant host, the apex for the apex workspace, the
// app URL when tenant hosts are off.
func TestGcalWorkspaceURL(t *testing.T) {
	f := hub.GcalWorkspaceURL("{tenant}.example.test", "t1", "https://example.test/")
	if f("w2") != "https://w2.example.test" || f("t1") != "https://example.test" {
		t.Fatalf("with a pattern: %q %q", f("w2"), f("t1"))
	}
	if g := hub.GcalWorkspaceURL("", "t1", "https://example.test/"); g("w2") != "https://example.test" {
		t.Fatalf("without a pattern: %q", g("w2"))
	}
}
