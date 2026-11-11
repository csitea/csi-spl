package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
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

// Spec 090 phase 4, T041 / SPL-5258 (linkedin-company-page.md section 8.2):
// connecting a LinkedIn Company Page through the second LinkedIn app and
// publishing a live blog post as the Page on a member's press, against a
// fake LinkedIn and a fake blog (one server). Every token below is an
// obvious fake; each reaches the store only sealed, and never an answer or
// a log line. The proofs: 503 while the app is not configured; only
// tenant.settings connects; a personal-profile state is refused; only
// APPROVED Super admin / Content admin Pages become channels; any admin or
// biz_owner publishes as the Page (author urn:li:organization), a developer
// and a demoted connector cannot, an agent only for a tenant.settings
// member; the access token is refreshed and sealed back; a refused
// connection expires the channel and the post waits; a 429 is retried, a
// 500 is never resent and is mailed; the 7-day reminder goes once.

const (
	fakeOrgSecret = "fake-org-client-secret-not-a-secret"
	fakeOrgCode   = "fake-org-code"
)

type orgFake struct {
	*httptest.Server
	mu       sync.Mutex
	posts    []marketing.BlogPost
	gen      int // the access token generation: org-acc-<gen>-not-a-secret
	refresh  string
	acls     string
	shares   []map[string]any
	images   []string // every image owner
	postFail func(w http.ResponseWriter) bool
}

func (f *orgFake) access() string { return fmt.Sprintf("org-acc-%d-not-a-secret", f.gen) }

func newOrgFake(t *testing.T) *orgFake {
	t.Helper()
	f := &orgFake{refresh: "org-ref-not-a-secret", posts: []marketing.BlogPost{
		{ID: "2026-11-11-hello", Title: "Hello Page", Summary: "A summary."},
		{ID: "2026-11-10-two", Title: "Two", Summary: "Short."},
	}, acls: `{"elements":[
		{"organization":"urn:li:organization:1001","role":"ADMINISTRATOR","state":"APPROVED"},
		{"organization":"urn:li:organization:2002","role":"ANALYST","state":"APPROVED"},
		{"organization":"urn:li:organization:3003","role":"CONTENT_ADMIN","state":"REQUESTED"}]}`}
	f.Server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.Close)
	return f
}

func (f *orgFake) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	_ = r.ParseForm()
	authed := r.Header.Get("Authorization") == "Bearer "+f.access()
	switch {
	case r.URL.Path == "/blog-md/index.json":
		_ = json.NewEncoder(w).Encode(map[string]any{"locales": map[string]any{"en": f.posts}})
	case r.URL.Path == "/oauth/v2/accessToken":
		f.token(w, r)
	case !authed && strings.HasPrefix(r.URL.Path, "/rest/"):
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"message":"Invalid access token","status":401}`)
	case r.URL.Path == "/rest/organizationAcls":
		_, _ = io.WriteString(w, f.acls)
	case strings.HasPrefix(r.URL.Path, "/rest/organizations/"):
		_, _ = io.WriteString(w, `{"localizedName":"Example Company","vanityName":"example-co"}`)
	case r.URL.Path == "/rest/images":
		var b map[string]map[string]string
		_ = json.NewDecoder(r.Body).Decode(&b)
		f.images = append(f.images, b["initializeUploadRequest"]["owner"])
		_, _ = io.WriteString(w, `{"value":{"uploadUrl":"`+f.URL+`/upload","image":"urn:li:image:1"}}`)
	case r.URL.Path == "/upload":
	case r.URL.Path == "/rest/posts":
		var b map[string]any
		_ = json.NewDecoder(r.Body).Decode(&b)
		f.shares = append(f.shares, b)
		if f.postFail != nil && f.postFail(w) {
			return
		}
		w.Header().Set("X-Restli-Id", fmt.Sprintf("urn:li:share:%d", len(f.shares)))
		w.WriteHeader(http.StatusCreated)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (f *orgFake) token(w http.ResponseWriter, r *http.Request) {
	bundle := func(withRefresh bool) {
		out := map[string]any{"access_token": f.access(), "expires_in": 5184000}
		if withRefresh {
			out["refresh_token"], out["refresh_token_expires_in"] = f.refresh, 31536000
		}
		_ = json.NewEncoder(w).Encode(out)
	}
	switch {
	case r.PostForm.Get("client_id") != "org-client" || r.PostForm.Get("client_secret") != fakeOrgSecret:
		w.WriteHeader(http.StatusUnauthorized)
	case r.PostForm.Get("grant_type") == "authorization_code" && r.PostForm.Get("code") == fakeOrgCode:
		f.gen++
		bundle(true)
	case r.PostForm.Get("grant_type") == "refresh_token" && r.PostForm.Get("refresh_token") == f.refresh:
		f.gen++
		bundle(false) // LinkedIn keeps the refresh token
	default:
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"error":"invalid_grant","error_description":"The provided refresh token is invalid"}`)
	}
}

