package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-4564: the T034 review notes N2-N8 (R7 c-993, msg b20f5448), each
// with a case that fails on the T034 code (328ab0094).

// metaConnect connects one more Facebook Page of the workspace, by member by.
func (e *metaPubEnv) metaConnect(t *testing.T, ref, by string) store.MarketingChannel {
	t.Helper()
	sealed, keyID, err := e.m.Sealer.Seal(context.Background(), marketing.NewPlaintext(fakeMetaPageToken))
	if err != nil {
		t.Fatal(err)
	}
	ch, err := e.st.(store.Marketing).ConnectMarketingChannel(context.Background(), store.MarketingChannel{Tenant: e.tid,
		Platform: "facebook_page", AccountType: "page", AccountRef: ref, AccountName: "Page " + ref, DelegatedBy: by},
		store.MarketingToken{Ciphertext: sealed, KMSKeyID: keyID}, e.clock.Now())
	if err != nil {
		t.Fatal(err)
	}
	return ch
}

// metaSchedule records ref on ch as scheduled and due now.
func (e *metaPubEnv) metaSchedule(t *testing.T, ch store.MarketingChannel, ref string) {
	t.Helper()
	if _, err := e.st.(store.Marketing).ScheduleMarketingPost(context.Background(), store.MarketingPost{Tenant: e.tid,
		ChannelID: ch.ID, SourceType: store.MarketingSourceBlog, SourceRef: ref, ContentText: ref}, e.clock.Now()); err != nil {
		t.Fatal(err)
	}
}

// N2: a post in flight on the channel (claimed, its Meta call not answered
// yet) takes the cap's one place: an approval meanwhile posts nothing.
func TestMarketingMetaCapCountsInFlight(t *testing.T) {
	e := newMetaPubEnv(t)
	e.metaSchedule(t, e.page, "2026-10-28-third")
	if due, err := e.st.(store.Marketing).ClaimMarketingPosts(context.Background(), e.tid, e.page.ID, e.clock.Now()); err != nil || len(due) != 1 {
		t.Fatalf("in-flight claim: %+v, %v", due, err)
	}
	code, body := e.publish(t, e.owner, "2026-10-30-hello", e.page)
	if code != http.StatusOK || body["published"] != float64(0) || body["deferred"] != float64(1) {
		t.Fatalf("approval while a post is in flight: %d %v, want published 0, deferred 1", code, body)
	}
	if feeds, _, _ := e.fake.counts(); feeds != 0 {
		t.Fatalf("%d Page posts while one was in flight, want 0 (cap 1)", feeds)
	}
}

// N2: racing approvals of different posts on one channel make one Page post
// between them (cap 1), never two.
func TestMarketingMetaCapUnderRace(t *testing.T) {
	e := newMetaPubEnv(t)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		for _, post := range []string{"2026-10-30-hello", "2026-10-28-third"} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, _ = e.srv.PublishMetaPost(context.Background(), e.tid, e.owner, post, e.page.ID)
			}()
		}
	}
	wg.Wait()
	if feeds, _, _ := e.fake.counts(); feeds != 1 {
		t.Fatalf("%d Page posts from racing approvals of two posts, want 1 (cap 1)", feeds)
	}
}

