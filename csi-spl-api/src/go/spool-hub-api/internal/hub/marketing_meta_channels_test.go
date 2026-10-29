package hub_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 090 T033 / SPL-4254: connecting Facebook Pages and their Instagram
// accounts, against a fake Meta Graph API. Every token value below is an
// obvious fake; each must reach the store only sealed, and never an answer
// or a log line. The user token is never stored at all.

const (
	fakeMetaSecret     = "fake-meta-app-secret-not-a-secret"
	fakeMetaCode       = "fake-meta-code"
	fakeMetaShortToken = "fake-meta-short-user-token-not-a-secret"
	fakeMetaUserToken  = "fake-meta-long-user-token-not-a-secret"
	fakeMetaPageTokenA = "fake-meta-page-token-a-not-a-secret"
	fakeMetaPageTokenB = "fake-meta-page-token-b-not-a-secret"
)

// fakeMeta answers the two token exchanges and /me/accounts (two Pages, the
// first with an Instagram account), and records every request it saw.
type fakeMeta struct {
	*httptest.Server
	mu   sync.Mutex
	seen []string
}

func newFakeMeta(t *testing.T) *fakeMeta {
	t.Helper()
	f := &fakeMeta{}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.seen = append(f.seen, r.Method+" "+r.URL.Path)
		f.mu.Unlock()
		f.serve(w, r)
	}))
	t.Cleanup(f.Close)
	return f
}