func (f *orgFake) set(fn func(f *orgFake)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

func (f *orgFake) sent() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.shares...)
}

type orgEnv struct {
	*env
	fake  *orgFake
	m     *hub.MarketingLinkedInOrg
	clock *shareClock
	tid   string
	admin string
	owner string
	dev   string
	mails *[]string
	buf   *syncBuf
}

// newOrgEnv: an allow-listed, switched-on workspace with an admin, a
// biz_owner and a developer, wired to a fake LinkedIn; off leaves the
// Company Page app unconfigured.
func newOrgEnv(t *testing.T, off bool) *orgEnv {
	t.Helper()
	fake := newOrgFake(t)
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k")
	if err != nil {
		t.Fatal(err)
	}
	mails := &[]string{}
	var mailMu sync.Mutex
	m := &hub.MarketingLinkedInOrg{
		Org: &marketing.LinkedInOrg{ClientID: "org-client", ClientSecret: marketing.NewPlaintext(fakeOrgSecret), Version: "202610",
			RedirectURI: "https://app.example.com" + hub.LinkedInOrgCallbackPath, AuthBase: fake.URL, APIBase: fake.URL, HTTP: fake.Client()},
		Sealer: sealer, AppURL: fake.URL, APIURL: "https://api.example.com",
		Mail: func(_ context.Context, to, subject, body string) error {
			mailMu.Lock()
			defer mailMu.Unlock()
			*mails = append(*mails, to+"|"+subject+"|"+body)
			return nil
		},
	}
	clock := &shareClock{now: time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)}
	buf := &syncBuf{}
	tid := mktIDs(1)[0]
	e := mktEnvWith(t, []string{tid}, func(o *hub.Options) {
		if !off {
			o.MarketingLinkedInOrg = m
		}
		o.Log = zerolog.New(buf)
		o.Now = clock.Now
	}, tid)
	admin := seat(t, e, tid, rbac.Admin)
	mktOn(t, e, tid, admin)
	return &orgEnv{env: e, fake: fake, m: m, clock: clock, tid: tid, admin: admin, owner: seat(t, e, tid, rbac.BizOwner),
		dev: seat(t, e, tid, rbac.Developer), mails: mails, buf: buf}
}

