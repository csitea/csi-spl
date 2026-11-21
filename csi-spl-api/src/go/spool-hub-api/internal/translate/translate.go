// Package translate is the hub's Google Cloud Translation v3 client (spec 123
// section 16.6.3, row L3; owner HUM-10, csitea 720fa031, msg baae5fb7,
// follow-up answer 3: "G — Google Cloud Translation, in our own GCP
// project"). It calls translateText (REST) in the env's own project as the
// hub's runtime service account: the token is Cloud Run's metadata server
// token, no key file. The base URL is the hub's cnf
// (SPOOL_HUB_COST_LABELS_TRANSLATE_URL, no default host); a daily character
// cap stops the calls for the UTC day once reached.
//
// The text goes as text/html with each mask token in a no-translate span
// (16.6.5): Wrap builds it, Unwrap takes the answer back to plain text.
// Measured on dev 2026-11-21, n = 20 texts x 18 locales: the span came back
// intact 360 of 360 (testdata/measurement-dev-2026-11-21.md).
package translate

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"cloud.google.com/go/compute/metadata"
)

// ErrDailyCap is a call refused because the day's characters are spent.
var ErrDailyCap = errors.New("translate: the daily character cap is reached")

// TokenSource is an OAuth access token for the API.
type TokenSource func(ctx context.Context) (string, error)

// Client calls translateText. Its zero cap is no cap.
type Client struct {
	// URL is the parent's REST base, ending in .../v3/projects/<p>/locations/<l>.
	URL        string
	Token      TokenSource
	HTTP       *http.Client
	DailyChars int
	Now        func() time.Time

	mu   sync.Mutex
	day  string
	used int
}

// answerMax bounds one answer's body.
const answerMax = 64 << 10

// Reserve takes n characters of today's cap; false = the cap would be passed
// and nothing is taken. The cap counts what is sent, per UTC day, in this
// process.
func (c *Client) Reserve(n int) bool {
	if c.DailyChars <= 0 {
		return true
	}
	now := time.Now
	if c.Now != nil {
		now = c.Now
	}
	day := now().UTC().Format(time.DateOnly)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.day != day {
		c.day, c.used = day, 0
	}
	if c.used+n > c.DailyChars {
		return false
	}
	c.used += n
	return true
}

// Translate is content (text/html) in target, from source.
func (c *Client) Translate(ctx context.Context, content, source, target string) (string, error) {
	tok, err := c.Token(ctx)
	if err != nil {
		return "", fmt.Errorf("translate: token: %w", err)
	}
	body, _ := json.Marshal(map[string]any{
		"contents": []string{content}, "mimeType": "text/html",
		"sourceLanguageCode": source, "targetLanguageCode": target,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.URL, "/")+":translateText", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	hc := c.HTTP
	if hc == nil {
		hc = http.DefaultClient
	}
	resp, err := hc.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, answerMax))
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("translate: %s answered %d", target, resp.StatusCode)
	}
	var out struct {
		Translations []struct {
			TranslatedText string `json:"translatedText"`
		} `json:"translations"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Translations) != 1 {
		return "", fmt.Errorf("translate: %s answered no translation", target)
	}
	return out.Translations[0].TranslatedText, nil
}

// tokenRe is a mask token; spanRe one in its no-translate span, as the API
// gives it back.
var (
	tokenRe = regexp.MustCompile(`\[(?:EMAIL|PHONE|NAME|WORKSPACE|OTHER)_[0-9]+\]`)
	spanRe  = regexp.MustCompile(`<span translate="no">\s*(\[(?:EMAIL|PHONE|NAME|WORKSPACE|OTHER)_[0-9]+\])\s*</span>`)
)

// Wrap is a masked text as the API's text/html: escaped, each token in a
// no-translate span.
func Wrap(masked string) string {
	return tokenRe.ReplaceAllString(html.EscapeString(masked), `<span translate="no">$0</span>`)
}

// Unwrap is an answer back to plain text: each span its token, then
// unescaped. A span the API changed is left in, for the caller's check.
func Unwrap(answer string) string {
	return html.UnescapeString(spanRe.ReplaceAllString(answer, "$1"))
}

// MetadataToken is the runtime service account's token from the metadata
// server, kept until a minute before it expires.
func MetadataToken() TokenSource {
	var (
		mu  sync.Mutex
		tok string
		exp time.Time
	)
	return func(ctx context.Context) (string, error) {
		mu.Lock()
		defer mu.Unlock()
		if tok != "" && time.Now().Before(exp) {
			return tok, nil
		}
		raw, err := metadata.GetWithContext(ctx, "instance/service-accounts/default/token")
		if err != nil {
			return "", err
		}
		var t struct {
			AccessToken string `json:"access_token"`
			ExpiresIn   int    `json:"expires_in"`
		}
		if err := json.Unmarshal([]byte(raw), &t); err != nil || t.AccessToken == "" {
			return "", errors.New("translate: the metadata server answered no token")
		}
		tok, exp = t.AccessToken, time.Now().Add(time.Duration(t.ExpiresIn)*time.Second-time.Minute)
		return tok, nil
	}
}
