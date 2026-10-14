package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
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

// Spec 090 T015 / SPL-1634 and SPL-40: the blog share sweep and the owner's
// publish against a fake blog and a fake LinkedIn Posts API. The core proofs:
// the sweep never shares a new post, only the workspace owner's publish does;
// each post is shared exactly once, a retryable failure is retried then
// failed, and a post whose outcome is unknown is never sent again.

// shareFake is the WUI's live blog plus LinkedIn's REST API, in one server.
type shareFake struct {
	*httptest.Server
	mu        sync.Mutex
	posts     []marketing.BlogPost // the live en index, newest first
	shares    []map[string]any     // every POST /rest/posts body
	headers   []http.Header
	postCode  int  // the answer to POST /rest/posts (0 = 201)
	hangUp    bool // close the connection on POST /rest/posts after reading it
	uploads   int
	sawTokens []string
}

func newShareFake(t *testing.T) *shareFake {
	t.Helper()
	f := &shareFake{}
	f.Server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.Close)
	return f
}

func (f *shareFake) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch {
	case r.URL.Path == "/blog-md/index.json":
		_ = json.NewEncoder(w).Encode(map[string]any{"locales": map[string]any{"en": f.posts, "bg": []any{}}})
	case strings.HasPrefix(r.URL.Path, "/blog/img/"):
		var b bytes.Buffer
		_ = png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 4, 4)))
		_, _ = w.Write(b.Bytes())
	case r.URL.Path == "/rest/images":
		f.sawTokens = append(f.sawTokens, r.Header.Get("Authorization"))
		_, _ = io.WriteString(w, `{"value":{"uploadUrl":"`+f.URL+`/upload/1","image":"urn:li:image:1"}}`)
	case r.URL.Path == "/upload/1":
		f.uploads++
	case r.URL.Path == "/rest/posts":
		f.postsCall(w, r)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (f *shareFake) postsCall(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	f.shares = append(f.shares, body)
	f.headers = append(f.headers, r.Header.Clone())
	if f.hangUp {
		if hj, ok := w.(http.Hijacker); ok {
			c, _, _ := hj.Hijack()
			_ = c.Close()
			return
		}
	}
	if f.postCode != 0 {
		w.WriteHeader(f.postCode)
		_, _ = io.WriteString(w, `{"message":"fake failure"}`)
		return
	}
	w.Header().Set("X-Restli-Id", "urn:li:share:"+string(rune('0'+len(f.shares))))
	w.WriteHeader(http.StatusCreated)
}

func (f *shareFake) set(fn func(f *shareFake)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

func (f *shareFake) shareCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.shares)
}

func blogPost(id string) marketing.BlogPost {
	return marketing.BlogPost{ID: id, Title: "Post " + id + " (with [markup] & #tags)", Summary: "What " + id + " says.", Image: id + ".webp"}
}

type shareEnv struct {
	*env
	fake   *shareFake
	m      *hub.MarketingLinkedIn
	srv    *hub.Server
	clock  *shareClock
	tid    string
	admin  string
	owner  string
	ch     store.MarketingChannel
	mails  *[]string
	logBuf *syncBuf
}

type shareClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *shareClock) Now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *shareClock) add(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// newShareEnv: one allow-listed, switched-on workspace whose owner has a
// connected LinkedIn channel (token expires in 60 days), an admin, and a
// live blog with two posts.
func newShareEnv(t *testing.T) *shareEnv {
	t.Helper()
	fake := newShareFake(t)
	fake.posts = []marketing.BlogPost{blogPost("2026-10-02-second"), blogPost("2026-10-01-first")}
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k")
	if err != nil {
		t.Fatal(err)
	}
	mails := &[]string{}
	var mailMu sync.Mutex
	m := &hub.MarketingLinkedIn{
		LinkedIn: &marketing.LinkedIn{ClientID: "client-id", ClientSecret: marketing.NewPlaintext(fakeLinkedInSecret),
			Version: "202606", AuthBase: fake.URL, APIBase: fake.URL},
		Sealer: sealer, AppURL: fake.URL, APIURL: "https://api.example.com",
		Mail: func(_ context.Context, to, subject, body string) error {
			mailMu.Lock()
			defer mailMu.Unlock()
			*mails = append(*mails, to+"|"+subject+"|"+body)
			return nil
		},
	}
	clock := &shareClock{now: time.Date(2026, 10, 13, 9, 0, 0, 0, time.UTC)}
	buf := &syncBuf{}
	tid := mktIDs(1)[0]
	e := mktEnvWith(t, []string{tid}, func(o *hub.Options) {
		o.MarketingLinkedIn = m
		o.Log = zerolog.New(buf)
		o.Now = clock.Now
	}, tid)
	admin := seat(t, e, tid, rbac.Admin)
	mktOn(t, e, tid, admin)
	owner := seat(t, e, tid, rbac.BizOwner)
	sealed, keyID, err := sealer.Seal(context.Background(), marketing.NewPlaintext(fakeLinkedInToken))
	if err != nil {
		t.Fatal(err)
	}
	exp := clock.Now().Add(60 * 24 * time.Hour)
	ch, err := e.st.(store.Marketing).ConnectMarketingChannel(context.Background(), store.MarketingChannel{Tenant: tid,
		Platform: "linkedin", AccountRef: fakeLinkedInSub, DelegatedBy: owner, AutoPublish: true, ExpiresAt: &exp},
		store.MarketingToken{Ciphertext: sealed, KMSKeyID: keyID}, clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	return &shareEnv{env: e, fake: fake, m: m, srv: e.srv, clock: clock, tid: tid, admin: admin, owner: owner, ch: ch, mails: mails, logBuf: buf}
}

func (e *shareEnv) sweep() hub.MarketingShareResult {
	return e.srv.SweepMarketingShare(context.Background())
}

func (e *shareEnv) publish(id string) {
	e.fake.set(func(f *shareFake) { f.posts = append([]marketing.BlogPost{blogPost(id)}, f.posts...) })
}

// ownerPublish is the owner's publish of a live post; a refusal fails t.
func (e *shareEnv) ownerPublish(t *testing.T, id string) hub.MarketingShareResult {
	t.Helper()
	r, err := e.srv.PublishMarketingPost(context.Background(), e.tid, e.owner, id)
	if err != nil {
		t.Fatalf("owner publish %s: %v", id, err)
	}
	return r
}

// newPostWaits: a new post in the live index, two sweeps, nothing shared.
func (e *shareEnv) newPostWaits(t *testing.T, id string) {
	t.Helper()
	n := e.fake.shareCount()
	e.publish(id)
	if r1, r2 := e.sweep(), e.sweep(); r1 != (hub.MarketingShareResult{}) || r2 != (hub.MarketingShareResult{}) || e.fake.shareCount() != n {
		t.Fatalf("the sweep acted on new post %s: %+v then %+v, %d shares (was %d)", id, r1, r2, e.fake.shareCount(), n)
	}
}

func TestMarketingShareEachNewPostOnce(t *testing.T) {
	e := newShareEnv(t)
	// the first sweep records the back catalogue and shares none of it
	if r := e.sweep(); r.Baselined != 2 || r.Published != 0 || e.fake.shareCount() != 0 {
		t.Fatalf("baseline sweep %+v, %d shares; want 2 baselined, 0 shares", r, e.fake.shareCount())
	}
	if r := e.sweep(); r != (hub.MarketingShareResult{}) {
		t.Fatalf("quiet sweep did %+v", r)
	}
	// SPL-40: a new post waits for the owner; the sweep never shares it
	e.newPostWaits(t, "2026-10-13-new")
	r1 := e.ownerPublish(t, "2026-10-13-new")
	if _, err := e.srv.PublishMarketingPost(context.Background(), e.tid, e.owner, "2026-10-13-new"); !errors.Is(err, hub.ErrMarketingRecorded) {
		t.Fatalf("a second publish of one post: %v, want ErrMarketingRecorded", err)
	}
	if r2 := e.sweep(); r1.Scheduled != 1 || r1.Published != 1 || r2 != (hub.MarketingShareResult{}) || e.fake.shareCount() != 1 {
		t.Fatalf("owner publish: %+v then sweep %+v, %d shares; want one share", r1, r2, e.fake.shareCount())
	}
	got := e.fake.shares[0]
	content, _ := got["content"].(map[string]any)
	article, _ := content["article"].(map[string]any)
	if got["author"] != "urn:li:person:"+fakeLinkedInSub || got["lifecycleState"] != "PUBLISHED" || got["visibility"] != "PUBLIC" ||
		article["source"] != e.fake.URL+"/blog/2026-10-13-new" || article["thumbnail"] != "urn:li:image:1" {
		t.Fatalf("share body %v", got)
	}
	if c, _ := got["commentary"].(string); !strings.Contains(c, `Post 2026-10-13-new \(with \[markup\] & \#tags\)`) {
		t.Fatalf("commentary not little-text escaped: %q", c)
	}
	h := e.fake.headers[0]
	if h.Get("LinkedIn-Version") != "202606" || h.Get("X-Restli-Protocol-Version") != "2.0.0" || h.Get("Authorization") != "Bearer "+fakeLinkedInToken {
		t.Fatalf("share headers %v", h)
	}
	// publishes racing each other and the sweeps of two hub instances
	// still share a new post once
	e.newPostWaits(t, "2026-10-14-race")
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(2)
		go func() {
			defer wg.Done()
			_, _ = e.srv.PublishMarketingPost(context.Background(), e.tid, e.owner, "2026-10-14-race")
		}()
		go func() { defer wg.Done(); e.sweep() }()
	}
	wg.Wait()
	if n := e.fake.shareCount(); n != 2 {
		t.Fatalf("after the racing publishes: %d shares, want 2", n)
	}
	if strings.Contains(e.logBuf.String(), fakeLinkedInToken) {
		t.Fatal("the LinkedIn token reached a log line")
	}
}

func TestMarketingShareRetriesThenReports(t *testing.T) {
	e := newShareEnv(t)
	e.sweep()
	e.fake.set(func(f *shareFake) { f.postCode = http.StatusServiceUnavailable })
	e.newPostWaits(t, "2026-10-13-flaky")
	if r := e.ownerPublish(t, "2026-10-13-flaky"); r.Retried != 1 || e.fake.shareCount() != 1 {
		t.Fatalf("attempt 1: %+v, %d calls", r, e.fake.shareCount())
	}
	if r := e.sweep(); r.Retried != 0 || e.fake.shareCount() != 1 {
		t.Fatalf("CONTROL: retried before its time: %+v", r)
	}
	e.clock.add(15 * time.Minute)
	if r := e.sweep(); r.Retried != 1 || e.fake.shareCount() != 2 {
		t.Fatalf("attempt 2: %+v, %d calls", r, e.fake.shareCount())
	}
	e.clock.add(25 * time.Minute)
	if r := e.sweep(); r.Failed != 1 || e.fake.shareCount() != 3 {
		t.Fatalf("attempt 3: %+v, %d calls; want failed", r, e.fake.shareCount())
	}
	e.clock.add(time.Hour)
	if e.sweep(); e.fake.shareCount() != 3 {
		t.Fatalf("a failed post was sent again: %d calls", e.fake.shareCount())
	}
	if len(*e.mails) != 1 || !strings.Contains((*e.mails)[0], "was not shared on LinkedIn") {
		t.Fatalf("holder not told of the failure: %v", *e.mails)
	}
	if !strings.Contains(e.logBuf.String(), "blog share FAILED") {
		t.Fatal("the failure is not in the log")
	}
}

func TestMarketingShareUnknownOutcomeIsNeverResent(t *testing.T) {
	e := newShareEnv(t)
	e.sweep()
	e.fake.set(func(f *shareFake) { f.hangUp = true })
	e.newPostWaits(t, "2026-10-13-lost")
	if r := e.ownerPublish(t, "2026-10-13-lost"); r.Failed != 1 || e.fake.shareCount() != 1 {
		t.Fatalf("hang-up: %+v, %d calls; want failed at once", r, e.fake.shareCount())
	}
	e.fake.set(func(f *shareFake) { f.hangUp = false })
	e.clock.add(2 * time.Hour)
	if e.sweep(); e.fake.shareCount() != 1 {
		t.Fatalf("an unknown-outcome post was sent again: %d calls", e.fake.shareCount())
	}
}

func TestMarketingShareServerErrorIsNeverResent(t *testing.T) {
	e := newShareEnv(t)
	e.sweep()
	e.fake.set(func(f *shareFake) { f.postCode = http.StatusInternalServerError })
	e.newPostWaits(t, "2026-10-13-maybe")
	if r := e.ownerPublish(t, "2026-10-13-maybe"); r.Failed != 1 || e.fake.shareCount() != 1 {
		t.Fatalf("500: %+v, %d calls; want failed at once (LinkedIn may have posted it)", r, e.fake.shareCount())
	}
	e.fake.set(func(f *shareFake) { f.postCode = 0 })
	e.clock.add(2 * time.Hour)
	if e.sweep(); e.fake.shareCount() != 1 {
		t.Fatalf("a post answered with 500 was sent again: %d calls", e.fake.shareCount())
	}
}

func TestMarketingShare401WaitsForReconnect(t *testing.T) {
	e := newShareEnv(t)
	e.sweep()
	e.fake.set(func(f *shareFake) { f.postCode = http.StatusUnauthorized })
	e.newPostWaits(t, "2026-10-13-later")
	if r := e.ownerPublish(t, "2026-10-13-later"); r.Retried != 1 {
		t.Fatalf("401: %+v", r)
	}
	chs, _ := e.st.(store.Marketing).MarketingChannels(context.Background(), e.tid)
	if chs[0].Status != store.MarketingExpired {
		t.Fatalf("channel after 401: %s, want expired", chs[0].Status)
	}
	if len(*e.mails) != 1 || !strings.Contains((*e.mails)[0], "connect again") || !strings.Contains((*e.mails)[0], e.m.ConnectLink(e.tid)) {
		t.Fatalf("holder not asked to re-connect: %v", *e.mails)
	}
	// the re-connect renews the channel; the waiting post is shared, once
	e.fake.set(func(f *shareFake) { f.postCode = 0 })
	sealed, keyID, _ := e.m.Sealer.Seal(context.Background(), marketing.NewPlaintext(fakeLinkedInToken))
	exp := e.clock.Now().Add(60 * 24 * time.Hour)
	if _, err := e.st.(store.Marketing).ConnectMarketingChannel(context.Background(), store.MarketingChannel{Tenant: e.tid,
		Platform: "linkedin", AccountRef: fakeLinkedInSub, DelegatedBy: e.owner, AutoPublish: true, ExpiresAt: &exp},
		store.MarketingToken{Ciphertext: sealed, KMSKeyID: keyID}, e.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if r := e.sweep(); r.Published != 1 || e.fake.shareCount() != 2 {
		t.Fatalf("after the re-connect: %+v, %d calls", r, e.fake.shareCount())
	}
}

func TestMarketingShareSwitchOffSharesNothing(t *testing.T) {
	e := newShareEnv(t)
	e.sweep()
	if code, _ := call(t, e.env, e.tid, http.MethodPatch, "/v1/marketing/settings", e.admin, map[string]any{"enabled": false}); code != 200 {
		t.Fatal(code)
	}
	e.publish("2026-10-13-off")
	if r := e.sweep(); r != (hub.MarketingShareResult{}) || e.fake.shareCount() != 0 {
		t.Fatalf("switched off: %+v, %d shares", r, e.fake.shareCount())
	}
	if _, err := e.srv.PublishMarketingPost(context.Background(), e.tid, e.owner, "2026-10-13-off"); !errors.Is(err, hub.ErrMarketingOff) || e.fake.shareCount() != 0 {
		t.Fatalf("owner publish while switched off: %v, %d shares", err, e.fake.shareCount())
	}
}

func TestMarketingShareReminderOnceAWeekAhead(t *testing.T) {
	e := newShareEnv(t)
	e.sweep()
	e.clock.add(52 * 24 * time.Hour) // 8 days left: no reminder yet
	if r := e.sweep(); r.Reminded != 0 {
		t.Fatalf("reminded 8 days ahead: %+v", r)
	}
	e.clock.add(2 * 24 * time.Hour) // 6 days left
	if r := e.sweep(); r.Reminded != 1 {
		t.Fatalf("6 days ahead: %+v, want one reminder", r)
	}
	if r := e.sweep(); r.Reminded != 0 {
		t.Fatalf("a second reminder: %+v", r)
	}
	if len(*e.mails) != 1 || !strings.Contains((*e.mails)[0], e.m.ConnectLink(e.tid)) {
		t.Fatalf("reminder mail %v", *e.mails)
	}
	e.clock.add(7 * 24 * time.Hour) // past the end
	if r := e.sweep(); r.Expired != 1 {
		t.Fatalf("past expiry: %+v, want expired", r)
	}
}

// SPL-40 (owner HUM-10, topic add4fbf4 msg 3a3f366b): only the workspace
// owner publishes to LinkedIn. An admin, another member and an agent are
// refused, on the route and on the method; the owner's publish goes out.
func TestMarketingShareOnlyTheOwnerPublishes(t *testing.T) {
	e := newShareEnv(t)
	e.sweep()
	e.newPostWaits(t, "2026-10-13-owner")
	dev, agent := seat(t, e.env, e.tid, rbac.Developer), seat(t, e.env, e.tid, rbac.PureAgent)
	for _, who := range []string{e.admin, dev, agent, "", "AGT-1"} {
		if _, err := e.srv.PublishMarketingPost(context.Background(), e.tid, who, "2026-10-13-owner"); !errors.Is(err, hub.ErrMarketingNotOwner) {
			t.Fatalf("publish as %q: %v, want ErrMarketingNotOwner", who, err)
		}
	}
	path := "/v1/marketing/posts/2026-10-13-owner/publish"
	if code, body := call(t, e.env, e.tid, http.MethodPost, path, e.admin, nil); code != http.StatusForbidden {
		t.Fatalf("admin POST %s: %d %v, want 403", path, code, body)
	}
	if n := e.fake.shareCount(); n != 0 {
		t.Fatalf("a refused publish reached LinkedIn: %d shares", n)
	}
	// CONTROL: the owner, on the same route, is shared once
	code, body := call(t, e.env, e.tid, http.MethodPost, path, e.owner, nil)
	if code != http.StatusOK || body["published"] != float64(1) || e.fake.shareCount() != 1 {
		t.Fatalf("owner POST %s: %d %v, %d shares; want 200, one share", path, code, body, e.fake.shareCount())
	}
	if code, _ := call(t, e.env, e.tid, http.MethodPost, path, e.owner, nil); code != http.StatusConflict || e.fake.shareCount() != 1 {
		t.Fatalf("second owner POST: %d, %d shares; want 409, still one", code, e.fake.shareCount())
	}
	if code, _ := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/2026-10-01-first/publish", e.owner, nil); code != http.StatusConflict {
		t.Fatalf("publish of a baselined post: %d, want 409", code)
	}
	if code, _ := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/2026-12-31-nope/publish", e.owner, nil); code != http.StatusNotFound {
		t.Fatalf("publish of a post not live: %d, want 404", code)
	}
}

