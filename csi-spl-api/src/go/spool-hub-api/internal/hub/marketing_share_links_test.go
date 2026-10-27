package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 090 T037 (SPL-3872): one-click share links for Facebook, Viber,
// WhatsApp and Instagram. The golden strings below are the same ones the
// WUI's tests/unit/marketing-share-links.test.mjs expects, so the hub and the
// public blog row cannot drift apart.

const (
	slApp   = "https://blog.example.com"
	slID    = "2026-10-26-kids-human-experience"
	slLink  = slApp + "/blog/" + slID
	slTitle = "Лагер 🏕️ & деца (2027)!" // Cyrillic, an emoji with a variation selector, & ( ) !
	slText  = "%D0%9B%D0%B0%D0%B3%D0%B5%D1%80%20%F0%9F%8F%95%EF%B8%8F%20%26%20%D0%B4%D0%B5%D1%86%D0%B0%20%282027%29%21%20https%3A%2F%2Fblog.example.com%2Fblog%2F2026-10-26-kids-human-experience"
)

// encodedOK reports why a share URL is not safely percent-encoded: a raw
// space, a raw non-ASCII byte, or a query that does not parse.
func encodedOK(raw string) string {
	for i := 0; i < len(raw); i++ {
		if c := raw[i]; c <= ' ' || c >= 0x7f {
			return "raw byte " + string(rune(c)) + " in " + raw
		}
	}
	u, err := url.Parse(raw)
	if err != nil {
		return err.Error()
	}
	if _, err := url.ParseQuery(u.RawQuery); err != nil {
		return err.Error()
	}
	return ""
}

func TestMarketingShareLinksEncoding(t *testing.T) {
	l := hub.BuildMarketingShareLinks(slApp+"/", marketing.BlogPost{ID: slID, Title: slTitle, Summary: "Летен лагер 2027.", Image: slID + ".webp"})
	want := map[string]string{
		"facebook": "https://www.facebook.com/sharer/sharer.php?u=https%3A%2F%2Fblog.example.com%2Fblog%2F2026-10-26-kids-human-experience",
		"whatsapp": "https://wa.me/?text=" + slText,
		"viber":    "viber://forward?text=" + slText,
	}
	got := map[string]string{"facebook": l.Facebook, "whatsapp": l.WhatsApp, "viber": l.Viber}
	for app, w := range want {
		if got[app] != w {
			t.Errorf("%s:\n got %s\nwant %s", app, got[app], w)
		}
		if why := encodedOK(got[app]); why != "" {
			t.Errorf("%s not encoded: %s", app, why)
		}
	}
	if strings.Contains(l.Facebook, "quote=") || strings.Count(l.Facebook, "=") != 1 {
		t.Errorf("facebook carries a parameter beyond u: %s", l.Facebook)
	}
	if l.URL != slLink || l.PostID != slID {
		t.Errorf("url %q post %q", l.URL, l.PostID)
	}
	ig := l.Instagram
	if ig.Caption != slTitle+"\n\nЛетен лагер 2027.\n\n"+slLink || ig.Open != "https://www.instagram.com/" ||
		len(ig.Images) != 1 || ig.Images[0] != slApp+"/blog/img/"+slID+".webp" {
		t.Errorf("instagram pack %+v", ig)
	}
	// CONTROL: the validator refuses raw Unicode and a raw space.
	for _, bad := range []string{"https://wa.me/?text=" + slTitle, "viber://forward?text=a b"} {
		if encodedOK(bad) == "" {
			t.Errorf("CONTROL: encodedOK passed the unencoded %q", bad)
		}
	}
}

// viberDecoded is the text a Viber link prefills.
func viberDecoded(t *testing.T, link string) string {
	t.Helper()
	u, err := url.Parse(link)
	if err != nil || u.Scheme != "viber" || u.Host != "forward" {
		t.Fatalf("viber link %q: %v", link, err)
	}
	return u.Query().Get("text")
}

