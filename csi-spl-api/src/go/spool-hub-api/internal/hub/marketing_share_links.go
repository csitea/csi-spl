package hub

import (
	"net/http"
	"net/url"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// One-click share links for a live blog post (spec 090 T037, SPL-3872;
// owner HUM-10, topics 44a37f81 msg 58967cd0 and 665401a9 msg bd55650a):
// GET /v1/marketing/posts/{id}/share-links. The hub posts nothing: it
// returns the URLs a member opens by hand.
//
//   - Facebook: the sharer with `u` only; `quote` is deprecated and ignored.
//   - Viber: viber://forward?text=, the headline and the link in at most
//     viberMaxText characters, the headline shortened, the link kept whole.
//   - WhatsApp: https://wa.me/?text=, the headline and the link.
//   - Instagram has no web intent: the caption to copy and the pictures to
//     download, plus the page to open.
//
// Every value is percent-encoded the way the WUI's
// src/utils/marketing-share-links.mjs encodes it (RFC 3986, a space is %20),
// so the hub and the public blog row build the same links.

// viberMaxText is the Viber client's limit on a forwarded text.
const viberMaxText = 200

const instagramOpen = "https://www.instagram.com/"

// MarketingInstagramPack is Instagram's manual hand-over.
type MarketingInstagramPack struct {
	Caption string   `json:"caption"`
	Images  []string `json:"images"`
	Open    string   `json:"open"`
}

// MarketingShareLinks is the share-links answer for one post.
type MarketingShareLinks struct {
	PostID    string                 `json:"post_id"`
	URL       string                 `json:"url"`
	Facebook  string                 `json:"facebook"`
	Viber     string                 `json:"viber"`
	WhatsApp  string                 `json:"whatsapp"`
	Instagram MarketingInstagramPack `json:"instagram"`
}

// shareEscape is JavaScript's encodeURIComponent plus !'()*: every byte but
// A-Z a-z 0-9 - . _ ~ is %XX, a space included.
func shareEscape(s string) string {
	return strings.ReplaceAll(url.QueryEscape(s), "+", "%20")
}

// viberText is "<headline> <link>" in at most viberMaxText characters: the
// headline is cut at a character and ends in an ellipsis, the link is never
// cut. A link longer than the limit on its own is returned alone.
func viberText(title, link string) string {
	title = strings.TrimSpace(title)
	if utf8.RuneCountInString(title)+1+utf8.RuneCountInString(link) <= viberMaxText {
		return title + " " + link
	}
	room := viberMaxText - utf8.RuneCountInString(link) - 2 // the ellipsis and the space
	if room <= 0 {
		return link
	}
	return strings.TrimSpace(string([]rune(title)[:room])) + "… " + link
}

// BuildMarketingShareLinks is the four apps' links for p on the blog at appURL.
func BuildMarketingShareLinks(appURL string, p marketing.BlogPost) MarketingShareLinks {
	link := marketing.BlogPostURL(appURL, p.ID)
	title := strings.TrimSpace(p.Title)
	caption := title
	if s := strings.TrimSpace(p.Summary); s != "" {
		caption += "\n\n" + s
	}
	caption += "\n\n" + link
	images := []string{}
	if p.Image != "" && !strings.ContainsAny(p.Image, "/\\") {
		images = append(images, strings.TrimRight(appURL, "/")+"/blog/img/"+url.PathEscape(p.Image))
	}
	return MarketingShareLinks{
		PostID:    p.ID,
		URL:       link,
		Facebook:  "https://www.facebook.com/sharer/sharer.php?u=" + shareEscape(link),
		Viber:     "viber://forward?text=" + shareEscape(viberText(title, link)),
		WhatsApp:  "https://wa.me/?text=" + shareEscape(title+" "+link),
		Instagram: MarketingInstagramPack{Caption: caption, Images: images, Open: instagramOpen},
	}
}

// GET /v1/marketing/posts/{id}/share-links: any member of a workspace with
// marketing on (marketingRoute); a post not in the live index is 404.
func (s *Server) handleMarketingShareLinks(w http.ResponseWriter, r *http.Request, tenant string) {
	w.Header().Set("Cache-Control", "no-store")
	if hum, _ := s.memberID(r, tenant); hum == "" {
		writeForbidden(w, rbac.TopicsRead, "the share links need a member session")
		return
	}
	m := s.o.MarketingLinkedIn
	if m == nil || m.AppURL == "" {
		writeErr(w, http.StatusServiceUnavailable, "blog_off", "the blog is not configured on this hub")
		return
	}
	posts, err := marketing.FetchBlogIndex(r.Context(), m.httpClient(), m.AppURL)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "blog_index", "the live blog index is unavailable")
		return
	}
	bp, ok := blogByID(posts)[r.PathValue("id")]
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", ErrMarketingNoPost.Error())
		return
	}
	writeJSON(w, http.StatusOK, BuildMarketingShareLinks(m.AppURL, bp))
}
