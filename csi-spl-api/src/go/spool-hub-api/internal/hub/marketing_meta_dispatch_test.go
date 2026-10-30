package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
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

// Spec 090 T034 / SPL-4424: a blog post is published on a connected
// Facebook Page or Instagram account only after the owner's approval, once,
// within the caps, against a fake Meta Graph API and a fake blog (one TLS
// server, so the picture URL is https as Instagram needs). The proofs: a
// held post is never claimed; the publish approves it and exactly one Page
// post is made, also under racing publishes and sweeps; the second publish
// is 409; the daily cap and Instagram's 100 in 24 h defer a post; a refused
// token expires the channel and the post waits; a 500 is never resent.

const fakeMetaPageToken = "fake-meta-page-token-not-a-secret"

// metaPubFake is the live blog plus the Graph API's publish calls.
type metaPubFake struct {
	*httptest.Server
	mu         sync.Mutex
	posts      []marketing.BlogPost
	feeds      []map[string][]string // every POST /<page>/feed form
	containers int                   // POST /<ig>/media
	publishes  int                   // POST /<ig>/media_publish
	inProgress int                   // container status reads answered IN_PROGRESS first
	feedFail   func(w http.ResponseWriter) bool
	tokens     []string
}

func newMetaPubFake(t *testing.T) *metaPubFake {
	t.Helper()
	f := &metaPubFake{}
	f.Server = httptest.NewTLSServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.Close)
	return f
}

