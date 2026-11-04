package hub_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 090 T036 (SPL-4804): POST /v1/marketing/posts/{id}/manual-publish
// records a live blog post the member posted by hand on a connected channel:
// published, platform_post_id 'manual', event post_handed_over; nothing
// reaches the platform and a second hand-over is 409. Memory store, and
// Postgres when the suite runs on it (newEnv).

func (e *metaPubEnv) handOver(t *testing.T, as, post, channel string) (int, map[string]any) {
	t.Helper()
	return call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/"+post+"/manual-publish?channel="+channel, as, nil)
}

func TestMarketingManualPublishHandsOver(t *testing.T) {
	e := newMetaPubEnv(t)
	code, body := e.handOver(t, e.owner, "2026-10-29-webp", e.ig.ID)
	if code != http.StatusOK || body["status"] != "published" || body["platform_post_id"] != "manual" ||
		body["published_at"] != "2026-10-30T09:00:00Z" || body["channel"] != e.ig.ID {
		t.Fatalf("hand-over: %d %v, want 200 published manual", code, body)
	}
	p := e.post(t, e.ig, "2026-10-29-webp")
	if p.Status != store.MarketingPublished || p.PlatformPostID != store.MarketingManualPostID || p.Attempts != 0 {
		t.Fatalf("post after the hand-over: %+v", p)
	}
	if feeds, containers, publishes := e.fake.counts(); feeds+containers+publishes != 0 {
		t.Fatalf("a hand-over called Meta: %d feeds, %d containers, %d publishes", feeds, containers, publishes)
	}
	if !e.buf.contains("handed over") {
		t.Fatalf("log: want the hand-over line:\n%s", e.buf.String())
	}
	// RED CONTROL: the post is recorded once; the second hand-over is 409
	if code, body := e.handOver(t, e.owner, "2026-10-29-webp", e.ig.ID); code != http.StatusConflict {
		t.Fatalf("second hand-over: %d %v, want 409", code, body)
	}
	// a hand-over takes nothing from the channel's daily cap: the API post still goes out
	if code, body := e.publish(t, e.owner, "2026-10-30-hello", e.ig); code != http.StatusOK || body["published"] != float64(1) {
		t.Fatalf("publish after a hand-over: %d %v, want 200 published 1", code, body)
	}
	if r := e.sweep(); r.Published != 0 {
		t.Fatalf("the sweep sent a handed-over post: %+v", r)
	}
}

// A post already approved for the API (scheduled) may still be handed over:
// it is then never sent.
func TestMarketingManualPublishScheduledPost(t *testing.T) {
	e := newMetaPubEnv(t)
	mk := e.st.(store.Marketing)
	if _, err := mk.ScheduleMarketingPost(context.Background(), store.MarketingPost{Tenant: e.tid, ChannelID: e.page.ID,
		SourceType: store.MarketingSourceBlog, SourceRef: "2026-10-28-third", ContentText: "Third",
		Status: store.MarketingScheduled}, e.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if code, body := e.handOver(t, e.admin, "2026-10-28-third", e.page.ID); code != http.StatusOK {
		t.Fatalf("hand-over of a scheduled post: %d %v", code, body)
	}
	if r := e.sweep(); r.Published != 0 {
		t.Fatalf("the sweep sent a handed-over post: %+v", r)
	}
	if feeds, _, _ := e.fake.counts(); feeds != 0 {
		t.Fatalf("%d Page posts, want 0", feeds)
	}
}

// RED CONTROL of the gates: a developer (no tenant.settings) is 403, an unknown channel or a
// post not in the live index 404, and nothing is recorded.
func TestMarketingManualPublishGates(t *testing.T) {
	e := newMetaPubEnv(t)
	member := seat(t, e.env, e.tid, rbac.Developer)
	cases := []struct {
		name, as, post, channel string
		want                    int
	}{
		{"developer", member, "2026-10-30-hello", e.page.ID, http.StatusForbidden},
		{"unknown channel", e.owner, "2026-10-30-hello", "00000000-0000-0000-0000-000000000000", http.StatusNotFound},
		{"no channel", e.owner, "2026-10-30-hello", "", http.StatusNotFound},
		{"post not live", e.owner, "2026-01-01-gone", e.page.ID, http.StatusNotFound},
	}
	for _, c := range cases {
		if code, body := e.handOver(t, c.as, c.post, c.channel); code != c.want {
			t.Errorf("%s: %d %v, want %d", c.name, code, body, c.want)
		}
	}
	if _, err := e.st.(store.MarketingMetaDispatch).MarketingPostByRef(context.Background(), e.tid, e.page.ID,
		store.MarketingSourceBlog, "2026-10-30-hello"); err == nil {
		t.Fatal("a refused hand-over recorded the post")
	}
}
