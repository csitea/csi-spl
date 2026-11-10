package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-5196 (owner HUM-10, t1 19ef7d51 msg 8c73a054: "any person with
// either a business owner or admin role in a workspace ... to post that
// content from the integrated posts for the particular target system"):
// LinkedIn takes Facebook's rule (metaApprover). The member who connected
// the channel, or a member holding tenant.settings (biz_owner and admin by
// the default roles), lists and publishes; the share still goes out on the
// connector's own profile, and the list names it. Every other role is 403.
func TestMarketingLinkedInAdminAndOwnerPublish(t *testing.T) {
	e := newShareEnv(t)
	e.sweep()
	owner2 := seat(t, e.env, e.tid, rbac.BizOwner) // a business owner who did not connect
	for i, who := range []struct{ name, hum string }{{"admin", e.admin}, {"biz_owner, not the connector", owner2}, {"connector", e.owner}} {
		id := "2026-10-2" + string(rune('1'+i)) + "-by"
		e.newPostWaits(t, id)
		code, body := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts", who.hum, nil)
		if code != http.StatusOK || !listsPost(body, id) {
			t.Fatalf("%s GET /v1/marketing/posts: %d %v, want 200 listing %s", who.name, code, body, id)
		}
		profiles, _ := body["profiles"].([]any)
		if len(profiles) != 1 {
			t.Fatalf("%s: profiles %v, want the one LinkedIn channel", who.name, body["profiles"])
		}
		pr, _ := profiles[0].(map[string]any)
		if pr["name"] != "FirstName LastName" || pr["mine"] != (who.hum == e.owner) {
			t.Fatalf("%s: profile %v, want the connector's name and mine=%v", who.name, pr, who.hum == e.owner)
		}
		n := e.fake.shareCount()
		code, body = call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/"+id+"/publish", who.hum, nil)
		if code != http.StatusOK || body["published"] != float64(1) || e.fake.shareCount() != n+1 {
			t.Fatalf("%s publish: %d %v, %d shares (was %d); want 200, one more", who.name, code, body, e.fake.shareCount(), n)
		}
		e.fake.mu.Lock()
		author, _ := e.fake.shares[n]["author"].(string)
		e.fake.mu.Unlock()
		if author != "urn:li:person:"+fakeLinkedInSub {
			t.Fatalf("%s publish: author %q, want the connector's profile", who.name, author)
		}
	}
	e.newPostWaits(t, "2026-10-29-refused")
	for _, role := range []string{rbac.Developer, rbac.Tester, rbac.RegularUser, rbac.ProductOwner} {
		who := seat(t, e.env, e.tid, role)
		if _, err := e.srv.UnsharedMarketingPosts(context.Background(), e.tid, who); !errors.Is(err, hub.ErrMarketingNotOwner) {
			t.Fatalf("%s list: %v, want ErrMarketingNotOwner", role, err)
		}
		if code, body := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts", who, nil); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
			t.Fatalf("%s GET: %d %v, want 403 naming tenant.settings", role, code, body)
		}
		if code, body := call(t, e.env, e.tid, http.MethodPost, "/v1/marketing/posts/2026-10-29-refused/publish", who, nil); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
			t.Fatalf("%s publish: %d %v, want 403 naming tenant.settings", role, code, body)
		}
	}
	if n := e.fake.shareCount(); n != 3 {
		t.Fatalf("%d shares, want the three allowed publishes", n)
	}
}

// SPL-5196: a workspace's admin with no LinkedIn connected at all gets
// 404 (no channel), not 403: the right is there, the account is not.
func TestMarketingLinkedInAdminNoChannel(t *testing.T) {
	e := newShareEnv(t)
	if _, err := e.st.(store.Marketing).DisconnectMarketingChannel(context.Background(), e.tid, e.ch.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.srv.PublishMarketingPost(context.Background(), e.tid, e.admin, "2026-10-01-first"); !errors.Is(err, hub.ErrMarketingNoChannel) {
		t.Fatalf("admin publish with no channel: %v, want ErrMarketingNoChannel", err)
	}
}

// SPL-5196: the open demo workspace never lists or publishes, under "all"
// and for its admin and business owner alike (specs/077).
func TestMarketingLinkedInNeverInDemo(t *testing.T) {
	e, demo := demoEnv(t, func(o *hub.Options) { o.MarketingWorkspaces = []string{"all"} })
	for _, role := range []string{rbac.Admin, rbac.BizOwner} {
		who := seat(t, e, demo, role)
		for _, x := range []struct{ method, path string }{
			{http.MethodGet, "/v1/marketing/posts"}, {http.MethodPost, "/v1/marketing/posts/2026-10-01-first/publish"},
		} {
			if code, _ := call(t, e, demo, x.method, x.path, who, nil); code != http.StatusForbidden {
				t.Fatalf("demo %s %s %s: %d, want 403", role, x.method, x.path, code)
			}
		}
	}
}

// SPL-5196: the Facebook / Instagram list takes the publish's own rule
// (metaApprover): the connector or a tenant.settings holder lists; it was
// the workspace owner only, so the admin who connected the Page could
// publish on it but not see its queue.
func TestMarketingMetaListAdminAndOwner(t *testing.T) {
	e := newMetaPubEnv(t)
	path := "/v1/marketing/posts?channel=" + e.page.ID
	for _, who := range []struct{ name, hum string }{{"admin, the connector", e.admin}, {"biz_owner", e.owner}} {
		if code, body := call(t, e.env, e.tid, http.MethodGet, path, who.hum, nil); code != http.StatusOK || !listsPost(body, "2026-10-30-hello") {
			t.Fatalf("%s GET %s: %d %v, want 200 with the posts", who.name, path, code, body)
		}
	}
	for _, role := range []string{rbac.Developer, rbac.Tester, rbac.RegularUser, rbac.ProductOwner} {
		who := seat(t, e.env, e.tid, role)
		if code, body := call(t, e.env, e.tid, http.MethodGet, path, who, nil); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
			t.Fatalf("%s GET %s: %d %v, want 403 naming tenant.settings", role, path, code, body)
		}
	}
}

func listsPost(body map[string]any, id string) bool {
	posts, _ := body["posts"].([]any)
	for _, p := range posts {
		if m, _ := p.(map[string]any); m["id"] == id {
			return true
		}
	}
	return false
}