func (f *fakeMeta) serve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch r.URL.Path {
	case "/v26.0/oauth/access_token":
		_ = r.ParseForm()
		switch {
		case r.PostForm.Get("client_secret") != fakeMetaSecret:
			metaFakeError(w, http.StatusBadRequest, 1)
		case r.PostForm.Get("code") == fakeMetaCode:
			_, _ = io.WriteString(w, `{"access_token":"`+fakeMetaShortToken+`","token_type":"bearer","expires_in":3600}`)
		case r.PostForm.Get("fb_exchange_token") == fakeMetaShortToken:
			_, _ = io.WriteString(w, `{"access_token":"`+fakeMetaUserToken+`","token_type":"bearer","expires_in":5184000}`)
		default:
			metaFakeError(w, http.StatusBadRequest, 100)
		}
	case "/v26.0/me/accounts":
		if r.Header.Get("Authorization") != "Bearer "+fakeMetaUserToken {
			metaFakeError(w, http.StatusUnauthorized, 190)
			return
		}
		_, _ = io.WriteString(w, `{"data":[`+
			`{"id":"1001","name":"Page A","access_token":"`+fakeMetaPageTokenA+`","tasks":["CREATE_CONTENT"],`+
			`"instagram_business_account":{"id":"17841","username":"page_a_ig","name":"Page A IG"}},`+
			`{"id":"1002","name":"Page B","access_token":"`+fakeMetaPageTokenB+`","tasks":["CREATE_CONTENT"]}],"paging":{}}`)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func metaFakeError(w http.ResponseWriter, status, code int) {
	w.WriteHeader(status)
	b, _ := json.Marshal(map[string]any{"error": map[string]any{"message": "refused by the fake", "type": "OAuthException", "code": code}})
	_, _ = w.Write(b)
}

type mktMetaEnv struct {
	*env
	fb     *fakeMeta
	m      *hub.MarketingMeta
	logBuf *syncBuf
}

// metaEnv is mktEnv with the Meta app wired to a fake Meta and a fake KMS,
// and the hub's log captured.
func metaEnv(t *testing.T, allow []string, ids ...string) *mktMetaEnv {
	t.Helper()
	fb := newFakeMeta(t)
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k")
	if err != nil {
		t.Fatal(err)
	}
	m := &hub.MarketingMeta{
		Meta: &marketing.Meta{AppID: "app-id", AppSecret: marketing.NewPlaintext(fakeMetaSecret),
			RedirectURI: "https://app.example.com" + hub.MetaCallbackPath, Version: "v26.0",
			GraphBase: fb.URL, DialogBase: fb.URL, Attempts: 1},
		Sealer: sealer, AppURL: "https://app.example.com",
	}
	buf := &syncBuf{}
	e := mktEnvWith(t, allow, func(o *hub.Options) {
		o.MarketingMeta = m
		o.Log = zerolog.New(buf)
	}, ids...)
	return &mktMetaEnv{env: e, fb: fb, m: m, logBuf: buf}
}

// startMetaConnect asks the hub for the dialog URL and returns its state.
func startMetaConnect(t *testing.T, e *mktMetaEnv, tid, as string) string {
	t.Helper()
	code, body := call(t, e.env, tid, http.MethodPost, "/v1/marketing/facebook/connect", as, nil)
	if code != http.StatusOK {
		t.Fatalf("connect: %d %v", code, body)
	}
	au, _ := body["authorize_url"].(string)
	u, err := url.Parse(au)
	if err != nil || !strings.HasPrefix(au, e.fb.URL+"/v26.0/dialog/oauth?") {
		t.Fatalf("authorize_url %q", au)
	}
	q := u.Query()
	if q.Get("scope") != "pages_show_list,pages_read_engagement,pages_manage_posts,instagram_basic,instagram_content_publish" ||
		q.Get("client_id") != "app-id" || q.Get("redirect_uri") != e.m.Meta.RedirectURI ||
		q.Get("response_type") != "code" || q.Get("state") == "" {
		t.Fatalf("authorize_url query %v", q)
	}
	return q.Get("state")
}

// metaCallback is Meta's redirect: a browser with NO session, on the path
// the WUI host's rewrite keeps.
func metaCallback(t *testing.T, e *mktMetaEnv, tid, path string, q url.Values) (int, string) {
	t.Helper()
	resp, err := e.client.Get(e.url(tid) + path + "?" + q.Encode())
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestMarketingMetaConnect(t *testing.T) {
	ids := mktIDs(1)
	tid := ids[0]
	e := metaEnv(t, ids, tid)
	admin := seat(t, e.env, tid, rbac.Admin)
	mktOn(t, e.env, tid, admin)

	state := startMetaConnect(t, e, tid, admin)
	code, page := metaCallback(t, e, tid, hub.MetaCallbackPath, url.Values{"code": {fakeMetaCode}, "state": {state}})
	if code != http.StatusOK || !strings.Contains(page, "Facebook connected") || !strings.Contains(page, "2 Facebook Page(s) and 1 Instagram account(s)") {
		t.Fatalf("callback: %d %s", code, page)
	}
	mk := e.st.(store.Marketing)
	chs, err := mk.MarketingChannels(context.Background(), tid)
	if err != nil || len(chs) != 3 {
		t.Fatalf("channels = %+v, %v; want 2 Pages + 1 Instagram", chs, err)
	}
	want := map[string]string{"facebook_page/1001": fakeMetaPageTokenA, "facebook_page/1002": fakeMetaPageTokenB, "instagram_business/17841": fakeMetaPageTokenA}
	for _, ch := range chs {
		key := ch.Platform + "/" + ch.AccountRef
		pageTok, ok := want[key]
		if !ok || ch.AutoPublish || ch.DelegatedBy != admin || ch.Status != store.MarketingActive || ch.ExpiresAt != nil {
			t.Fatalf("channel %+v (auto_publish must be off: every post waits for approval)", ch)
		}
		tok, err := mk.MarketingToken(context.Background(), tid, ch.ID)
		if err != nil || strings.Contains(tok.Ciphertext, "not-a-secret") || tok.KMSKeyID == "" {
			t.Fatalf("%s: stored token is not sealed: %v", key, err)
		}
		if p, err := e.m.Sealer.Open(context.Background(), tok.Ciphertext); err != nil || p.Reveal() != pageTok {
			t.Fatalf("%s: sealed token does not open to its Page's token: %v", key, err)
		}
	}

	pc, pages := call(t, e.env, tid, http.MethodGet, "/v1/marketing/facebook/pages", admin, nil)
	raw, _ := json.Marshal(pages)
	list, _ := pages["pages"].([]any)
	if pc != http.StatusOK || len(list) != 2 || !strings.Contains(string(raw), `"username":"page_a_ig"`) || !strings.Contains(string(raw), `"instagram":null`) {
		t.Fatalf("pages: %d %s", pc, raw)
	}

	// a second connect renews the same three channels; the hub-origin /v1 path answers too
	state = startMetaConnect(t, e, tid, admin)
	if code, _ := metaCallback(t, e, tid, "/v1/marketing/facebook/callback", url.Values{"code": {fakeMetaCode}, "state": {state}}); code != http.StatusOK {
		t.Fatalf("re-connect: %d", code)
	}
	if chs, _ := mk.MarketingChannels(context.Background(), tid); len(chs) != 3 {
		t.Fatalf("re-connect made %d channels, want 3", len(chs))
	}
	for _, s := range []string{e.logBuf.String(), page, string(raw)} {
		if strings.Contains(s, "not-a-secret") || strings.Contains(s, fakeMetaCode) {
			t.Fatal("a Meta token, the app secret or the code reached a log line or an answer")
		}
	}
}

// The row's red controls: a missing or tampered state is 400 bad_state; a
// workspace off the allow-list is 404 (connect and callback alike).
func TestMarketingMetaConnectRefusals(t *testing.T) {
	ids := mktIDs(2)
	listed, unlisted := ids[0], ids[1]
	e := metaEnv(t, []string{listed}, listed, unlisted)
	admin, dev := seat(t, e.env, listed, rbac.Admin), seat(t, e.env, listed, rbac.Developer)
	if code, _ := call(t, e.env, listed, http.MethodPost, "/v1/marketing/facebook/connect", admin, nil); code != http.StatusNotFound {
		t.Fatalf("switch off: %d, want 404", code)
	}
	mktOn(t, e.env, listed, admin)
	if code, _ := call(t, e.env, listed, http.MethodPost, "/v1/marketing/facebook/connect", dev, nil); code != http.StatusForbidden {
		t.Fatalf("developer connect: %d, want 403", code)
	}
	outAdmin := seat(t, e.env, unlisted, rbac.Admin)
	for _, p := range []string{"/v1/marketing/facebook/connect", "/v1/marketing/facebook/pages"} {
		method := http.MethodGet
		if strings.HasSuffix(p, "/connect") {
			method = http.MethodPost
		}
		if code, _ := call(t, e.env, unlisted, method, p, outAdmin, nil); code != http.StatusNotFound {
			t.Fatalf("unlisted %s %s: %d, want 404", method, p, code)
		}
	}
	// a validly signed state for a workspace off the allow-list stores nothing
	off := e.m.Meta.NewState(marketing.State{Tenant: unlisted, Member: outAdmin, Exp: time.Now().Add(10 * time.Minute).Unix()})
	if code, _ := metaCallback(t, e, unlisted, hub.MetaCallbackPath, url.Values{"code": {fakeMetaCode}, "state": {off}}); code != http.StatusNotFound {
		t.Fatalf("unlisted callback: %d, want 404", code)
	}
	state := startMetaConnect(t, e, listed, admin)
	li := (&marketing.LinkedIn{ClientSecret: marketing.NewPlaintext(fakeMetaSecret)}).NewState(marketing.State{Tenant: listed, Member: admin, Exp: time.Now().Add(10 * time.Minute).Unix()})
	for name, q := range map[string]url.Values{
		"no state":       {"code": {fakeMetaCode}},
		"forged state":   {"code": {fakeMetaCode}, "state": {"eyJ0IjoieCJ9.AAAA"}},
		"tampered state": {"code": {fakeMetaCode}, "state": {"x" + state}},
		"linkedin state": {"code": {fakeMetaCode}, "state": {li}},
	} {
		if code, body := metaCallback(t, e, listed, hub.MetaCallbackPath, q); code != http.StatusBadRequest || !strings.Contains(body, `"bad_state"`) {
			t.Errorf("%s: %d %s, want 400 bad_state", name, code, body)
		}
	}
	// Meta's refusal and a code Meta refuses store nothing
	if code, page := metaCallback(t, e, listed, hub.MetaCallbackPath, url.Values{"error": {"access_denied"}, "state": {state}}); code != http.StatusOK || !strings.Contains(page, "Nothing was stored") {
		t.Fatalf("access_denied: %d %s", code, page)
	}
	if code, _ := metaCallback(t, e, listed, hub.MetaCallbackPath, url.Values{"code": {"refused-code"}, "state": {state}}); code != http.StatusBadGateway {
		t.Fatalf("refused code: %d, want 502", code)
	}
	if chs, _ := e.st.(store.Marketing).MarketingChannels(context.Background(), listed); len(chs) != 0 {
		t.Fatalf("a refusal stored %d channel(s)", len(chs))
	}
	if strings.Contains(e.logBuf.String(), "not-a-secret") {
		t.Fatal("a Meta secret reached a log line")
	}
}

// Unset config: every route answers 503 not_configured, never a crash and
// never a guess; the allow-list still comes first (404).
func TestMarketingMetaNotConfigured(t *testing.T) {
	ids := mktIDs(2)
	listed, unlisted := ids[0], ids[1]
	e := mktEnv(t, []string{listed}, listed, unlisted)
	admin := seat(t, e, listed, rbac.Admin)
	mktOn(t, e, listed, admin)
	for _, x := range []struct{ method, path string }{
		{http.MethodPost, "/v1/marketing/facebook/connect"}, {http.MethodGet, "/v1/marketing/facebook/connect"},
		{http.MethodGet, "/v1/marketing/facebook/pages"}, {http.MethodGet, "/v1/marketing/facebook/callback?state=x"},
		{http.MethodGet, hub.MetaCallbackPath + "?state=x"},
	} {
		if code, body := call(t, e, listed, x.method, x.path, admin, nil); code != http.StatusServiceUnavailable || body["error"] != "not_configured" {
			t.Errorf("unconfigured %s %s: %d %v, want 503 not_configured", x.method, x.path, code, body)
		}
	}
	outAdmin := seat(t, e, unlisted, rbac.Admin)
	if code, _ := call(t, e, unlisted, http.MethodPost, "/v1/marketing/facebook/connect", outAdmin, nil); code != http.StatusNotFound {
		t.Fatalf("unconfigured + unlisted connect: %d, want 404", code)
	}
}

// The GET form is the one-click link: a redirect straight to Meta's dialog.
func TestMarketingMetaConnectLinkRedirects(t *testing.T) {
	ids := mktIDs(1)
	tid := ids[0]
	e := metaEnv(t, ids, tid)
	admin := seat(t, e.env, tid, rbac.Admin)
	mktOn(t, e.env, tid, admin)
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/marketing/facebook/connect", nil)
	req.Header.Set(memberHeader, admin)
	c := *e.client
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound || !strings.HasPrefix(resp.Header.Get("Location"), e.fb.URL+"/v26.0/dialog/oauth?") {
		t.Fatalf("connect link: %d %q", resp.StatusCode, resp.Header.Get("Location"))
	}
}