func TestMarketingShareLinksViberClamp(t *testing.T) {
	long := strings.Repeat("Лагер 🏕️ за деца ", 20) // 360 characters
	l := hub.BuildMarketingShareLinks(slApp, marketing.BlogPost{ID: slID, Title: long})
	txt := viberDecoded(t, l.Viber)
	if n := utf8.RuneCountInString(txt); n > 200 {
		t.Fatalf("viber text is %d characters, want <= 200: %q", n, txt)
	}
	if !strings.HasSuffix(txt, "… "+slLink) || !strings.HasPrefix(txt, "Лагер 🏕️ за деца") {
		t.Fatalf("viber text lost its headline or its link: %q", txt)
	}
	if !utf8.ValidString(txt) {
		t.Fatalf("viber text cut a character: %q", txt)
	}
	// WhatsApp has no such limit: the whole headline is kept.
	if wa, _ := url.Parse(l.WhatsApp); wa.Query().Get("text") != strings.TrimSpace(long)+" "+slLink {
		t.Fatalf("whatsapp text clamped: %q", wa.Query().Get("text"))
	}
	// CONTROL: unclamped, the same post is over the limit.
	if n := utf8.RuneCountInString(strings.TrimSpace(long) + " " + slLink); n <= 200 {
		t.Fatalf("CONTROL: the long title is only %d characters with its link", n)
	}
	// A short headline is passed whole.
	if txt := viberDecoded(t, hub.BuildMarketingShareLinks(slApp, marketing.BlogPost{ID: slID, Title: slTitle}).Viber); txt != slTitle+" "+slLink {
		t.Fatalf("short viber text %q", txt)
	}
}

// The route: any member of a workspace with marketing on; nobody else.
func TestMarketingShareLinksRoute(t *testing.T) {
	e := newShareEnv(t)
	e.publish(slID)
	dev := seat(t, e.env, e.tid, rbac.Developer)
	path := "/v1/marketing/posts/" + slID + "/share-links"
	code, body := call(t, e.env, e.tid, http.MethodGet, path, dev, nil)
	if code != http.StatusOK || body["post_id"] != slID || body["url"] != e.fake.URL+"/blog/"+slID {
		t.Fatalf("member GET: %d %v", code, body)
	}
	if fb, _ := body["facebook"].(string); fb != "https://www.facebook.com/sharer/sharer.php?u="+url.QueryEscape(e.fake.URL+"/blog/"+slID) {
		t.Fatalf("facebook %q", fb)
	}
	if ig, _ := body["instagram"].(map[string]any); ig == nil || ig["open"] != "https://www.instagram.com/" {
		t.Fatalf("instagram %v", body["instagram"])
	}
	if code, body := call(t, e.env, e.tid, http.MethodGet, "/v1/marketing/posts/2026-01-01-nope/share-links", dev, nil); code != http.StatusNotFound {
		t.Fatalf("unknown post: %d %v, want 404", code, body)
	}
	// CONTROL: no member session, and a member of another workspace, get nothing.
	if code, body := call(t, e.env, e.tid, http.MethodGet, path, "", nil); code == http.StatusOK {
		t.Fatalf("CONTROL: anonymous GET: %d %v", code, body)
	}
	other := mktIDs(1)[0]
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: other, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	stranger := seat(t, e.env, other, rbac.Admin)
	if code, body := call(t, e.env, e.tid, http.MethodGet, path, stranger, nil); code == http.StatusOK || body["post_id"] != nil {
		t.Fatalf("CONTROL: another workspace's admin GET: %d %v", code, body)
	}
	// CONTROL: marketing switched off, the route is 404 like every marketing route.
	if code, _ := call(t, e.env, e.tid, http.MethodPatch, "/v1/marketing/settings", e.admin, map[string]any{"enabled": false}); code != http.StatusOK {
		t.Fatalf("turn off: %d", code)
	}
	if code, _ := call(t, e.env, e.tid, http.MethodGet, path, dev, nil); code != http.StatusNotFound {
		t.Fatalf("CONTROL: marketing off: %d, want 404", code)
	}
}