// N3: a post the cap holds back in a sweep's batch spends no attempt and is
// not retried before the window frees.
func TestMarketingMetaCapHoldsBackWithoutAttempt(t *testing.T) {
	e := newMetaPubEnv(t)
	e.metaSchedule(t, e.page, "2026-10-28-third")
	e.metaSchedule(t, e.page, "2026-10-30-hello")
	if r := e.sweep(); r.Published != 1 || r.Retried != 0 || r.Failed != 0 {
		t.Fatalf("sweep of two due posts under cap 1: %+v, want published 1, nothing retried", r)
	}
	held := e.post(t, e.page, "2026-10-30-hello")
	if held.Status != store.MarketingScheduled || held.Attempts != 0 || held.LastError != "" {
		t.Fatalf("the held post: %+v, want scheduled, no attempt spent, no error", held)
	}
	e.clock.add(23 * time.Hour)
	e.sweep()
	if p := e.post(t, e.page, "2026-10-30-hello"); p.Attempts != 0 {
		t.Fatalf("held post claimed inside the window: %+v", p)
	}
	e.clock.add(time.Hour + time.Minute)
	if r := e.sweep(); r.Published != 1 {
		t.Fatalf("after the window: %+v, want published 1", r)
	}
	if p := e.post(t, e.page, "2026-10-30-hello"); p.Attempts != 1 || p.Status != store.MarketingPublished {
		t.Fatalf("held post after the window: %+v, want published on its first attempt", p)
	}
}

// N4 (dispatch ruling msg b76d61e2, spec.md §16.3 item 2): the member who
// connected the channel, or a member holding tenant.settings, approves;
// anyone else is 403.
func TestMarketingMetaApprover(t *testing.T) {
	e := newMetaPubEnv(t)
	dev := seat(t, e.env, e.tid, rbac.Developer)
	other := seat(t, e.env, e.tid, rbac.Developer)
	for i, tc := range []struct {
		name, as string
		want     int
	}{
		{"connector, not an owner", dev, http.StatusOK},
		{"admin (tenant.settings), not the connector", e.admin, http.StatusOK},
		{"biz_owner (holds tenant.settings), not the connector", e.owner, http.StatusOK},
		{"member with neither", other, http.StatusForbidden},
	} {
		ch := e.metaConnect(t, strconv.Itoa(2001+i), dev) // a Page id is digits
		code, body := e.publish(t, tc.as, "2026-10-30-hello", ch)
		if code != tc.want || (code == http.StatusForbidden && body["permission"] != rbac.TenantSettings) {
			t.Errorf("%s: %d %v, want %d (a 403 names tenant.settings)", tc.name, code, body, tc.want)
		}
	}
	if feeds, _, _ := e.fake.counts(); feeds != 3 {
		t.Fatalf("%d Page posts, want 3 (the three approvals)", feeds)
	}
}

// N5: a Meta post stuck in dispatching fails with a text, and a mail, that
// name Facebook, not LinkedIn.
func TestMarketingMetaStuckNamesPlatform(t *testing.T) {
	e := newMetaPubEnv(t)
	e.metaSchedule(t, e.page, "2026-10-30-hello")
	if due, err := e.st.(store.Marketing).ClaimMarketingPosts(context.Background(), e.tid, e.page.ID, e.clock.Now()); err != nil || len(due) != 1 {
		t.Fatalf("claim: %+v, %v", due, err)
	}
	e.clock.add(16 * time.Minute)
	if r := e.sweep(); r.Failed != 1 {
		t.Fatalf("sweep of a stuck post: %+v, want failed 1", r)
	}
	p := e.post(t, e.page, "2026-10-30-hello")
	if !strings.Contains(p.LastError, "during the Facebook call") || strings.Contains(p.LastError, "LinkedIn") {
		t.Fatalf("stuck Meta post error %q, want it to name Facebook", p.LastError)
	}
	if len(*e.mails) != 1 || !strings.Contains((*e.mails)[0], "during the Facebook call") {
		t.Fatalf("mails %v, want one naming the Facebook call", *e.mails)
	}
}

