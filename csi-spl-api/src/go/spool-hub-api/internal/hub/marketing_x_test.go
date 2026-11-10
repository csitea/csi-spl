package hub_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
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

// Spec 090 X row / SPL-5194: connecting an X account with OAuth 2.0 PKCE and
// publishing a live blog post on it on a member's press, against a fake X
// and a fake blog (one server). Every token below is an obvious fake; each
// reaches the store only sealed, and never an answer or a log line. The
// proofs: 503 while X is not configured; only tenant.settings connects; the
// callback checks the PKCE verifier; a biz_owner who did not connect the
// account publishes once (409 the second time), the text within 280; a
// developer cannot; an ended access token is refreshed and the new pair
// sealed back; a refused token expires the channel and the post waits; a
// 429 is retried, a 500 is never resent and is mailed.

const (
	fakeXSecret = "fake-x-client-secret-not-a-secret"
	fakeXCode   = "fake-x-code"
)

type xFake struct {
	*httptest.Server
	mu       sync.Mutex
	posts    []marketing.BlogPost
	gen      int      // the token pair generation: access acc-<gen>-not-a-secret
	verifier string   // the PKCE verifier the code was issued for
	tweets   []string // every POST /2/tweets text
	postFail func(w http.ResponseWriter) bool
}

func (f *xFake) access() string  { return "acc-" + strconv.Itoa(f.gen) + "-not-a-secret" }
func (f *xFake) refresh() string { return "ref-" + strconv.Itoa(f.gen) + "-not-a-secret" }

func newXFake(t *testing.T) *xFake {
	t.Helper()
	f := &xFake{posts: []marketing.BlogPost{
		{ID: "2026-11-10-hello", Title: "Hello X", Summary: strings.Repeat("A long summary. ", 40)},
		{ID: "2026-11-09-two", Title: "Two", Summary: "Short."},
	}}
	f.Server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.Close)
	return f
}