// callback runs LinkedIn's redirect to the callback (a browser with no
// session) on the WUI path with state st.
func (e *orgEnv) callback(t *testing.T, st string) (int, string) {
	t.Helper()
	resp, err := e.client.Get(e.url(e.tid) + hub.LinkedInOrgCallbackPath + "?" + url.Values{"code": {fakeOrgCode}, "state": {st}}.Encode())
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

// connect runs the connect as `as`: the authorize URL, then the callback.
func (e *orgEnv) connect(t *testing.T, as string) (int, string) {
	t.Helper()
	code, body := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/linkedin-org/connect", as, nil)
	if code != http.StatusOK {
		t.Fatalf("connect: %d %v", code, body)
	}
	au, _ := body["authorize_url"].(string)
	u, err := url.Parse(au)
	if err != nil || !strings.HasPrefix(au, e.fake.URL+"/oauth/v2/authorization?") {
		t.Fatalf("authorize_url %q", au)
	}
	q := u.Query()
	if q.Get("scope") != marketing.LinkedInOrgScopes || q.Get("client_id") != "org-client" || q.Get("redirect_uri") != e.m.Org.RedirectURI {
		t.Fatalf("authorize_url query %v", q)
	}
	return e.callback(t, q.Get("state"))
}

func (e *orgEnv) channels(t *testing.T) []store.MarketingChannel {
	t.Helper()
	chs, _ := e.st.(store.Marketing).MarketingChannels(context.Background(), e.tid)
	var out []store.MarketingChannel
	for _, c := range chs {
		if c.Platform == store.MarketingPlatformLinkedInPage {
			out = append(out, c)
		}
	}
	return out
}

func (e *orgEnv) channel(t *testing.T) store.MarketingChannel {
	t.Helper()
	chs := e.channels(t)
	if len(chs) != 1 {
		t.Fatalf("%d LinkedIn Page channels, want 1", len(chs))
	}
	return chs[0]
}

func (e *orgEnv) publish(t *testing.T, as, post string, ch store.MarketingChannel) (int, map[string]any) {
	t.Helper()
	return call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/"+post+"/publish?channel="+ch.ID, as, nil)
}

func (e *orgEnv) post(t *testing.T, ch store.MarketingChannel, ref string) store.MarketingPost {
	t.Helper()
	p, err := e.st.(store.MarketingMetaDispatch).MarketingPostByRef(context.Background(), e.tid, ch.ID, store.MarketingSourceBlog, ref)
	if err != nil {
		t.Fatalf("post %s: %v", ref, err)
	}
	return p
}

// The red control of the dark launch: with no Company Page app every
// /v1/marketing/linkedin-org route answers 503 not_configured, the dispatch
// sweep does nothing and its runner returns.
func TestMarketingLinkedInOrgNotConfigured(t *testing.T) {
	e := newOrgEnv(t, true)
	for _, r := range [][2]string{{http.MethodPost, "/v1/marketing/linkedin-org/connect"}, {http.MethodGet, "/v1/marketing/linkedin-org/pages"},
		{http.MethodGet, "/v1/marketing/linkedin-org/connect"}} {
		if code, body := call(t, e.env, e.tid, r[0], r[1], e.admin, nil); code != http.StatusServiceUnavailable || body["error"] != "not_configured" {
			t.Fatalf("%s %s: %d %v, want 503 not_configured", r[0], r[1], code, body)
		}
	}
	if r := e.srv.SweepMarketingLinkedInOrg(context.Background()); r != (hub.MarketingShareResult{}) {
		t.Fatalf("sweep without the app: %+v", r)
	}
	done := make(chan struct{})
	go func() { e.srv.RunMarketingLinkedInOrgDispatch(context.Background()); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("RunMarketingLinkedInOrgDispatch kept running without the app")
	}
}

func TestMarketingLinkedInOrgConnect(t *testing.T) {
	e := newOrgEnv(t, false)
	if code, _ := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/linkedin-org/connect", e.dev, nil); code != http.StatusForbidden {
		t.Fatalf("developer connect: %d, want 403", code)
	}
	// a state of the personal-profile app is refused, nothing stored
	li := &marketing.LinkedIn{ClientSecret: marketing.NewPlaintext(fakeOrgSecret)}
	if code, _ := e.callback(t, li.NewState(marketing.State{Tenant: e.tid, Member: e.admin, Exp: e.clock.Now().Add(time.Minute).Unix()})); code != http.StatusBadRequest {
		t.Fatalf("a personal-profile state: %d, want 400 bad_state", code)
	}
	code, page := e.connect(t, e.admin)
	if code != http.StatusOK || !strings.Contains(page, "LinkedIn company page connected") || !strings.Contains(page, "Example Company") {
		t.Fatalf("callback: %d %s", code, page)
	}
	ch := e.channel(t) // only 1001: 2002 is ANALYST, 3003 only REQUESTED
	if ch.AutoPublish || ch.AccountRef != "1001" || ch.AccountType != "page" || ch.AccountName != "Example Company" ||
		ch.DelegatedBy != e.admin || ch.Status != store.MarketingActive || ch.Metadata["organization_urn"] != "urn:li:organization:1001" ||
		ch.Metadata["role"] != "ADMINISTRATOR" || ch.ExpiresAt == nil || !ch.ExpiresAt.Equal(e.clock.Now().Add(365*24*time.Hour)) {
		t.Fatalf("channel %+v", ch)
	}
	tok, err := e.st.(store.Marketing).MarketingToken(context.Background(), e.tid, ch.ID)
	if err != nil || strings.Contains(tok.Ciphertext, "not-a-secret") {
		t.Fatalf("token not sealed: %v", err)
	}
	p, err := e.m.Sealer.Open(context.Background(), tok.Ciphertext)
	bundle, perr := marketing.ParseOrgToken(p)
	if err != nil || perr != nil || bundle.Access.Reveal() != "org-acc-1-not-a-secret" || bundle.Refresh.Reveal() != "org-ref-not-a-secret" {
		t.Fatalf("sealed bundle does not open to LinkedIn's tokens: %v %v", err, perr)
	}
	pc, pages := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/linkedin-org/pages", e.dev, nil)
	raw, _ := json.Marshal(pages)
	if pc != http.StatusOK || !strings.Contains(string(raw), `"vanity_name":"example-co"`) || !strings.Contains(string(raw), ch.ID) {
		t.Fatalf("pages: %d %s", pc, raw)
	}
	for _, s := range []string{e.buf.String(), page, string(raw)} {
		if strings.Contains(s, "not-a-secret") || strings.Contains(s, fakeOrgCode) {
			t.Fatal("a LinkedIn token, the client secret or the code reached a log line or an answer")
		}
	}
	if code, _ := call(t, e.env, e.tid, http.MethodDelete, "/v1/marketing/channels/"+ch.ID, e.admin, nil); code != http.StatusNoContent {
		t.Fatalf("disconnect: %d, want 204", code)
	}
	if _, pages := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/linkedin-org/pages", e.admin, nil); len(pages["pages"].([]any)) != 0 {
		t.Fatalf("after disconnect: %v", pages)
	}
	// a member with no eligible Page role: nothing stored
	e.fake.set(func(f *orgFake) {
		f.acls = `{"elements":[{"organization":"urn:li:organization:2002","role":"ANALYST","state":"APPROVED"}]}`
	})
	if code, page := e.connect(t, e.admin); code != http.StatusOK || !strings.Contains(page, "no company page") || len(e.channels(t)) != 0 {
		t.Fatalf("no eligible Page: %d %s, %d channels", code, page, len(e.channels(t)))
	}
}

