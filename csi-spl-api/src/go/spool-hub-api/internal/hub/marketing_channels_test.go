package hub_test

import (
	"context"
	"crypto/ed25519"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 090 T006 / SPL-1634: connecting a LinkedIn account, against a fake
// LinkedIn. The token LinkedIn hands out is fakeLinkedInToken: it must reach
// the store only sealed, and never an answer or a log line.

const (
	fakeLinkedInToken  = "AQX-fake-member-token-0123456789"
	fakeLinkedInCode   = "code-ok"
	fakeLinkedInSecret = "fake-client-secret"
	fakeLinkedInSub    = "abc123"
)

// fakeLinkedIn answers the token exchange and userinfo, and records every
// request it saw ("METHOD path").
type fakeLinkedIn struct {
	*httptest.Server
	mu   sync.Mutex
	seen []string
}

func newFakeLinkedIn(t *testing.T) *fakeLinkedIn {
	t.Helper()
	f := &fakeLinkedIn{}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.seen = append(f.seen, r.Method+" "+r.URL.Path)
		f.mu.Unlock()
		f.serve(w, r)
	}))
	t.Cleanup(f.Close)
	return f
}

func (f *fakeLinkedIn) serve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch r.URL.Path {
	case "/oauth/v2/accessToken":
		_ = r.ParseForm()
		if r.PostForm.Get("client_secret") != fakeLinkedInSecret || r.PostForm.Get("code") != fakeLinkedInCode {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"error":"invalid_request","error_description":"bad code"}`)
			return
		}
		_, _ = io.WriteString(w, `{"access_token":"`+fakeLinkedInToken+`","expires_in":5184000,"scope":"openid,profile,w_member_social"}`)
	case "/v2/userinfo":
		if r.Header.Get("Authorization") != "Bearer "+fakeLinkedInToken {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = io.WriteString(w, `{"sub":"`+fakeLinkedInSub+`","name":"FirstName LastName"}`)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

type mktLinkedInEnv struct {
	*env
	li     *fakeLinkedIn
	m      *hub.MarketingLinkedIn
	logBuf *syncBuf
}

// linkedInEnv is mktEnv with the LinkedIn app wired to a fake LinkedIn and a
// fake KMS, and the hub's log captured.
func linkedInEnv(t *testing.T, allow []string, ids ...string) *mktLinkedInEnv {
	t.Helper()
	li := newFakeLinkedIn(t)
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k")
	if err != nil {
		t.Fatal(err)
	}
	m := &hub.MarketingLinkedIn{
		LinkedIn: &marketing.LinkedIn{ClientID: "client-id", ClientSecret: marketing.NewPlaintext(fakeLinkedInSecret),
			RedirectURI: "https://app.example.com/api/v1/marketing/linkedin/callback", Version: "202606",
			AuthBase: li.URL, APIBase: li.URL},
		Sealer: sealer, AppURL: "https://app.example.com", APIURL: "https://api.example.com",
	}
	buf := &syncBuf{}
	e := mktEnvWith(t, allow, func(o *hub.Options) {
		o.MarketingLinkedIn = m
		o.Log = zerolog.New(buf)
	}, ids...)
	return &mktLinkedInEnv{env: e, li: li, m: m, logBuf: buf}
}

// mktEnvWith is mktEnv with one more Options change.
func mktEnvWith(t *testing.T, allow []string, mut func(*hub.Options), ids ...string) *env {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) { o.MarketingWorkspaces = allow; mut(o) })
	for _, id := range ids {
		if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: mktPub()}); err != nil {
			t.Fatal(err)
		}
	}
	return e
}

// startConnect asks the hub for the authorize URL and returns its state.
func startConnect(t *testing.T, e *mktLinkedInEnv, tid, as string) string {
	t.Helper()
	code, body := call(t, e.env, tid, http.MethodPost, "/v1/marketing/linkedin/connect", as, nil)
	if code != http.StatusOK {
		t.Fatalf("connect: %d %v", code, body)
	}
	au, _ := body["authorize_url"].(string)
	u, err := url.Parse(au)
	if err != nil || !strings.HasPrefix(au, e.li.URL+"/oauth/v2/authorization?") {
		t.Fatalf("authorize_url %q", au)
	}
	q := u.Query()
	if q.Get("scope") != marketing.LinkedInScopes || q.Get("client_id") != "client-id" ||
		q.Get("redirect_uri") != e.m.LinkedIn.RedirectURI || q.Get("state") == "" {
		t.Fatalf("authorize_url query %v", q)
	}
	return q.Get("state")
}

// callback is LinkedIn's redirect: a browser with NO session (the WUI
// host's /api rewrite drops it), so no member header. It comes on the path
// the rewrite keeps, LinkedInCallbackPath (SPL-1688: only /v1 was routed).
func callback(t *testing.T, e *mktLinkedInEnv, tid string, q url.Values) (int, string) {
	t.Helper()
	return callbackAt(t, e, tid, hub.LinkedInCallbackPath, q)
}

func callbackAt(t *testing.T, e *mktLinkedInEnv, tid, path string, q url.Values) (int, string) {
	t.Helper()
	resp, err := e.client.Get(e.url(tid) + path + "?" + q.Encode())
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func mktOn(t *testing.T, e *env, tid, admin string) {
	t.Helper()
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/marketing/settings", admin, map[string]any{"enabled": true}); code != 200 {
		t.Fatalf("turn on: %d %v", code, body)
	}
}

func TestMarketingLinkedInConnect(t *testing.T) {
	ids := mktIDs(1)
	tid := ids[0]
	e := linkedInEnv(t, ids, tid)
	admin := seat(t, e.env, tid, rbac.Admin)
	mktOn(t, e.env, tid, admin)

	state := startConnect(t, e, tid, admin)
	code, page := callback(t, e, tid, url.Values{"code": {fakeLinkedInCode}, "state": {state}})
	if code != http.StatusOK || !strings.Contains(page, "LinkedIn connected") {
		t.Fatalf("callback: %d %s", code, page)
	}
	mk := e.st.(store.Marketing)
	chs, err := mk.MarketingChannels(context.Background(), tid)
	if err != nil || len(chs) != 1 {
		t.Fatalf("channels = %v, %v", chs, err)
	}
	ch := chs[0]
	if ch.AccountRef != fakeLinkedInSub || ch.DelegatedBy != admin || !ch.AutoPublish || ch.Status != store.MarketingActive || ch.ExpiresAt == nil {
		t.Fatalf("channel %+v", ch)
	}
	// the store holds only the sealed token, and it opens to LinkedIn's
	tok, err := mk.MarketingToken(context.Background(), tid, ch.ID)
	if err != nil || strings.Contains(tok.Ciphertext, fakeLinkedInToken) || tok.KMSKeyID == "" {
		t.Fatalf("stored token is not sealed: %v", err)
	}
	if p, err := e.m.Sealer.Open(context.Background(), tok.Ciphertext); err != nil || p.Reveal() != fakeLinkedInToken {
		t.Fatalf("sealed token does not open to LinkedIn's: %v", err)
	}
	// the list answer shows the channel and no token
	lc, list := call(t, e.env, tid, http.MethodGet, "/v1/marketing/channels", admin, nil)
	if lc != 200 || len(list["channels"].([]any)) != 1 {
		t.Fatalf("channels list: %d %v", lc, list)
	}
	// a second connect of the same LinkedIn member renews the one channel;
	// the hub-origin /v1 path answers too
	state = startConnect(t, e, tid, admin)
	if code, _ := callbackAt(t, e, tid, "/v1/marketing/linkedin/callback", url.Values{"code": {fakeLinkedInCode}, "state": {state}}); code != 200 {
		t.Fatalf("re-connect: %d", code)
	}
	if chs, _ := mk.MarketingChannels(context.Background(), tid); len(chs) != 1 {
		t.Fatalf("re-connect made %d channels, want 1", len(chs))
	}
	if strings.Contains(e.logBuf.String(), fakeLinkedInToken) || strings.Contains(page, fakeLinkedInToken) {
		t.Fatal("the LinkedIn token reached a log line or the page")
	}
}

func TestMarketingLinkedInConnectRefusals(t *testing.T) {
	ids := mktIDs(2)
	listed, unlisted := ids[0], ids[1]
	e := linkedInEnv(t, []string{listed}, listed, unlisted)
	admin, dev := seat(t, e.env, listed, rbac.Admin), seat(t, e.env, listed, rbac.Developer)
	// switched off: 404 even for the admin
	if code, _ := call(t, e.env, listed, http.MethodPost, "/v1/marketing/linkedin/connect", admin, nil); code != http.StatusNotFound {
		t.Fatalf("switch off: %d, want 404", code)
	}
	mktOn(t, e.env, listed, admin)
	if code, _ := call(t, e.env, listed, http.MethodPost, "/v1/marketing/linkedin/connect", dev, nil); code != http.StatusForbidden {
		t.Fatalf("developer connect: %d, want 403", code)
	}
	outAdmin := seat(t, e.env, unlisted, rbac.Admin)
	if code, _ := call(t, e.env, unlisted, http.MethodPost, "/v1/marketing/linkedin/connect", outAdmin, nil); code != http.StatusNotFound {
		t.Fatalf("unlisted connect: %d, want 404", code)
	}
	state := startConnect(t, e, listed, admin)
	for name, q := range map[string]url.Values{
		"no state":       {"code": {fakeLinkedInCode}},
		"forged state":   {"code": {fakeLinkedInCode}, "state": {"eyJ0IjoieCJ9.AAAA"}},
		"tampered state": {"code": {fakeLinkedInCode}, "state": {"x" + state}},
	} {
		if code, _ := callback(t, e, listed, q); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", name, code)
		}
	}
	// a code LinkedIn refuses stores nothing
	if code, _ := callback(t, e, listed, url.Values{"code": {"bad"}, "state": {state}}); code != http.StatusBadGateway {
		t.Fatalf("refused code: %d, want 502", code)
	}
	if chs, _ := e.st.(store.Marketing).MarketingChannels(context.Background(), listed); len(chs) != 0 {
		t.Fatalf("a refused code stored %d channel(s)", len(chs))
	}
}

func TestMarketingLinkedInNotConfigured(t *testing.T) {
	ids := mktIDs(1)
	e := mktEnv(t, ids, ids[0])
	admin := seat(t, e, ids[0], rbac.Admin)
	mktOn(t, e, ids[0], admin)
	if code, body := call(t, e, ids[0], http.MethodPost, "/v1/marketing/linkedin/connect", admin, nil); code != http.StatusServiceUnavailable {
		t.Fatalf("unconfigured connect: %d %v, want 503", code, body)
	}
}

// The GET form is the one-click link: a redirect straight to LinkedIn.
func TestMarketingLinkedInConnectLinkRedirects(t *testing.T) {
	ids := mktIDs(1)
	tid := ids[0]
	e := linkedInEnv(t, ids, tid)
	admin := seat(t, e.env, tid, rbac.Admin)
	mktOn(t, e.env, tid, admin)
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/marketing/linkedin/connect", nil)
	req.Header.Set(memberHeader, admin)
	c := *e.client
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound || !strings.HasPrefix(resp.Header.Get("Location"), e.li.URL+"/oauth/v2/authorization?") {
		t.Fatalf("connect link: %d %q", resp.StatusCode, resp.Header.Get("Location"))
	}
	if got := e.m.ConnectLink("spool"); got != "https://api.example.com/v1/marketing/linkedin/connect?workspace=spool" {
		t.Fatalf("ConnectLink = %q", got)
	}
}

func mktPub() ed25519.PublicKey {
	pub, _, _ := ed25519.GenerateKey(nil)
	return pub
}
