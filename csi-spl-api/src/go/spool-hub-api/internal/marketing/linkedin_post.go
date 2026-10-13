package marketing

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
)

// linkedin_post.go shares one article on the member's own feed through the
// LinkedIn Posts API (spec 090 T009, SPL-1634): POST /rest/posts as
// urn:li:person:<sub>, with an optional thumbnail uploaded through the
// Images API first. Scope w_member_social ("Share on LinkedIn").

// Article is what one share carries: the commentary above the card, and the
// card's link, title, description and optional picture (PNG, JPEG or GIF).
type Article struct {
	Commentary  string
	URL         string
	Title       string
	Description string
	Picture     []byte
}

// ErrUnknownOutcome is a failure after which LinkedIn may or may not have
// made the post (the connection broke once the request was sent). The hub
// never retries it, so a post is never shared twice.
var ErrUnknownOutcome = errors.New("linkedin: the request was sent but no answer came back; the outcome is unknown")

// Retryable reports whether err is safe to retry: LinkedIn said 429 or 503
// (refused before doing the work), or the connection failed before anything
// was sent. Any other 5xx may come after the post was made, so it is not
// retried: a post is never shared twice.
func Retryable(err error) bool {
	var he *HTTPError
	if errors.As(err, &he) {
		return he.Status == http.StatusTooManyRequests || he.Status == http.StatusServiceUnavailable
	}
	var oe *net.OpError
	return errors.As(err, &oe) && oe.Op == "dial"
}

// Unauthorized reports a 401: the token was revoked or has expired.
func Unauthorized(err error) bool {
	var he *HTTPError
	return errors.As(err, &he) && he.Status == http.StatusUnauthorized
}

// littleTextReserved are the characters LinkedIn's "little text" commentary
// format treats as markup; each is escaped with a backslash.
const littleTextReserved = `\|{}@[]()<>#*_~`

// EscapeLittleText escapes s for the Posts API commentary field.
func EscapeLittleText(s string) string {
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune(littleTextReserved, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func (l *LinkedIn) restRequest(ctx context.Context, method, path string, tok Plaintext, body any) (*http.Request, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, l.apiBase()+path, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+tok.Reveal())
	req.Header.Set("LinkedIn-Version", l.Version)
	req.Header.Set("X-Restli-Protocol-Version", "2.0.0")
	req.Header.Set("Content-Type", "application/json")
	return req, nil
}

// UploadImage puts pic on LinkedIn for the member and returns its image urn.
func (l *LinkedIn) UploadImage(ctx context.Context, tok Plaintext, memberSub string, pic []byte) (string, error) {
	req, err := l.restRequest(ctx, http.MethodPost, "/rest/images?action=initializeUpload", tok,
		map[string]any{"initializeUploadRequest": map[string]any{"owner": "urn:li:person:" + memberSub}})
	if err != nil {
		return "", err
	}
	var init struct {
		Value struct {
			UploadURL string `json:"uploadUrl"`
			Image     string `json:"image"`
		} `json:"value"`
	}
	if err := l.doJSON(req, &init); err != nil {
		return "", fmt.Errorf("linkedin image init: %w", err)
	}
	if init.Value.UploadURL == "" || init.Value.Image == "" {
		return "", errors.New("linkedin image init: no upload url")
	}
	put, err := http.NewRequestWithContext(ctx, http.MethodPut, init.Value.UploadURL, bytes.NewReader(pic))
	if err != nil {
		return "", err
	}
	put.Header.Set("Authorization", "Bearer "+tok.Reveal())
	if err := l.doJSON(put, nil); err != nil {
		return "", fmt.Errorf("linkedin image upload: %w", err)
	}
	return init.Value.Image, nil
}

// Share posts a on the member's feed and returns the post urn. A failure
// after the request went out is ErrUnknownOutcome (never retried).
func (l *LinkedIn) Share(ctx context.Context, tok Plaintext, memberSub string, a Article, thumbnail string) (string, error) {
	article := map[string]any{"source": a.URL, "title": a.Title, "description": a.Description}
	if thumbnail != "" {
		article["thumbnail"] = thumbnail
	}
	req, err := l.restRequest(ctx, http.MethodPost, "/rest/posts", tok, map[string]any{
		"author":     "urn:li:person:" + memberSub,
		"commentary": EscapeLittleText(a.Commentary),
		"visibility": "PUBLIC",
		"distribution": map[string]any{"feedDistribution": "MAIN_FEED", "targetEntities": []any{},
			"thirdPartyDistributionChannels": []any{}},
		"content":                   map[string]any{"article": article},
		"lifecycleState":            "PUBLISHED",
		"isReshareDisabledByAuthor": false,
	})
	if err != nil {
		return "", err
	}
	resp, err := l.client().Do(req)
	if err != nil {
		var oe *net.OpError
		if errors.As(err, &oe) && oe.Op == "dial" {
			return "", err
		}
		return "", fmt.Errorf("%w (%s)", ErrUnknownOutcome, err.Error())
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		return "", httpError(resp.StatusCode, b)
	}
	id := resp.Header.Get("X-Restli-Id")
	if id == "" {
		id = resp.Header.Get("X-LinkedIn-Id")
	}
	return id, nil
}
