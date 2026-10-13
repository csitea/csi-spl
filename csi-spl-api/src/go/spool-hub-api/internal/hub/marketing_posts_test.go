package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-1698: the owner's list of unshared live blog posts, the WUI's source
// for its Publish to LinkedIn buttons. Same gate as the publish: only the
// workspace owner; a published or baselined post drops out of the list.
func TestMarketingPostsListsOnlyUnsharedForTheOwner(t *testing.T) {
	e := newShareEnv(t)
	// before the first sweep the channel has no baseline: the back catalogue is not offered
	if code, body := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts", e.owner, nil); code != http.StatusOK || len(body["posts"].([]any)) != 0 {
		t.Fatalf("owner GET before the baseline: %d %v, want 200 and no posts", code, body)
	}
	e.sweep()
	e.newPostWaits(t, "2026-10-13-list")
	dev, agent := seat(t, e.env, e.tid, rbac.Developer), seat(t, e.env, e.tid, rbac.PureAgent)
	for _, who := range []string{e.admin, dev, agent, "", "AGT-1"} {
		if _, err := e.srv.UnsharedMarketingPosts(context.Background(), e.tid, who); !errors.Is(err, hub.ErrMarketingNotOwner) {
			t.Fatalf("list as %q: %v, want ErrMarketingNotOwner", who, err)
		}
	}
	if code, body := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts", e.admin, nil); code != http.StatusForbidden {
		t.Fatalf("admin GET: %d %v, want 403", code, body)
	}
	// CONTROL: the owner sees exactly the new post, not the two baselined ones
	code, body := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts", e.owner, nil)
	posts, _ := body["posts"].([]any)
	if code != http.StatusOK || len(posts) != 1 || posts[0].(map[string]any)["id"] != "2026-10-13-list" {
		t.Fatalf("owner GET: %d %v, want 200 and only 2026-10-13-list", code, body)
	}
	e.ownerPublish(t, "2026-10-13-list")
	if code, body := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts", e.owner, nil); code != http.StatusOK || len(body["posts"].([]any)) != 0 {
		t.Fatalf("owner GET after the publish: %d %v, want 200 and no posts", code, body)
	}
	if n := e.fake.shareCount(); n != 1 {
		t.Fatalf("the list reached LinkedIn: %d shares, want the publish's one", n)
	}
}
