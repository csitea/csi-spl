package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 090 T035 / SPL-4496: the hub routes the WUI's connected-accounts
// page needs. A channel is disconnected (DELETE, 204) with its sealed token
// and posts, a Facebook Page with its linked Instagram account; another
// workspace's channel is 404; a member without the settings right is 403.
// GET /v1/marketing/posts?channel= lists a Meta channel's unshared posts.
// Each route the WUI calls cross-origin answers its CORS preflight.

// mktChannel connects one channel straight in the store.
func mktChannel(t *testing.T, mk store.Marketing, tid, platform, ref, page string) store.MarketingChannel {
	t.Helper()
	ch, err := mk.ConnectMarketingChannel(context.Background(), store.MarketingChannel{Tenant: tid, Platform: platform,
		AccountRef: ref, AccountName: ref, DelegatedBy: "HUM-1", Metadata: map[string]any{"page_id": page}},
		store.MarketingToken{Ciphertext: "v1.sealed." + ref, KMSKeyID: "kms/key/1"}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	return ch
}

func TestMarketingChannelDisconnect(t *testing.T) {
	ids := mktIDs(2)
	a, b := ids[0], ids[1]
	e := mktEnvWith(t, ids, func(*hub.Options) {}, ids...)
	adminA, devA, adminB := seat(t, e, a, rbac.Admin), seat(t, e, a, rbac.Developer), seat(t, e, b, rbac.Admin)
	mktOn(t, e, a, adminA)
	mktOn(t, e, b, adminB)
	mk := e.st.(store.Marketing)
	li := mktChannel(t, mk, a, "linkedin", "member-1", "")
	page := mktChannel(t, mk, a, "facebook_page", "1001", "1001")
	ig := mktChannel(t, mk, a, "instagram_business", "17841", "1001")
	page2 := mktChannel(t, mk, a, "facebook_page", "2002", "2002")
	ig2 := mktChannel(t, mk, a, "instagram_business", "27841", "2002")
	if _, err := mk.ScheduleMarketingPost(context.Background(), store.MarketingPost{Tenant: a, ChannelID: page.ID,
		SourceType: store.MarketingSourceBlog, SourceRef: "2026-10-30-hello"}, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	del := func(as, tid, id string) int {
		code, _ := call(t, e, tid, http.MethodDelete, "/v1/marketing/channels/"+id, as, nil)
		return code
	}
	if code := del(adminB, b, page.ID); code != http.StatusNotFound {
		t.Fatalf("B deletes A's channel: %d, want 404", code)
	}
	if code := del(devA, a, page.ID); code != http.StatusForbidden {
		t.Fatalf("a developer deletes: %d, want 403", code)
	}
	for _, id := range []string{"00000000-0000-4000-8000-000000000000", "not-a-uuid"} {
		if code := del(adminA, a, id); code != http.StatusNotFound {
			t.Fatalf("delete %q: %d, want 404", id, code)
		}
	}
	if chs, _ := mk.MarketingChannels(context.Background(), a); len(chs) != 5 {
		t.Fatalf("a refused delete removed a channel: %d left, want 5", len(chs))
	}
	// an Instagram account alone: its Page stays
	if code := del(adminA, a, ig2.ID); code != http.StatusNoContent {
		t.Fatalf("delete Instagram: %d, want 204", code)
	}
	// the Page: its Instagram account goes with it, the other Page and LinkedIn stay
	if code := del(adminA, a, page.ID); code != http.StatusNoContent {
		t.Fatalf("delete Page: %d, want 204", code)
	}
	for _, ch := range []store.MarketingChannel{page, ig, ig2} {
		if _, err := mk.MarketingToken(context.Background(), a, ch.ID); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("%s %s token after the delete: %v, want ErrNotFound", ch.Platform, ch.AccountRef, err)
		}
	}
	if refs, _ := mk.MarketingPostRefs(context.Background(), a, page.ID); len(refs) != 0 {
		t.Fatalf("the Page's posts survived: %v", refs)
	}
	chs, _ := mk.MarketingChannels(context.Background(), a)
	left := []string{}
	for _, c := range chs {
		left = append(left, c.ID)
	}
	if len(chs) != 2 || !strings.Contains(strings.Join(left, ","), li.ID) || !strings.Contains(strings.Join(left, ","), page2.ID) {
		t.Fatalf("left %v, want LinkedIn %s and Page %s", left, li.ID, page2.ID)
	}
	if code := del(adminA, a, page.ID); code != http.StatusNotFound {
		t.Fatalf("second delete: %d, want 404", code)
	}
}

// GET /v1/marketing/posts?channel=: the live posts with no row on that
// Meta channel; the owner only; without channel= the LinkedIn list.
func TestMarketingMetaPostList(t *testing.T) {
	e := newMetaPubEnv(t)
	list := func(as string, ch string) (int, []string) {
		code, body := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts?channel="+ch, as, nil)
		var out []string
		posts, _ := body["posts"].([]any)
		for _, p := range posts {
			out = append(out, p.(map[string]any)["id"].(string))
		}
		return code, out
	}
	all := "2026-10-30-hello,2026-10-29-webp,2026-10-28-third"
	if code, ids := list(e.owner, e.page.ID); code != http.StatusOK || strings.Join(ids, ",") != all {
		t.Fatalf("Page list before a publish: %d %v, want 200 %s", code, ids, all)
	}
	if code, _ := e.publish(t, e.owner, "2026-10-30-hello", e.page); code != http.StatusOK {
		t.Fatalf("publish: %d", code)
	}
	if code, ids := list(e.owner, e.page.ID); code != http.StatusOK || strings.Join(ids, ",") != "2026-10-29-webp,2026-10-28-third" {
		t.Fatalf("Page list after the publish: %d %v, want the two unpublished", code, ids)
	}
	if code, ids := list(e.owner, e.ig.ID); code != http.StatusOK || strings.Join(ids, ",") != all {
		t.Fatalf("Instagram list: %d %v, want all three (no row on it)", code, ids)
	}
	if code, _ := list(e.admin, e.page.ID); code != http.StatusForbidden {
		t.Fatalf("admin list: %d, want 403", code)
	}
	if code, _ := list(e.owner, "00000000-0000-4000-8000-000000000000"); code != http.StatusNotFound {
		t.Fatalf("unknown channel: %d, want 404", code)
	}
	// without channel= the route is the LinkedIn list, unchanged: no LinkedIn app here
	if code, body := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts", e.owner, nil); code != http.StatusServiceUnavailable || body["error"] != "linkedin_off" {
		t.Fatalf("LinkedIn list: %d %v, want 503 linkedin_off", code, body)
	}
	if n, _, _ := e.fake.counts(); n != 1 {
		t.Fatalf("the list reached Meta: %d Page posts, want the publish's one", n)
	}
}

// Every marketing route the WUI's connected-accounts page calls answers its
// preflight with the WUI origin and the method.
func TestMarketingAccountsPreflights(t *testing.T) {
	tid := mktIDs(1)[0]
	e := mktEnvWith(t, []string{tid}, func(*hub.Options) {}, tid)
	for path, method := range map[string]string{
		"/v1/marketing/channels": "GET",
		"/v1/marketing/channels/00000000-0000-4000-8000-000000000000": "DELETE",
		"/v1/marketing/facebook/pages":                                "GET",
		"/v1/marketing/facebook/connect":                              "POST",
		"/v1/marketing/posts":                                         "GET",
	} {
		req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+path, nil)
		req.Header.Set("Origin", wuiOrigin)
		req.Header.Set("Access-Control-Request-Method", method)
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		h := resp.Header
		if resp.StatusCode != http.StatusNoContent || h.Get("Access-Control-Allow-Origin") != wuiOrigin ||
			!strings.Contains(h.Get("Access-Control-Allow-Methods"), method) || !strings.Contains(h.Get("Access-Control-Allow-Headers"), "Authorization") {
			t.Errorf("OPTIONS %s: %d %v, want 204 allowing %s from the WUI", path, resp.StatusCode, h, method)
		}
	}
}