// SPL-5196 parity: any admin or biz_owner publishes as the Page, even one
// who did not connect it; every other role, and a connector who lost both
// roles, is 403 naming tenant.settings.
func TestMarketingLinkedInOrgPublishRoles(t *testing.T) {
	e := newOrgEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	for _, who := range []string{e.dev, seat(t, e.env, e.tid, rbac.RegularUser)} {
		if code, body := e.publish(t, who, "2026-11-11-hello", ch); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
			t.Fatalf("publish by a non-admin: %d %v, want 403 naming tenant.settings", code, body)
		}
		if code, _ := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts?channel="+ch.ID, who, nil); code != http.StatusForbidden {
			t.Fatalf("list by a non-admin: %d, want 403", code)
		}
	}
	lc, list := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts?channel="+ch.ID, e.owner, nil)
	if lc != http.StatusOK || len(list["posts"].([]any)) != 2 {
		t.Fatalf("unshared list: %d %v", lc, list)
	}
	code, body := e.publish(t, e.owner, "2026-11-11-hello", ch) // biz_owner, not the connector
	if code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("publish: %d %v, want 200 published 1", code, body)
	}
	sent := e.fake.sent()
	link := marketing.BlogPostURL(e.m.AppURL, "2026-11-11-hello")
	art, _ := sent[0]["content"].(map[string]any)["article"].(map[string]any)
	if len(sent) != 1 || sent[0]["author"] != "urn:li:organization:1001" || art["source"] != link || art["title"] != "Hello Page" {
		t.Fatalf("posted %v, want one post as the Page", sent)
	}
	p := e.post(t, ch, "2026-11-11-hello")
	if p.Status != store.MarketingPublished || p.PlatformPostID != "urn:li:share:1" {
		t.Fatalf("post %+v", p)
	}
	if !e.buf.contains(`"permalink":"https://www.linkedin.com/feed/update/urn:li:share:1"`) {
		t.Fatalf("log lacks the permalink:\n%s", e.buf.String())
	}
	if code, _ := e.publish(t, e.admin, "2026-11-11-hello", ch); code != http.StatusConflict {
		t.Fatalf("second publish: %d, want 409", code)
	}
	if code, _ := e.publish(t, e.admin, "2026-01-01-gone", ch); code != http.StatusNotFound {
		t.Fatalf("a post not in the live index: %d, want 404", code)
	}
	// the connector (admin) is demoted: no connector-alone bypass (SPL-5196 R7 W1)
	setRoles(t, e.env, e.tid, e.admin, rbac.Developer)
	e.clock.add(25 * time.Hour)
	if code, body := e.publish(t, e.admin, "2026-11-10-two", ch); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
		t.Fatalf("demoted connector publish: %d %v, want 403 naming tenant.settings", code, body)
	}
	if len(e.fake.sent()) != 1 {
		t.Fatal("a refused publish reached LinkedIn")
	}
}