func (f *metaPubFake) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if strings.HasPrefix(r.URL.Path, "/v26.0/") {
		f.tokens = append(f.tokens, r.Header.Get("Authorization"))
	}
	_ = r.ParseForm()
	p := r.URL.Path
	switch {
	case p == "/blog-md/index.json":
		_ = json.NewEncoder(w).Encode(map[string]any{"locales": map[string]any{"en": f.posts}})
	case r.Method == http.MethodPost && strings.HasSuffix(p, "/feed"):
		f.feeds = append(f.feeds, r.PostForm)
		if f.feedFail != nil && f.feedFail(w) {
			return
		}
		_, _ = io.WriteString(w, `{"id":"1001_`+strconv.Itoa(len(f.feeds))+`"}`)
	case r.Method == http.MethodPost && strings.HasSuffix(p, "/media"):
		f.containers++
		_, _ = io.WriteString(w, `{"id":"c`+strconv.Itoa(f.containers)+`"}`)
	case r.Method == http.MethodPost && strings.HasSuffix(p, "/media_publish"):
		f.publishes++
		_, _ = io.WriteString(w, `{"id":"m`+strconv.Itoa(f.publishes)+`"}`)
	case r.Method == http.MethodGet && r.URL.Query().Get("fields") == "status_code,status":
		code := marketing.ContainerFinished
		if f.inProgress > 0 {
			f.inProgress--
			code = marketing.ContainerInProgress
		}
		_, _ = io.WriteString(w, `{"status_code":"`+code+`","status":"fake"}`)
	case r.Method == http.MethodGet && r.URL.Query().Get("fields") != "":
		field := r.URL.Query().Get("fields")
		_, _ = io.WriteString(w, `{"`+field+`":"https://social.example.com`+p+`"}`)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (f *metaPubFake) set(fn func(f *metaPubFake)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

func (f *metaPubFake) counts() (feeds, containers, publishes int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.feeds), f.containers, f.publishes
}

// metaFail makes the fake answer every Page post with status and Meta code.
func metaFail(status, code int, header map[string]string) func(w http.ResponseWriter) bool {
	return func(w http.ResponseWriter) bool {
		for k, v := range header {
			w.Header().Set(k, v)
		}
		metaFakeError(w, status, code)
		return true
	}
}

type metaPubEnv struct {
	*env
	fake  *metaPubFake
	m     *hub.MarketingMeta
	srv   *hub.Server
	clock *shareClock
	tid   string
	admin string
	owner string
	page  store.MarketingChannel
	ig    store.MarketingChannel
	mails *[]string
	buf   *syncBuf
}

// newMetaPubEnv: an allow-listed, switched-on workspace with an owner, an
// admin, a live blog of a JPEG post and a WEBP post, and one Page with its
// Instagram account connected (auto_publish off, as T033 connects them).
func newMetaPubEnv(t *testing.T) *metaPubEnv {
	t.Helper()
	fake := newMetaPubFake(t)
	fake.posts = []marketing.BlogPost{
		{ID: "2026-10-30-hello", Title: "Hello World", Summary: "The first post.", Image: "2026-10-30-hello.jpg"},
		{ID: "2026-10-29-webp", Title: "A WEBP post", Summary: "Its picture is WEBP.", Image: "2026-10-29-webp.webp"},
		{ID: "2026-10-28-third", Title: "Third", Summary: "Another one.", Image: "2026-10-28-third.jpg"},
	}
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k")
	if err != nil {
		t.Fatal(err)
	}
	mails := &[]string{}
	var mailMu sync.Mutex
	m := &hub.MarketingMeta{
		Meta: &marketing.Meta{AppID: "app-id", AppSecret: marketing.NewPlaintext(fakeMetaSecret), Version: "v26.0",
			GraphBase: fake.URL, HTTP: fake.Client(), Attempts: 1},
		Sealer: sealer, AppURL: fake.URL, APIURL: "https://api.example.com", ContainerWait: time.Millisecond,
		Mail: func(_ context.Context, to, subject, body string) error {
			mailMu.Lock()
			defer mailMu.Unlock()
			*mails = append(*mails, to+"|"+subject+"|"+body)
			return nil
		},
	}
	clock := &shareClock{now: time.Date(2026, 10, 30, 9, 0, 0, 0, time.UTC)}
	buf := &syncBuf{}
	tid := mktIDs(1)[0]
	e := mktEnvWith(t, []string{tid}, func(o *hub.Options) {
		o.MarketingMeta = m
		o.Log = zerolog.New(buf)
		o.Now = clock.Now
	}, tid)
	admin := seat(t, e, tid, rbac.Admin)
	mktOn(t, e, tid, admin)
	owner := seat(t, e, tid, rbac.BizOwner)
	sealed, keyID, err := sealer.Seal(context.Background(), marketing.NewPlaintext(fakeMetaPageToken))
	if err != nil {
		t.Fatal(err)
	}
	tok := store.MarketingToken{Ciphertext: sealed, KMSKeyID: keyID}
	mk := e.st.(store.Marketing)
	page, err := mk.ConnectMarketingChannel(context.Background(), store.MarketingChannel{Tenant: tid, Platform: "facebook_page",
		AccountType: "page", AccountRef: "1001", AccountName: "Page A", DelegatedBy: admin}, tok, clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	ig, err := mk.ConnectMarketingChannel(context.Background(), store.MarketingChannel{Tenant: tid, Platform: "instagram_business",
		AccountType: "business", AccountRef: "17841", AccountName: "page_a_ig", DelegatedBy: admin}, tok, clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	return &metaPubEnv{env: e, fake: fake, m: m, srv: e.srv, clock: clock, tid: tid, admin: admin, owner: owner,
		page: page, ig: ig, mails: mails, buf: buf}
}

func (e *metaPubEnv) publish(t *testing.T, as, post string, ch store.MarketingChannel) (int, map[string]any) {
	t.Helper()
	return call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/"+post+"/publish?channel="+ch.ID, as, nil)
}

func (e *metaPubEnv) post(t *testing.T, ch store.MarketingChannel, ref string) store.MarketingPost {
	t.Helper()
	p, err := e.st.(store.MarketingMetaDispatch).MarketingPostByRef(context.Background(), e.tid, ch.ID, store.MarketingSourceBlog, ref)
	if err != nil {
		t.Fatalf("post %s on %s: %v", ref, ch.Platform, err)
	}
	return p
}

func (e *metaPubEnv) sweep() hub.MarketingShareResult {
	return e.srv.SweepMarketingMeta(context.Background())
}

// The red control of tasks.md T034: a held post on an auto_publish=false
// channel is never claimed; the publish moves it to scheduled and it is
// claimed exactly once; the second publish is 409.
func TestMarketingMetaApprovalHold(t *testing.T) {
	e := newMetaPubEnv(t)
	mk := e.st.(store.Marketing)
	if _, err := mk.ScheduleMarketingPost(context.Background(), store.MarketingPost{Tenant: e.tid, ChannelID: e.page.ID,
		SourceType: store.MarketingSourceBlog, SourceRef: "2026-10-30-hello", ContentText: "Hello World",
		Status: store.MarketingAwaitingApproval}, e.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if r1, r2 := e.sweep(), e.sweep(); r1 != (hub.MarketingShareResult{}) || r2 != (hub.MarketingShareResult{}) {
		t.Fatalf("the sweep acted on a held post: %+v then %+v", r1, r2)
	}
	if due, err := mk.ClaimMarketingPosts(context.Background(), e.tid, e.page.ID, e.clock.Now().Add(time.Hour)); err != nil || len(due) != 0 {
		t.Fatalf("a held post was claimed: %+v, %v", due, err)
	}
	if feeds, _, _ := e.fake.counts(); feeds != 0 {
		t.Fatalf("a held post reached Meta: %d Page posts", feeds)
	}
	code, body := e.publish(t, e.owner, "2026-10-30-hello", e.page)
	if code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("owner publish: %d %v, want 200 published 1", code, body)
	}
	p := e.post(t, e.page, "2026-10-30-hello")
	if p.Status != store.MarketingPublished || p.PlatformPostID != "1001_1" || p.Attempts != 1 {
		t.Fatalf("post after publish: %+v", p)
	}
	e.fake.mu.Lock()
	form, tok := e.fake.feeds[0], e.fake.tokens[0]
	e.fake.mu.Unlock()
	if form["link"][0] != marketing.BlogPostURL(e.m.AppURL, "2026-10-30-hello") || form["message"][0] != "Hello World" ||
		tok != "Bearer "+fakeMetaPageToken {
		t.Fatalf("Page post form %v, token %q", form, tok)
	}
	if !e.buf.contains(`"permalink":"https://social.example.com/v26.0/1001_1"`) || e.buf.contains(fakeMetaPageToken) {
		t.Fatalf("log: want the permalink, never the token:\n%s", e.buf.String())
	}
	if code, _ := e.publish(t, e.owner, "2026-10-30-hello", e.page); code != http.StatusConflict {
		t.Fatalf("second publish: %d, want 409", code)
	}
	if r := e.sweep(); r.Published != 0 {
		t.Fatalf("a sweep re-published: %+v", r)
	}
	if feeds, _, _ := e.fake.counts(); feeds != 1 {
		t.Fatalf("%d Page posts, want exactly 1", feeds)
	}
}

// Racing publishes and sweeps on two hub handles of one store: one Page
// post, one 200, the rest 409.
func TestMarketingMetaPublishOnceUnderRace(t *testing.T) {
	e := newMetaPubEnv(t)
	var wg sync.WaitGroup
	var mu sync.Mutex
	codes := map[int]int{}
	for i := 0; i < 6; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			_, err := e.srv.PublishMetaPost(context.Background(), e.tid, e.owner, "2026-10-30-hello", e.page.ID)
			code := http.StatusOK
			if errors.Is(err, hub.ErrMarketingRecorded) {
				code = http.StatusConflict
			} else if err != nil {
				code = http.StatusInternalServerError
			}
			mu.Lock()
			codes[code]++
			mu.Unlock()
		}()
		go func() { defer wg.Done(); e.sweep() }()
	}
	wg.Wait()
	if feeds, _, _ := e.fake.counts(); feeds != 1 || codes[http.StatusOK] != 1 || codes[http.StatusConflict] != 5 {
		t.Fatalf("%d Page posts, answers %v; want 1 post, one 200 and five 409", feeds, codes)
	}
}

// Instagram: container, status until FINISHED, media_publish, once; a post
// whose picture is not JPEG is refused before anything is recorded.
func TestMarketingMetaInstagram(t *testing.T) {
	e := newMetaPubEnv(t)
	e.fake.set(func(f *metaPubFake) { f.inProgress = 2 })
	code, body := e.publish(t, e.owner, "2026-10-30-hello", e.ig)
	if code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("instagram publish: %d %v", code, body)
	}
	if _, c, p := e.fake.counts(); c != 1 || p != 1 {
		t.Fatalf("%d containers, %d media_publish; want 1 and 1", c, p)
	}
	p := e.post(t, e.ig, "2026-10-30-hello")
	want := "Hello World\n\nThe first post.\n\n" + marketing.BlogPostURL(e.m.AppURL, "2026-10-30-hello")
	if p.Status != store.MarketingPublished || p.PlatformPostID != "m1" || p.ContentText != want ||
		len(p.MediaAssets) != 1 || !strings.HasSuffix(p.MediaAssets[0].URL, "/blog/img/2026-10-30-hello.jpg") {
		t.Fatalf("instagram post %+v", p)
	}
	code, body = e.publish(t, e.owner, "2026-10-29-webp", e.ig)
	if code != http.StatusUnprocessableEntity || body["error"] != "instagram_needs_jpeg" {
		t.Fatalf("WEBP picture on Instagram: %d %v, want 422 instagram_needs_jpeg", code, body)
	}
	if _, err := e.st.(store.MarketingMetaDispatch).MarketingPostByRef(context.Background(), e.tid, e.ig.ID, store.MarketingSourceBlog, "2026-10-29-webp"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("a refused Instagram post was recorded: %v", err)
	}
}

