package marketing

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/gif"  // decode a blog picture in any web format
	_ "image/jpeg" // ...
	"image/png"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	_ "golang.org/x/image/webp" // the blog's pictures are WEBP; LinkedIn takes PNG
)

// blog.go reads the live blog the WUI serves (spec 111): the index the
// build writes to <app>/blog-md/index.json, a post's public page
// <app>/blog/<id> and its picture <app>/blog/img/<image>. What is in the
// LIVE index is what counts as published: a post the cap holds back, or a
// draft, is not in it (SPL-1634).

// BlogPost is one English post of the live index.
type BlogPost struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Summary string `json:"summary"`
	Image   string `json:"image"`
}

// maxPicture bounds a blog picture download (LinkedIn's own limit is far above).
const maxPicture = 8 << 20

var blogIDRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*$`)

// FetchBlogIndex reads the live index's English posts, newest first. A post
// whose id is not a blog id is dropped.
func FetchBlogIndex(ctx context.Context, c *http.Client, appURL string) ([]BlogPost, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(appURL, "/")+"/blog-md/index.json", nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("blog index: HTTP %d", resp.StatusCode)
	}
	var idx struct {
		Locales map[string][]BlogPost `json:"locales"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&idx); err != nil {
		return nil, fmt.Errorf("blog index: %w", err)
	}
	en, ok := idx.Locales["en"]
	if !ok {
		return nil, errors.New("blog index: no en locale")
	}
	out := make([]BlogPost, 0, len(en))
	for _, p := range en {
		if blogIDRe.MatchString(p.ID) && strings.TrimSpace(p.Title) != "" {
			out = append(out, p)
		}
	}
	return out, nil
}

// BlogPostURL is the post's public page.
func BlogPostURL(appURL, id string) string {
	return strings.TrimRight(appURL, "/") + "/blog/" + url.PathEscape(id)
}

// FetchBlogPicture downloads p's picture and re-encodes it as PNG; nil and
// no error when the post has none.
func FetchBlogPicture(ctx context.Context, c *http.Client, appURL string, p BlogPost) ([]byte, error) {
	if p.Image == "" || strings.ContainsAny(p.Image, "/\\") {
		return nil, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(appURL, "/")+"/blog/img/"+url.PathEscape(p.Image), nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("blog picture: HTTP %d", resp.StatusCode)
	}
	img, _, err := image.Decode(io.LimitReader(resp.Body, maxPicture))
	if err != nil {
		return nil, fmt.Errorf("blog picture: %w", err)
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

// The emojis that lead the commentary's three lines (SPL-1855; owner
// HUM-10, topic f46301d4 msg 8c3e0a83: "add some emojis on the LinkedIn
// post as well"). None is a little-text reserved character, so
// EscapeLittleText passes them through unchanged.
const (
	emojiTitle   = "\U0001F4DD " // memo
	emojiSummary = "\U0001F4A1 " // light bulb
	emojiLink    = "\U0001F449 " // pointing right
)

// BlogArticle is the share of p: its title and summary above the card, and
// the card linking to the post, each line led by an emoji. English, no
// generated text.
func BlogArticle(appURL string, p BlogPost, picture []byte) Article {
	link := BlogPostURL(appURL, p.ID)
	return Article{
		Commentary: emojiTitle + strings.TrimSpace(p.Title) + "\n\n" + emojiSummary + strings.TrimSpace(p.Summary) +
			"\n\n" + emojiLink + link,
		URL:         link,
		Title:       strings.TrimSpace(p.Title),
		Description: strings.TrimSpace(p.Summary),
		Picture:     picture,
	}
}