// N6: a client that goes away while Meta is answering does not cut the
// publish off: the post is recorded published, never left dispatching.
func TestMarketingMetaPublishSurvivesClientGone(t *testing.T) {
	e := newMetaPubEnv(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	e.fake.set(func(f *metaPubFake) {
		f.feedFail = func(http.ResponseWriter) bool {
			cancel()                           // the client hangs up mid-call
			time.Sleep(300 * time.Millisecond) // long enough for the hub to see it
			return false                       // then Meta answers: posted
		}
	})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, e.url(e.tid)+"/v1/marketing/posts/2026-10-30-hello/publish?channel="+e.page.ID, nil)
	req.Header.Set(memberHeader, e.owner)
	if resp, err := e.client.Do(req); err == nil {
		resp.Body.Close()
		t.Fatalf("the client was not cut off: %d", resp.StatusCode)
	}
	deadline := time.Now().Add(10 * time.Second)
	var p store.MarketingPost
	for time.Now().Before(deadline) {
		if p = e.post(t, e.page, "2026-10-30-hello"); p.Status != store.MarketingDispatching {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if feeds, _, _ := e.fake.counts(); p.Status != store.MarketingPublished || p.PlatformPostID != "1001_1" || feeds != 1 {
		t.Fatalf("post after the client left: %+v, %d Page posts; want published once", p, feeds)
	}
}

// N8: the agent (box upload token) door with ?channel publishes on the Meta
// channel for a member who may approve, and refuses anyone else.
func TestMarketingMetaAgentPublish(t *testing.T) {
	e := newMetaPubEnv(t)
	b := e.box(e.tid, "box-od", "c-002")
	e.pin(e.tid, b)
	e.clock.mu.Lock()
	saved := e.clock.now
	e.clock.now = time.Now()
	e.clock.mu.Unlock()
	tok := e.uploadToken(e.tid, b)
	e.clock.mu.Lock()
	e.clock.now = saved
	e.clock.mu.Unlock()
	dev := seat(t, e.env, e.tid, rbac.Developer)
	agent := func(requester string) (int, map[string]any) {
		req, _ := http.NewRequest(http.MethodPost, e.url(e.tid)+"/v1/marketing/posts/2026-10-30-hello/publish?channel="+e.page.ID, nil)
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
	for _, who := range []string{"", dev, "HUM-999999999"} {
		if code, body := agent(who); code != http.StatusForbidden {
			t.Fatalf("agent for %q: %d %v, want 403", who, code, body)
		}
	}
	if feeds, _, _ := e.fake.counts(); feeds != 0 {
		t.Fatalf("a refused agent publish reached Meta: %d", feeds)
	}
	if code, body := agent(e.owner); code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("agent for the owner: %d %v, want 200 published 1", code, body)
	}
	if code, _ := agent(e.owner); code != http.StatusConflict {
		t.Fatalf("second agent publish: %d, want 409", code)
	}
	if feeds, _, _ := e.fake.counts(); feeds != 1 || !e.buf.contains(`"agent":"box-od"`) {
		t.Fatalf("%d Page posts, log %s; want 1, attributed to box-od", feeds, e.buf.String())
	}
}

// N8: with Meta not configured the route answers 503 not_configured, and
// the dispatch sweep and its runner do nothing.
func TestMarketingMetaPublishNotConfigured(t *testing.T) {
	tid := mktIDs(1)[0]
	e := mktEnvWith(t, []string{tid}, func(o *hub.Options) {}, tid)
	admin := seat(t, e, tid, rbac.Admin)
	mktOn(t, e, tid, admin)
	owner := seat(t, e, tid, rbac.BizOwner)
	code, body := call(t, e, tid, http.MethodPost, "/v1/marketing/posts/2026-10-30-hello/publish?channel=00000000-0000-4000-8000-000000000000", owner, nil)
	if code != http.StatusServiceUnavailable || body["error"] != "not_configured" {
		t.Fatalf("Meta publish without Meta: %d %v, want 503 not_configured", code, body)
	}
	if r := e.srv.SweepMarketingMeta(context.Background()); r != (hub.MarketingShareResult{}) {
		t.Fatalf("sweep without Meta: %+v, want nothing", r)
	}
	done := make(chan struct{})
	go func() { e.srv.RunMarketingMetaDispatch(context.Background()); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("RunMarketingMetaDispatch kept running without Meta")
	}
}