// The agent door (a box upload token, X-Spool-Requester) publishes as the
// Page only for a member holding tenant.settings.
func TestMarketingLinkedInOrgAgentPublish(t *testing.T) {
	e := newOrgEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	b := e.box(e.tid, "box-li", "c-002")
	e.pin(e.tid, b)
	e.clock.mu.Lock()
	saved := e.clock.now
	e.clock.now = time.Now()
	e.clock.mu.Unlock()
	tok := e.uploadToken(e.tid, b)
	e.clock.mu.Lock()
	e.clock.now = saved
	e.clock.mu.Unlock()
	agent := func(requester string) (int, map[string]any) {
		req, _ := http.NewRequest(http.MethodPost, e.url(e.tid)+"/v1/marketing/posts/2026-11-11-hello/publish?channel="+ch.ID, nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		if requester != "" {
			req.Header.Set(hub.RequesterHeader, requester)
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		out := map[string]any{}
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return resp.StatusCode, out
	}
	for _, who := range []string{"", e.dev, "HUM-999999999"} {
		if code, body := agent(who); code != http.StatusForbidden {
			t.Fatalf("agent for %q: %d %v, want 403", who, code, body)
		}
	}
	if code, body := agent(e.owner); code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("agent for the biz_owner: %d %v, want 200 published 1", code, body)
	}
	if len(e.fake.sent()) != 1 || !e.buf.contains(`"agent":"box-li"`) {
		t.Fatalf("%d posts, log %s; want 1, attributed to box-li", len(e.fake.sent()), e.buf.String())
	}
}

// 60 days on, the access token is refreshed before the post and the new
// bundle sealed back; the refresh token keeps its first end.
func TestMarketingLinkedInOrgRefresh(t *testing.T) {
	e := newOrgEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	e.clock.add(60*24*time.Hour - time.Minute)
	if code, body := e.publish(t, e.admin, "2026-11-10-two", ch); code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("publish near the access token's end: %d %v", code, body)
	}
	tok, _ := e.st.(store.Marketing).MarketingToken(context.Background(), e.tid, ch.ID)
	p, _ := e.m.Sealer.Open(context.Background(), tok.Ciphertext)
	bundle, err := marketing.ParseOrgToken(p)
	if err != nil || bundle.Access.Reveal() != "org-acc-2-not-a-secret" || bundle.Refresh.Reveal() != "org-ref-not-a-secret" {
		t.Fatalf("the refreshed bundle was not sealed back: %v", err)
	}
	if !bundle.RefreshExpiresAt.Equal(time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC).Add(365 * 24 * time.Hour)) {
		t.Fatalf("the refresh token's end moved: %v", bundle.RefreshExpiresAt)
	}
}

// A refused connection (the member lost the Page role: 403) expires the
// channel and mails the re-connect link; the post waits, unsent.
func TestMarketingLinkedInOrgRefused(t *testing.T) {
	e := newOrgEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	e.fake.set(func(f *orgFake) {
		f.postFail = func(w http.ResponseWriter) bool {
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, `{"message":"Not enough permissions to access: partnerApiPostsExternal.CREATE","status":403}`)
			return true
		}
	})
	if code, body := e.publish(t, e.admin, "2026-11-10-two", ch); code != http.StatusOK || body["retried"] != float64(1) {
		t.Fatalf("publish on a refused connection: %d %v, want 200 retried 1", code, body)
	}
	if got := e.channel(t); got.Status != store.MarketingExpired {
		t.Fatalf("channel %s, want expired", got.Status)
	}
	if p := e.post(t, ch, "2026-11-10-two"); p.Status != store.MarketingScheduled {
		t.Fatalf("post %s, want scheduled (waiting for the re-connect)", p.Status)
	}
	if len(*e.mails) != 1 || !strings.Contains((*e.mails)[0], "LinkedIn refused the spool-hub company page connection") ||
		!strings.Contains((*e.mails)[0], "https://api.example.com/v1/marketing/linkedin-org/connect?workspace=") {
		t.Fatalf("mails %v", *e.mails)
	}
	n := len(e.fake.sent())
	if r := e.srv.SweepMarketingLinkedInOrg(context.Background()); r.Published != 0 || len(e.fake.sent()) != n {
		t.Fatalf("an expired channel was posted to: %+v", r)
	}
}

