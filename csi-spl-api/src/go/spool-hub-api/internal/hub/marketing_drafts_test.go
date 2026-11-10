package hub_test

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 090 section 22 / SPL-5240 (owner HUM-10, t1 19ef7d51; poll c1d8be01
// Q1 A, Q2 A): a workspace's admins and business owners write posts in the
// WUI and the author publishes them on the workspace's channels, with no
// approval step. Every platform here is a fake: nothing reaches a real one.

// draftCreate creates a draft as `as` and returns its id; a refusal fails t.
func draftCreate(t *testing.T, e *env, tid, as, body, img string) string {
	t.Helper()
	code, out := call(t, e, tid, http.MethodPost, "/v1/marketing/drafts", as, map[string]any{"body": body, "image_url": img})
	id, _ := out["id"].(string)
	if code != http.StatusCreated || id == "" || out["mine"] != true || out["body"] != body {
		t.Fatalf("create as %s: %d %v", as, code, out)
	}
	return id
}

// draftPublish publishes draft id on chs as `as`: the per-channel results.
func draftPublish(t *testing.T, e *env, tid, as, id string, chs ...string) (int, map[string]map[string]any) {
	t.Helper()
	code, out := call(t, e, tid, http.MethodPost, "/v1/marketing/drafts/"+id+"/publish", as, map[string]any{"channels": chs})
	res := map[string]map[string]any{}
	rs, _ := out["results"].([]any)
	for _, r := range rs {
		m, _ := r.(map[string]any)
		ch, _ := m["channel_id"].(string)
		res[ch] = m
	}
	return code, res
}

// TestMarketingDraftRoles: an admin and a business owner write, list and
// read each other's drafts; only the author edits, deletes and publishes;
// every other role gets 403 naming tenant.settings, on every route.
func TestMarketingDraftRoles(t *testing.T) {
	e := newShareEnv(t)
	id := draftCreate(t, e.env, e.tid, e.admin, "News from the admin", "")
	for _, who := range []struct {
		name, hum string
		mine      bool
	}{{"admin", e.admin, true}, {"biz_owner", e.owner, false}} {
		code, out := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/drafts", who.hum, nil)
		ds, _ := out["drafts"].([]any)
		chs, _ := out["channels"].([]any)
		if code != http.StatusOK || len(ds) != 1 || len(chs) != 1 {
			t.Fatalf("%s GET: %d %v, want 200 with one draft and the LinkedIn channel", who.name, code, out)
		}
		if d, _ := ds[0].(map[string]any); d["id"] != id || d["mine"] != who.mine {
			t.Fatalf("%s GET: draft %v, want %s mine=%v", who.name, d, id, who.mine)
		}
	}
	draftCreate(t, e.env, e.tid, e.owner, "News from the business owner", "")
	// not the author: no edit, no delete, no publish
	if code, out := call(t, e.env, e.tid, http.MethodPatch, "/v1/marketing/drafts/"+id, e.owner, map[string]any{"body": "x"}); code != http.StatusForbidden {
		t.Fatalf("biz_owner edits the admin's draft: %d %v, want 403", code, out)
	}
	if code, out := call(t, e.env, e.tid, http.MethodDelete, "/v1/marketing/drafts/"+id, e.owner, nil); code != http.StatusForbidden {
		t.Fatalf("biz_owner deletes the admin's draft: %d %v, want 403", code, out)
	}
	if code, _ := draftPublish(t, e.env, e.tid, e.owner, id, e.ch.ID); code != http.StatusForbidden {
		t.Fatalf("biz_owner publishes the admin's draft: %d, want 403", code)
	}
	for _, role := range []string{rbac.Developer, rbac.Tester, rbac.RegularUser, rbac.ProductOwner, rbac.BizCustomer} {
		who := seat(t, e.env, e.tid, role)
		for _, x := range []struct {
			method, path string
			body         any
		}{
			{http.MethodGet, "/v1/marketing/drafts", nil},
			{http.MethodPost, "/v1/marketing/drafts", map[string]any{"body": "x"}},
			{http.MethodPatch, "/v1/marketing/drafts/" + id, map[string]any{"body": "x"}},
			{http.MethodDelete, "/v1/marketing/drafts/" + id, nil},
			{http.MethodPost, "/v1/marketing/drafts/" + id + "/publish", map[string]any{"channels": []string{e.ch.ID}}},
		} {
			if code, out := call(t, e.env, e.tid, x.method, x.path, who, x.body); code != http.StatusForbidden || out["permission"] != rbac.TenantSettings {
				t.Fatalf("%s %s %s: %d %v, want 403 naming tenant.settings", role, x.method, x.path, code, out)
			}
		}
	}
	if n := e.fake.shareCount(); n != 0 {
		t.Fatalf("%d LinkedIn shares, want none", n)
	}
}

// TestMarketingDraftNeverInDemo: the open demo workspace never writes a
// post, under "all" and for its admin and business owner alike.
func TestMarketingDraftNeverInDemo(t *testing.T) {
	e, demo := demoEnv(t, func(o *hub.Options) { o.MarketingWorkspaces = []string{"all"} })
	for _, role := range []string{rbac.Admin, rbac.BizOwner} {
		who := seat(t, e, demo, role)
		for _, m := range []string{http.MethodGet, http.MethodPost} {
			if code, _ := call(t, e, demo, m, "/v1/marketing/drafts", who, map[string]any{"body": "x"}); code != http.StatusForbidden {
				t.Fatalf("demo %s %s: %d, want 403", role, m, code)
			}
		}
	}
}

// TestMarketingDraftOtherWorkspace: workspace A's admin neither lists,
// edits, deletes nor publishes workspace B's draft: 404, as if absent.
func TestMarketingDraftOtherWorkspace(t *testing.T) {
	ids := mktIDs(2)
	e := mktEnvWith(t, ids, func(*hub.Options) {}, ids...)
	adminA, adminB := seat(t, e, ids[0], rbac.Admin), seat(t, e, ids[1], rbac.Admin)
	mktOn(t, e, ids[0], adminA)
	mktOn(t, e, ids[1], adminB)
	idB := draftCreate(t, e, ids[1], adminB, "B's own words", "")
	if code, out := call(t, e, ids[0], http.MethodGet, "/v1/marketing/drafts", adminA, nil); code != http.StatusOK || len(out["drafts"].([]any)) != 0 {
		t.Fatalf("A lists: %d %v, want 200 and none of B's", code, out)
	}
	for _, x := range []struct {
		method, path string
		body         any
	}{
		{http.MethodPatch, "/v1/marketing/drafts/" + idB, map[string]any{"body": "A writes"}},
		{http.MethodDelete, "/v1/marketing/drafts/" + idB, nil},
		{http.MethodPost, "/v1/marketing/drafts/" + idB + "/publish", map[string]any{"channels": []string{"any"}}},
	} {
		if code, out := call(t, e, ids[0], x.method, x.path, adminA, x.body); code != http.StatusNotFound {
			t.Fatalf("A %s %s: %d %v, want 404", x.method, x.path, code, out)
		}
	}
	d, err := e.st.(store.MarketingDrafts).MarketingDraft(context.Background(), ids[1], idB)
	if err != nil || d.Body != "B's own words" || d.PublishedAt != nil {
		t.Fatalf("B's draft after A's calls: %+v %v", d, err)
	}
}

// TestMarketingDraftValidation: no text, too long a text and a non-https
// picture are 400; marketing switched off is 404 (marketingRoute).
func TestMarketingDraftValidation(t *testing.T) {
	e := newShareEnv(t)
	for _, b := range []map[string]any{{}, {"body": "  "}, {"body": strings.Repeat("a", 3001)},
		{"body": "ok", "image_url": "http://example.com/a.jpg"}, {"body": "ok", "image_url": "https://user@example.com/a.jpg"}} {
		if code, out := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/drafts", e.admin, b); code != http.StatusBadRequest {
			t.Fatalf("create %v: %d %v, want 400", b, code, out)
		}
	}
	id := draftCreate(t, e.env, e.tid, e.admin, strings.Repeat("é", 3000), "https://example.com/a.jpg")
	if code, _ := draftPublish(t, e.env, e.tid, e.admin, id); code != http.StatusBadRequest {
		t.Fatalf("publish with no channel: %d, want 400", code)
	}
	if code, out := call(t, e.env, e.tid, http.MethodPatch, "/v1/marketing/settings", e.admin, map[string]any{"enabled": false}); code != http.StatusOK {
		t.Fatalf("switch off: %d %v", code, out)
	}
	if code, _ := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/drafts", e.admin, nil); code != http.StatusNotFound {
		t.Fatalf("GET with marketing off: %d, want 404", code)
	}
}