func (f *xFake) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	_ = r.ParseForm()
	switch r.URL.Path {
	case "/blog-md/index.json":
		_ = json.NewEncoder(w).Encode(map[string]any{"locales": map[string]any{"en": f.posts}})
	case "/2/oauth2/token":
		f.token(w, r)
	case "/2/users/me":
		if r.Header.Get("Authorization") != "Bearer "+f.access() {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = io.WriteString(w, `{"data":{"id":"42","name":"Csitea","username":"csitea"}}`)
	case "/2/tweets":
		var b struct {
			Text string `json:"text"`
		}
		_ = json.NewDecoder(r.Body).Decode(&b)
		if r.Header.Get("Authorization") != "Bearer "+f.access() {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"title":"Unauthorized","detail":"Unauthorized","status":401}`)
			return
		}
		f.tweets = append(f.tweets, b.Text)
		if f.postFail != nil && f.postFail(w) {
			return
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"data":{"id":"185`+strconv.Itoa(len(f.tweets))+`","text":"x"}}`)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (f *xFake) token(w http.ResponseWriter, r *http.Request) {
	id, secret, ok := r.BasicAuth()
	pair := func() {
		_, _ = io.WriteString(w, `{"token_type":"bearer","access_token":"`+f.access()+`","refresh_token":"`+f.refresh()+`","expires_in":7200}`)
	}
	switch {
	case !ok || id != "x-client" || secret != fakeXSecret:
		w.WriteHeader(http.StatusUnauthorized)
	case r.PostForm.Get("grant_type") == "authorization_code" && r.PostForm.Get("code") == fakeXCode && r.PostForm.Get("code_verifier") == f.verifier:
		f.gen++
		pair()
	case r.PostForm.Get("grant_type") == "refresh_token" && r.PostForm.Get("refresh_token") == f.refresh():
		f.gen++ // X rotates the refresh token
		pair()
	default:
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"error":"invalid_request","error_description":"Value passed for the token was invalid."}`)
	}
}

func (f *xFake) set(fn func(f *xFake)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

func (f *xFake) sent() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.tweets...)
}

type xEnv struct {
	*env
	fake  *xFake
	m     *hub.MarketingX
	clock *shareClock
	tid   string
	admin string
	owner string
	dev   string
	mails *[]string
	buf   *syncBuf
}

// newXEnv: an allow-listed, switched-on workspace with an admin, a
// biz_owner and a developer, wired to a fake X; xOff leaves X unconfigured.
func newXEnv(t *testing.T, xOff bool) *xEnv {
	t.Helper()
	fake := newXFake(t)
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k")
	if err != nil {
		t.Fatal(err)
	}
	mails := &[]string{}
	var mailMu sync.Mutex
	m := &hub.MarketingX{
		X: &marketing.X{ClientID: "x-client", ClientSecret: marketing.NewPlaintext(fakeXSecret),
			RedirectURI: "https://app.example.com" + hub.XCallbackPath, AuthBase: fake.URL, APIBase: fake.URL, HTTP: fake.Client()},
		Sealer: sealer, AppURL: fake.URL, APIURL: "https://api.example.com",
		Mail: func(_ context.Context, to, subject, body string) error {
			mailMu.Lock()
			defer mailMu.Unlock()
			*mails = append(*mails, to+"|"+subject+"|"+body)
			return nil
		},
	}
	clock := &shareClock{now: time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)}
	buf := &syncBuf{}
	tid := mktIDs(1)[0]
	e := mktEnvWith(t, []string{tid}, func(o *hub.Options) {
		if !xOff {
			o.MarketingX = m
		}
		o.Log = zerolog.New(buf)
		o.Now = clock.Now
	}, tid)
	admin := seat(t, e, tid, rbac.Admin)
	mktOn(t, e, tid, admin)
	return &xEnv{env: e, fake: fake, m: m, clock: clock, tid: tid, admin: admin, owner: seat(t, e, tid, rbac.BizOwner),
		dev: seat(t, e, tid, rbac.Developer), mails: mails, buf: buf}
}

// connect runs the connect as `as`: the authorize URL, then X's redirect to
// the callback (a browser with no session) on the WUI path.
func (e *xEnv) connect(t *testing.T, as string) (int, string) {
	t.Helper()
	code, body := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/x/connect", as, nil)
	if code != http.StatusOK {
		t.Fatalf("connect: %d %v", code, body)
	}
	au, _ := body["authorize_url"].(string)
	u, err := url.Parse(au)
	if err != nil || !strings.HasPrefix(au, e.fake.URL+"/i/oauth2/authorize?") {
		t.Fatalf("authorize_url %q", au)
	}
	q := u.Query()
	st := q.Get("state")
	if q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") != marketing.Challenge(e.m.X.Verifier(st)) ||
		q.Get("scope") != marketing.XScopes || q.Get("redirect_uri") != e.m.X.RedirectURI || st == "" {
		t.Fatalf("authorize_url query %v", q)
	}
	e.fake.set(func(f *xFake) { f.verifier = e.m.X.Verifier(st) })
	resp, err := e.client.Get(e.url(e.tid) + hub.XCallbackPath + "?" + url.Values{"code": {fakeXCode}, "state": {st}}.Encode())
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func (e *xEnv) channel(t *testing.T) store.MarketingChannel {
	t.Helper()
	chs, _ := e.st.(store.Marketing).MarketingChannels(context.Background(), e.tid)
	for _, c := range chs {
		if c.Platform == store.MarketingPlatformX {
			return c
		}
	}
	t.Fatal("no X channel")
	return store.MarketingChannel{}
}

func (e *xEnv) publish(t *testing.T, as, post string, ch store.MarketingChannel) (int, map[string]any) {
	t.Helper()
	return call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/"+post+"/publish?channel="+ch.ID, as, nil)
}

func (e *xEnv) post(t *testing.T, ch store.MarketingChannel, ref string) store.MarketingPost {
	t.Helper()
	p, err := e.st.(store.MarketingMetaDispatch).MarketingPostByRef(context.Background(), e.tid, ch.ID, store.MarketingSourceBlog, ref)
	if err != nil {
		t.Fatalf("post %s: %v", ref, err)
	}
	return p
}

// The red control: with no X app every X route answers 503 not_configured.
func TestMarketingXNotConfigured(t *testing.T) {
	e := newXEnv(t, true)
	for _, r := range [][2]string{{http.MethodPost, "/v1/marketing/x/connect"}, {http.MethodGet, "/v1/marketing/x/accounts"}} {
		if code, body := call(t, e.env, e.tid, r[0], r[1], e.admin, nil); code != http.StatusServiceUnavailable || body["error"] != "not_configured" {
			t.Fatalf("%s %s: %d %v, want 503 not_configured", r[0], r[1], code, body)
		}
	}
}

func TestMarketingXConnect(t *testing.T) {
	e := newXEnv(t, false)
	if code, _ := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/x/connect", e.dev, nil); code != http.StatusForbidden {
		t.Fatalf("developer connect: %d, want 403", code)
	}
	code, page := e.connect(t, e.admin)
	if code != http.StatusOK || !strings.Contains(page, "X connected") || !strings.Contains(page, "@csitea") {
		t.Fatalf("callback: %d %s", code, page)
	}
	ch := e.channel(t)
	if ch.AutoPublish || ch.AccountRef != "42" || ch.AccountName != "@csitea" || ch.DelegatedBy != e.admin || ch.Status != store.MarketingActive {
		t.Fatalf("channel %+v", ch)
	}
	tok, err := e.st.(store.Marketing).MarketingToken(context.Background(), e.tid, ch.ID)
	if err != nil || strings.Contains(tok.Ciphertext, "not-a-secret") {
		t.Fatalf("token not sealed: %v", err)
	}
	p, err := e.m.Sealer.Open(context.Background(), tok.Ciphertext)
	pair, perr := marketing.ParseXToken(p)
	if err != nil || perr != nil || pair.Access.Reveal() != "acc-1-not-a-secret" || pair.Refresh.Reveal() != "ref-1-not-a-secret" {
		t.Fatalf("sealed pair does not open to X's tokens: %v %v", err, perr)
	}
	ac, accts := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/x/accounts", e.admin, nil)
	raw, _ := json.Marshal(accts)
	if ac != http.StatusOK || !strings.Contains(string(raw), `"username":"csitea"`) || !strings.Contains(string(raw), ch.ID) {
		t.Fatalf("accounts: %d %s", ac, raw)
	}
	// a callback whose verifier does not match the state is refused, nothing stored twice
	e.fake.set(func(f *xFake) { f.verifier = "other" })
	st := e.m.X.NewState(marketing.State{Tenant: e.tid, Member: e.admin, Exp: e.clock.Now().Add(time.Minute).Unix()})
	resp, err := e.client.Get(e.url(e.tid) + hub.XCallbackPath + "?" + url.Values{"code": {fakeXCode}, "state": {st}}.Encode())
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("a wrong verifier: %d, want 502", resp.StatusCode)
	}
	for _, s := range []string{e.buf.String(), page, string(raw)} {
		if strings.Contains(s, "not-a-secret") || strings.Contains(s, fakeXCode) {
			t.Fatal("an X token, the client secret or the code reached a log line or an answer")
		}
	}
	if code := deleteChannel(t, e, ch.ID); code != http.StatusNoContent {
		t.Fatalf("disconnect: %d, want 204", code)
	}
	if _, accts := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/x/accounts", e.admin, nil); len(accts["accounts"].([]any)) != 0 {
		t.Fatalf("after disconnect: %v", accts)
	}
}

func deleteChannel(t *testing.T, e *xEnv, id string) int {
	t.Helper()
	code, _ := call(t, e.env, e.tid, http.MethodDelete, "/v1/marketing/channels/"+id, e.admin, nil)
	return code
}

func TestMarketingXPublish(t *testing.T) {
	e := newXEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	if code, _ := e.publish(t, e.dev, "2026-11-10-hello", ch); code != http.StatusForbidden {
		t.Fatalf("developer publish: %d, want 403", code)
	}
	lc, list := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts?channel="+ch.ID, e.owner, nil)
	if lc != http.StatusOK || len(list["posts"].([]any)) != 2 {
		t.Fatalf("unshared list: %d %v", lc, list)
	}
	code, body := e.publish(t, e.owner, "2026-11-10-hello", ch) // biz_owner, not the connector
	if code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("publish: %d %v, want 200 published 1", code, body)
	}
	sent := e.fake.sent()
	link := marketing.BlogPostURL(e.m.AppURL, "2026-11-10-hello")
	if len(sent) != 1 || !strings.HasPrefix(sent[0], "Hello X\n\n") || !strings.HasSuffix(sent[0], "\n\n"+link) ||
		marketing.XWeightedLength(sent[0]) > marketing.XPostMaxWeight || !strings.Contains(sent[0], "…") {
		t.Fatalf("posted text %q", sent)
	}
	p := e.post(t, ch, "2026-11-10-hello")
	if p.Status != store.MarketingPublished || p.PlatformPostID != "1851" {
		t.Fatalf("post %+v", p)
	}
	if !e.buf.contains(`"permalink":"https://x.com/csitea/status/1851"`) {
		t.Fatalf("log lacks the permalink:\n%s", e.buf.String())
	}
	if code, _ := e.publish(t, e.admin, "2026-11-10-hello", ch); code != http.StatusConflict {
		t.Fatalf("second publish: %d, want 409", code)
	}
	if len(e.fake.sent()) != 1 {
		t.Fatal("a post went to X twice")
	}
	if code, _ := e.publish(t, e.admin, "2026-01-01-gone", ch); code != http.StatusNotFound {
		t.Fatalf("a post not in the live index: %d, want 404", code)
	}
}

// The access token lives two hours: three hours later the publish refreshes
// it, seals the rotated pair back and posts with the new access token.
func TestMarketingXRefresh(t *testing.T) {
	e := newXEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	e.clock.add(3 * time.Hour)
	if code, body := e.publish(t, e.admin, "2026-11-09-two", ch); code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("publish after expiry: %d %v", code, body)
	}
	tok, _ := e.st.(store.Marketing).MarketingToken(context.Background(), e.tid, ch.ID)
	p, _ := e.m.Sealer.Open(context.Background(), tok.Ciphertext)
	pair, err := marketing.ParseXToken(p)
	if err != nil || pair.Access.Reveal() != "acc-2-not-a-secret" || pair.Refresh.Reveal() != "ref-2-not-a-secret" {
		t.Fatalf("the rotated pair was not sealed back: %v", err)
	}
}

// A refused token expires the channel and mails the re-connect link; the
// post waits, unsent.
func TestMarketingXRefused(t *testing.T) {
	e := newXEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	e.fake.set(func(f *xFake) { f.gen = 99 }) // X revoked the pair
	if code, body := e.publish(t, e.admin, "2026-11-09-two", ch); code != http.StatusOK || body["retried"] != float64(1) {
		t.Fatalf("publish on a revoked token: %d %v, want 200 retried 1", code, body)
	}
	if got := e.channel(t); got.Status != store.MarketingExpired {
		t.Fatalf("channel %s, want expired", got.Status)
	}
	if p := e.post(t, ch, "2026-11-09-two"); p.Status != store.MarketingScheduled {
		t.Fatalf("post %s, want scheduled (waiting for the re-connect)", p.Status)
	}
	if len(*e.mails) != 1 || !strings.Contains((*e.mails)[0], "X refused the spool-hub connection") ||
		!strings.Contains((*e.mails)[0], "https://api.example.com/v1/marketing/x/connect?workspace=") {
		t.Fatalf("mails %v", *e.mails)
	}
	if r := e.srv.SweepMarketingX(context.Background()); r.Published != 0 || len(e.fake.sent()) != 0 {
		t.Fatalf("an expired channel was posted to: %+v", r)
	}
}

// A 429 is retried after X's reset; a 500 may have posted, so it fails at
// once, is never resent and is mailed.
func TestMarketingXFailures(t *testing.T) {
	e := newXEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	e.fake.set(func(f *xFake) {
		f.postFail = func(w http.ResponseWriter) bool {
			w.Header().Set("x-rate-limit-reset", strconv.FormatInt(time.Now().Add(-time.Second).Unix(), 10))
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, `{"errors":[{"code":88,"message":"Rate limit exceeded"}]}`)
			return true
		}
	})
	if code, body := e.publish(t, e.admin, "2026-11-09-two", ch); code != http.StatusOK || body["retried"] != float64(1) {
		t.Fatalf("429: %d %v, want retried 1", code, body)
	}
	e.fake.set(func(f *xFake) { f.postFail = nil })
	e.clock.add(marketingRetryWait)
	if r := e.srv.SweepMarketingX(context.Background()); r.Published != 1 {
		t.Fatalf("the sweep's retry: %+v, want published 1", r)
	}
	e.fake.set(func(f *xFake) {
		f.postFail = func(w http.ResponseWriter) bool { w.WriteHeader(http.StatusInternalServerError); return true }
	})
	e.clock.add(25 * time.Hour) // past the daily cap's window
	if code, body := e.publish(t, e.admin, "2026-11-10-hello", ch); code != http.StatusOK || body["failed"] != float64(1) {
		t.Fatalf("500: %d %v, want failed 1", code, body)
	}
	if p := e.post(t, ch, "2026-11-10-hello"); p.Status != store.MarketingFailed {
		t.Fatalf("post after 500: %s, want failed", p.Status)
	}
	n := len(e.fake.sent())
	e.clock.add(time.Hour)
	e.srv.SweepMarketingX(context.Background())
	if len(e.fake.sent()) != n {
		t.Fatal("a post that may have gone out was sent again")
	}
	if len(*e.mails) != 1 || !strings.Contains((*e.mails)[0], "was not published on @csitea") {
		t.Fatalf("mails %v", *e.mails)
	}
}

// marketingRetryWait is past the first retry delay (marketingRetryBase).
const marketingRetryWait = 11 * time.Minute