// FR-007: one API post per channel in 24 h; the next one waits, unsent,
// and goes out when the window frees.
func TestMarketingMetaDailyCap(t *testing.T) {
	e := newMetaPubEnv(t)
	if code, body := e.publish(t, e.owner, "2026-10-30-hello", e.page); code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("first publish: %d %v", code, body)
	}
	code, body := e.publish(t, e.owner, "2026-10-28-third", e.page)
	if code != http.StatusOK || body["published"] != float64(0) || body["deferred"] != float64(1) {
		t.Fatalf("second publish the same day: %d %v, want deferred 1", code, body)
	}
	e.clock.add(23 * time.Hour)
	if r := e.sweep(); r.Published != 0 {
		t.Fatalf("published inside the window: %+v", r)
	}
	if feeds, _, _ := e.fake.counts(); feeds != 1 {
		t.Fatalf("%d Page posts inside the window, want 1", feeds)
	}
	if p := e.post(t, e.page, "2026-10-28-third"); p.Status != store.MarketingScheduled || p.Attempts != 0 {
		t.Fatalf("the waiting post: %+v (never claimed, no attempt spent)", p)
	}
	e.clock.add(time.Hour + time.Minute)
	if r := e.sweep(); r.Published != 1 {
		t.Fatalf("after the window: %+v, want 1 published", r)
	}
}