// TestMarketingDraftLinkedInPublish: the author publishes once on the
// connector's LinkedIn profile, a text post with no card; a second publish
// there is already_recorded, and the published draft is kept as it went out.
func TestMarketingDraftLinkedInPublish(t *testing.T) {
	e := newShareEnv(t)
	id := draftCreate(t, e.env, e.tid, e.admin, "First draft", "")
	if code, out := call(t, e.env, e.tid, http.MethodPatch, "/v1/marketing/drafts/"+id, e.admin, map[string]any{"body": "Our news (today) #spool"}); code != http.StatusOK || out["body"] != "Our news (today) #spool" {
		t.Fatalf("edit: %d %v", code, out)
	}
	code, res := draftPublish(t, e.env, e.tid, e.admin, id, e.ch.ID, "no-such-channel")
	if code != http.StatusOK || res[e.ch.ID]["outcome"] != "published" || res["no-such-channel"]["error"] != "not_found" {
		t.Fatalf("publish: %d %v", code, res)
	}
	if n := e.fake.shareCount(); n != 1 {
		t.Fatalf("%d shares, want 1", n)
	}
	e.fake.mu.Lock()
	sh := e.fake.shares[0]
	e.fake.mu.Unlock()
	if _, card := sh["content"]; card || sh["commentary"] != `Our news \(today\) \#spool` || sh["author"] != "urn:li:person:"+fakeLinkedInSub {
		t.Fatalf("share body %v, want the text alone on the connector's profile", sh)
	}
	if code, res := draftPublish(t, e.env, e.tid, e.admin, id, e.ch.ID); code != http.StatusOK || res[e.ch.ID]["error"] != "already_recorded" || e.fake.shareCount() != 1 {
		t.Fatalf("second publish: %d %v, %d shares; want already_recorded, still 1", code, res, e.fake.shareCount())
	}
	if code, _ := call(t, e.env, e.tid, http.MethodPatch, "/v1/marketing/drafts/"+id, e.admin, map[string]any{"body": "late"}); code != http.StatusConflict {
		t.Fatalf("edit after publish: %d, want 409", code)
	}
	if code, _ := call(t, e.env, e.tid, http.MethodDelete, "/v1/marketing/drafts/"+id, e.admin, nil); code != http.StatusConflict {
		t.Fatalf("delete after publish: %d, want 409", code)
	}
	_, out := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/drafts", e.admin, nil)
	d, _ := out["drafts"].([]any)[0].(map[string]any)
	posts, _ := d["posts"].([]any)
	if d["published_at"] == nil || len(posts) != 1 || posts[0].(map[string]any)["status"] != store.MarketingPublished {
		t.Fatalf("listed draft %v, want published with one published post", d)
	}
	// the share sweep never sends it again
	e.clock.add(time.Hour)
	e.sweep()
	if n := e.fake.shareCount(); n != 1 {
		t.Fatalf("%d shares after a sweep, want 1", n)
	}
	// an unpublished draft is deleted
	gone := draftCreate(t, e.env, e.tid, e.admin, "never sent", "")
	if code, _ := call(t, e.env, e.tid, http.MethodDelete, "/v1/marketing/drafts/"+gone, e.admin, nil); code != http.StatusNoContent {
		t.Fatalf("delete: %d, want 204", code)
	}
}