// agentToken mints b's upload token under the real clock (the hello is
// signed now; the share clock is fixed), then puts the share clock back.
func (e *shareEnv) agentToken(tid string, b *box) string {
	e.clock.mu.Lock()
	saved := e.clock.now
	e.clock.now = time.Now()
	e.clock.mu.Unlock()
	defer func() { e.clock.mu.Lock(); e.clock.now = saved; e.clock.mu.Unlock() }()
	return e.uploadToken(tid, b)
}

// agentPublish POSTs the publish of id with an agent's upload token, naming
// requester (none when "") in X-Spool-Requester.
func (e *shareEnv) agentPublish(t *testing.T, tid, tok, requester, id string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/marketing/posts/"+id+"/publish", nil)
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

// SPL-1855 (owner HUM-10, topic f46301d4 msgs 54795a30, c5ed6345): an agent
// publishes a live post for the workspace owner, on the owner's connected
// channel, once. It is refused for anyone but the owner, and outside the
// allow-list; the sweep still starts nothing.
func TestMarketingShareAgentPublishesForTheOwner(t *testing.T) {
	e := newShareEnv(t)
	e.sweep()
	e.newPostWaits(t, "2026-10-14-agent")
	b := e.box(e.tid, "box-od", "c-002")
	e.pin(e.tid, b)
	tok := e.agentToken(e.tid, b)
	dev := seat(t, e.env, e.tid, rbac.Developer)
	for _, who := range []string{"", e.admin, dev, "HUM-999999999"} {
		if code, body := e.agentPublish(t, e.tid, tok, who, "2026-10-14-agent"); code != http.StatusForbidden {
			t.Fatalf("agent for %q: %d %v, want 403", who, code, body)
		}
	}
	if n := e.fake.shareCount(); n != 0 {
		t.Fatalf("a refused agent publish reached LinkedIn: %d shares", n)
	}
	code, body := e.agentPublish(t, e.tid, tok, e.owner, "2026-10-14-agent")
	if code != http.StatusOK || body["published"] != float64(1) || e.fake.shareCount() != 1 {
		t.Fatalf("agent for the owner: %d %v, %d shares; want 200, one share", code, body, e.fake.shareCount())
	}
	e.fake.mu.Lock()
	commentary, _ := e.fake.shares[0]["commentary"].(string)
	author, _ := e.fake.shares[0]["author"].(string)
	e.fake.mu.Unlock()
	if author != "urn:li:person:"+fakeLinkedInSub || !strings.HasPrefix(commentary, "\U0001F4DD ") {
		t.Fatalf("share: author %q commentary %q; want the owner's channel and the emoji commentary", author, commentary)
	}
	if !strings.Contains(e.logBuf.String(), `"agent":"box-od"`) {
		t.Fatalf("the agent's publish is not attributed in the log: %s", e.logBuf.String())
	}
	// once: a second publish, by the agent or the owner, is refused; the sweep adds nothing
	if code, _ := e.agentPublish(t, e.tid, tok, e.owner, "2026-10-14-agent"); code != http.StatusConflict {
		t.Fatalf("second agent publish: %d, want 409", code)
	}
	if code, _ := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/2026-10-14-agent/publish", e.owner, nil); code != http.StatusConflict {
		t.Fatalf("owner publish after the agent's: %d, want 409", code)
	}
	if r := e.sweep(); r != (hub.MarketingShareResult{}) || e.fake.shareCount() != 1 {
		t.Fatalf("sweep after the publish: %+v, %d shares; want nothing, one", r, e.fake.shareCount())
	}
	// a workspace outside the allow-list: 404, nothing shared
	other, _ := e.tenant()
	ob := e.box(other, "box-x", "c-003")
	e.pin(other, ob)
	if code, _ := e.agentPublish(t, other, e.agentToken(other, ob), e.owner, "2026-10-01-first"); code != http.StatusNotFound || e.fake.shareCount() != 1 {
		t.Fatalf("agent outside the allow-list: %d, %d shares; want 404, still one", code, e.fake.shareCount())
	}
}