// spec.md §21.1: never more than 100 Instagram API posts in 24 h, even
// with a channel cap above it.
func TestMarketingMetaInstagramLimit(t *testing.T) {
	for _, tc := range []struct {
		seeded    int
		published float64
	}{{99, 1}, {100, 0}} {
		e := newMetaPubEnv(t)
		e.m.DailyCap = 1000
		mk := e.st.(store.Marketing)
		ctx, now := context.Background(), e.clock.Now().Add(-time.Hour)
		for i := 0; i < tc.seeded; i++ {
			if _, err := mk.ScheduleMarketingPost(ctx, store.MarketingPost{Tenant: e.tid, ChannelID: e.ig.ID,
				SourceType: store.MarketingSourceBlog, SourceRef: "seed-" + strconv.Itoa(i)}, now); err != nil {
				t.Fatal(err)
			}
		}
		due, err := mk.ClaimMarketingPosts(ctx, e.tid, e.ig.ID, now)
		if err != nil || len(due) != tc.seeded {
			t.Fatalf("seed claim: %d, %v", len(due), err)
		}
		for _, p := range due {
			if err := mk.FinishMarketingPost(ctx, e.tid, p.ID, store.MarketingOutcome{Published: true, PlatformPostID: "seed"}, now); err != nil {
				t.Fatal(err)
			}
		}
		code, body := e.publish(t, e.owner, "2026-10-30-hello", e.ig)
		if code != http.StatusOK || body["published"] != tc.published {
			t.Fatalf("with %d Instagram posts in 24 h: %d %v, want published %v", tc.seeded, code, body, tc.published)
		}
	}
}