// A 429 is retried by the sweep; a 500 may have posted, so it fails at
// once, is never resent and is mailed.
func TestMarketingLinkedInOrgFailures(t *testing.T) {
	e := newOrgEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	e.fake.set(func(f *orgFake) {
		f.postFail = func(w http.ResponseWriter) bool { w.WriteHeader(http.StatusTooManyRequests); return true }
	})
	if code, body := e.publish(t, e.admin, "2026-11-10-two", ch); code != http.StatusOK || body["retried"] != float64(1) {
		t.Fatalf("429: %d %v, want retried 1", code, body)
	}
	e.fake.set(func(f *orgFake) { f.postFail = nil })
	e.clock.add(marketingRetryWait)
	if r := e.srv.SweepMarketingLinkedInOrg(context.Background()); r.Published != 1 {
		t.Fatalf("the sweep's retry: %+v, want published 1", r)
	}
	e.fake.set(func(f *orgFake) {
		f.postFail = func(w http.ResponseWriter) bool { w.WriteHeader(http.StatusInternalServerError); return true }
	})
	e.clock.add(25 * time.Hour) // past the daily cap's window
	if code, body := e.publish(t, e.admin, "2026-11-11-hello", ch); code != http.StatusOK || body["failed"] != float64(1) {
		t.Fatalf("500: %d %v, want failed 1", code, body)
	}
	if p := e.post(t, ch, "2026-11-11-hello"); p.Status != store.MarketingFailed {
		t.Fatalf("post after 500: %s, want failed", p.Status)
	}
	n := len(e.fake.sent())
	e.clock.add(time.Hour)
	e.srv.SweepMarketingLinkedInOrg(context.Background())
	if len(e.fake.sent()) != n {
		t.Fatal("a post that may have gone out was sent again")
	}
	if len(*e.mails) != 1 || !strings.Contains((*e.mails)[0], "was not published on the LinkedIn company page Example Company") {
		t.Fatalf("mails %v", *e.mails)
	}
}

// A 400 on the post (LinkedIn rejects its content) fails that post once and
// mails it; the connection stays: only a refused refresh counts 400 as
// refused (spec linkedin-company-page.md section 5.4, SPL-5258 R7).
func TestMarketingLinkedInOrgPostBadRequest(t *testing.T) {
	e := newOrgEnv(t, false)
	e.connect(t, e.admin)
	ch := e.channel(t)
	e.fake.set(func(f *orgFake) {
		f.postFail = func(w http.ResponseWriter) bool {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"message":"commentary too long","status":400}`)
			return true
		}
	})
	if code, body := e.publish(t, e.admin, "2026-11-10-two", ch); code != http.StatusOK || body["failed"] != float64(1) {
		t.Fatalf("post 400: %d %v, want 200 failed 1", code, body)
	}
	if got := e.channel(t); got.Status != store.MarketingActive {
		t.Fatalf("channel %s after a post 400, want active", got.Status)
	}
	if p := e.post(t, ch, "2026-11-10-two"); p.Status != store.MarketingFailed {
		t.Fatalf("post %s, want failed", p.Status)
	}
	if len(*e.mails) != 1 || strings.Contains((*e.mails)[0], "refused") ||
		!strings.Contains((*e.mails)[0], "was not published on the LinkedIn company page Example Company") {
		t.Fatalf("mails %v", *e.mails)
	}
	n := len(e.fake.sent())
	e.clock.add(time.Hour)
	e.srv.SweepMarketingLinkedInOrg(context.Background())
	if len(e.fake.sent()) != n {
		t.Fatal("a post LinkedIn rejected was sent again")
	}
}

// 7 days before the connection ends the connector gets one reminder; at the
// end the channel is expired and its posts wait.
func TestMarketingLinkedInOrgExpiry(t *testing.T) {
	e := newOrgEnv(t, false)
	e.connect(t, e.admin)
	e.clock.add(365*24*time.Hour - 6*24*time.Hour)
	if r := e.srv.SweepMarketingLinkedInOrg(context.Background()); r.Reminded != 1 {
		t.Fatalf("sweep inside the last week: %+v, want reminded 1", r)
	}
	if r := e.srv.SweepMarketingLinkedInOrg(context.Background()); r.Reminded != 0 {
		t.Fatalf("second sweep: %+v, want no second reminder", r)
	}
	e.clock.add(7 * 24 * time.Hour)
	if r := e.srv.SweepMarketingLinkedInOrg(context.Background()); r.Expired != 1 {
		t.Fatalf("sweep past the end: %+v, want expired 1", r)
	}
	if got := e.channel(t); got.Status != store.MarketingExpired {
		t.Fatalf("channel %s, want expired", got.Status)
	}
	if len(*e.mails) != 2 || !strings.Contains((*e.mails)[0], "Renew the LinkedIn company page connection") ||
		!strings.Contains((*e.mails)[1], "connection has ended") {
		t.Fatalf("mails %v", *e.mails)
	}
}