// TestMarketingDraftMetaPublish: a text post goes to the Facebook Page's
// feed with no link; Instagram takes only a draft with a JPEG picture.
func TestMarketingDraftMetaPublish(t *testing.T) {
	e := newMetaPubEnv(t)
	text := draftCreate(t, e.env, e.tid, e.owner, "Workshop on Friday", "")
	code, res := draftPublish(t, e.env, e.tid, e.owner, text, e.page.ID, e.ig.ID)
	if code != http.StatusOK || res[e.page.ID]["outcome"] != "published" || res[e.ig.ID]["error"] != "instagram_needs_jpeg" {
		t.Fatalf("publish text: %d %v", code, res)
	}
	feeds, containers, _ := e.fake.counts()
	e.fake.mu.Lock()
	form := url.Values(e.fake.feeds[0])
	e.fake.mu.Unlock()
	if feeds != 1 || containers != 0 || form.Get("message") != "Workshop on Friday" || form.Get("link") != "" {
		t.Fatalf("feeds %d containers %d form %v, want one feed post with the text and no link", feeds, containers, form)
	}
	pic := draftCreate(t, e.env, e.tid, e.owner, "See you there", "https://cdn.example.com/poster.jpg")
	if code, res := draftPublish(t, e.env, e.tid, e.owner, pic, e.ig.ID); code != http.StatusOK || res[e.ig.ID]["outcome"] != "published" {
		t.Fatalf("publish picture on Instagram: %d %v", code, res)
	}
	if _, containers, publishes := e.fake.counts(); containers != 1 || publishes != 1 {
		t.Fatalf("containers %d publishes %d, want one each", containers, publishes)
	}
}

// TestMarketingDraftXPublish: the text goes to X as it is; one over 280
// weighted characters is refused before anything is recorded.
func TestMarketingDraftXPublish(t *testing.T) {
	e := newXEnv(t, false)
	if code, body := e.connect(t, e.admin); code != http.StatusOK && code != http.StatusFound {
		t.Fatalf("connect: %d %s", code, body)
	}
	ch := e.channel(t)
	long := draftCreate(t, e.env, e.tid, e.admin, strings.Repeat("a", 281), "")
	if code, res := draftPublish(t, e.env, e.tid, e.admin, long, ch.ID); code != http.StatusOK || res[ch.ID]["error"] != "x_too_long" {
		t.Fatalf("publish 281: %d %v", code, res)
	}
	if code, _ := call(t, e.env, e.tid, http.MethodPatch, "/v1/marketing/drafts/"+long, e.admin, map[string]any{"body": "fits"}); code != http.StatusOK {
		t.Fatalf("a refused publish leaves the draft editable: %d, want 200", code)
	}
	ok := draftCreate(t, e.env, e.tid, e.admin, "Short and sweet", "")
	if code, res := draftPublish(t, e.env, e.tid, e.admin, ok, ch.ID); code != http.StatusOK || res[ch.ID]["outcome"] != "published" {
		t.Fatalf("publish: %d %v", code, res)
	}
	if sent := e.fake.sent(); len(sent) != 1 || sent[0] != "Short and sweet" {
		t.Fatalf("tweets %q, want the text alone", sent)
	}
}