// OAuthException 190: the channel expires, the holder is mailed the
// re-connect link, the post waits unsent and goes out after the re-connect.
func TestMarketingMetaRefusedTokenWaitsForReconnect(t *testing.T) {
	e := newMetaPubEnv(t)
	e.fake.set(func(f *metaPubFake) { f.feedFail = metaFail(http.StatusUnauthorized, 190, nil) })
	code, body := e.publish(t, e.owner, "2026-10-30-hello", e.page)
	if code != http.StatusOK || body["retried"] != float64(1) {
		t.Fatalf("publish on a refused token: %d %v", code, body)
	}
	chs, _ := e.st.(store.Marketing).MarketingChannels(context.Background(), e.tid)
	for _, ch := range chs {
		if ch.ID == e.page.ID && ch.Status != store.MarketingExpired {
			t.Fatalf("channel after 190: %+v, want expired", ch)
		}
	}
	if len(*e.mails) != 1 || !strings.Contains((*e.mails)[0], "https://api.example.com/v1/marketing/facebook/connect?workspace="+e.tid) {
		t.Fatalf("mails %v, want one re-connect link", *e.mails)
	}
	if p := e.post(t, e.page, "2026-10-30-hello"); p.Status != store.MarketingScheduled {
		t.Fatalf("post after 190: %+v, want scheduled (waiting)", p)
	}
	e.sweep()
	if feeds, _, _ := e.fake.counts(); feeds != 1 {
		t.Fatalf("an expired channel was posted to: %d calls", feeds)
	}
	e.fake.set(func(f *metaPubFake) { f.feedFail = nil })
	sealed, keyID, _ := e.m.Sealer.Seal(context.Background(), marketing.NewPlaintext(fakeMetaPageToken))
	if _, err := e.st.(store.Marketing).ConnectMarketingChannel(context.Background(), e.page, store.MarketingToken{Ciphertext: sealed, KMSKeyID: keyID}, e.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if r := e.sweep(); r.Published != 1 {
		t.Fatalf("after the re-connect: %+v, want published 1", r)
	}
}

// A rate limit is retried after Meta's Retry-After; a 500 on the Page post
// may have posted, so it fails at once and is never sent again.
func TestMarketingMetaRateLimitRetriesAnd500NeverResent(t *testing.T) {
	e := newMetaPubEnv(t)
	e.fake.set(func(f *metaPubFake) {
		f.feedFail = metaFail(http.StatusBadRequest, 32, map[string]string{"Retry-After": "120"})
	})
	if code, body := e.publish(t, e.owner, "2026-10-30-hello", e.page); code != http.StatusOK || body["retried"] != float64(1) {
		t.Fatalf("rate-limited publish: %d %v", code, body)
	}
	e.fake.set(func(f *metaPubFake) { f.feedFail = nil })
	e.clock.add(time.Minute)
	if r := e.sweep(); r.Published != 0 {
		t.Fatalf("retried before Retry-After: %+v", r)
	}
	e.clock.add(2 * time.Minute)
	if r := e.sweep(); r.Published != 1 {
		t.Fatalf("after Retry-After: %+v, want published 1", r)
	}

	f := newMetaPubEnv(t)
	f.fake.set(func(x *metaPubFake) { x.feedFail = metaFail(http.StatusInternalServerError, 1, nil) })
	if code, body := f.publish(t, f.owner, "2026-10-30-hello", f.page); code != http.StatusOK || body["failed"] != float64(1) {
		t.Fatalf("publish answered 500: %d %v, want failed 1", code, body)
	}
	f.clock.add(time.Hour)
	f.sweep()
	if feeds, _, _ := f.fake.counts(); feeds != 1 || len(*f.mails) != 1 || !strings.Contains((*f.mails)[0], "will not retry it") {
		t.Fatalf("after a 500: %d Page posts, mails %v; want 1 and one failure mail", feeds, *f.mails)
	}
}

// The gates of the LinkedIn publish hold on the Meta one.
func TestMarketingMetaPublishGates(t *testing.T) {
	e := newMetaPubEnv(t)
	if code, _ := e.publish(t, e.admin, "2026-10-30-hello", e.page); code != http.StatusForbidden {
		t.Fatalf("admin publish: %d, want 403", code)
	}
	if code, _ := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/2026-10-30-hello/publish?channel=00000000-0000-4000-8000-000000000000", e.owner, nil); code != http.StatusNotFound {
		t.Fatalf("unknown channel: %d, want 404", code)
	}
	if code, _ := e.publish(t, e.owner, "2026-12-31-nope", e.page); code != http.StatusNotFound {
		t.Fatalf("post not live: %d, want 404", code)
	}
	if feeds, c, _ := e.fake.counts(); feeds != 0 || c != 0 {
		t.Fatalf("a refused publish reached Meta: %d posts, %d containers", feeds, c)
	}
	if code, _ := call(t, e.env, e.tid, http.MethodPatch, "/v1/marketing/settings", e.admin, map[string]any{"enabled": false}); code != http.StatusOK {
		t.Fatalf("switch off: %d", code)
	}
	if code, _ := e.publish(t, e.owner, "2026-10-30-hello", e.page); code != http.StatusNotFound {
		t.Fatalf("publish with marketing off: %d, want 404", code)
	}

	off := mktEnvWith(t, []string{e.tid}, func(o *hub.Options) {}, mktIDs(1)[0])
	if _, err := off.srv.PublishMetaPost(context.Background(), e.tid, e.owner, "2026-10-30-hello", e.page.ID); !errors.Is(err, hub.ErrMarketingNoMeta) {
		t.Fatalf("Meta not configured: %v, want ErrMarketingNoMeta", err)
	}
}
