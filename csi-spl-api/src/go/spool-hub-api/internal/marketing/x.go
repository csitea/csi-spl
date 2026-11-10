package marketing

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// x.go is the X (x.com) side of a marketing channel (spec 090 §3 X row,
// SPL-5194): connect with OAuth 2.0 authorization code + PKCE, refresh the
// two-hour access token, read the member, and create one post. Checked
// against docs.x.com on 2026-11-10 (x-app-setup.md): authorize at
// x.com/i/oauth2/authorize, token at api.x.com/2/oauth2/token with HTTP
// Basic client auth, POST /2/tweets answers 201 {data: {id, text}}.
//
// PKCE without server state: the code verifier is an HMAC of the signed
// connect state, keyed from the client secret. The callback gets the state
// back, so any hub instance derives the same verifier, and nobody without
// the secret can.

// XScopes are the scopes the connect asks for: post, read the member, and
// offline.access for a refresh token.
const XScopes = "tweet.read tweet.write users.read offline.access"

// The X hosts; X's fields point them at a fake in tests.
const (
	XAuthBase = "https://x.com"
	XAPIBase  = "https://api.x.com"
)

// X post length: 280 weighted characters, a link counts 23 (t.co), a
// character outside the light ranges counts 2.
const (
	XPostMaxWeight = 280
	XURLWeight     = 23
)

// ErrXUnknownOutcome is a failure after the post request went out with no
// answer back: X may have made the post, so the hub never retries it.
var ErrXUnknownOutcome = errors.New("x: the request was sent but no answer came back; the outcome is unknown")

// ErrXTooLong is a post text over XPostMaxWeight; nothing was sent.
var ErrXTooLong = errors.New("x: the post text is over 280 weighted characters")

// X is the X app client. ClientSecret is a Plaintext so it never prints.
type X struct {
	ClientID     string
	ClientSecret Plaintext
	RedirectURI  string
	AuthBase     string
	APIBase      string
	HTTP         *http.Client
}

// XToken is a member's token pair: the access token (two hours), the refresh
// token (offline.access) and when the access token ends.
type XToken struct {
	Access    Plaintext
	Refresh   Plaintext
	ExpiresAt time.Time
}

// XUser is the member behind a token (GET /2/users/me).
type XUser struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Username string `json:"username"`
}

// XError is a non-2xx X answer: the status, X's own message and, on a 429,
// how long until the limit resets. Never a request header, so never a token.
type XError struct {
	Status     int
	Message    string
	RetryAfter time.Duration
}

// Error implements error.
func (e *XError) Error() string { return fmt.Sprintf("x: HTTP %d: %s", e.Status, e.Message) }

func (x *X) client() *http.Client {
	if x.HTTP != nil {
		return x.HTTP
	}
	return &http.Client{Timeout: 20 * time.Second}
}

func (x *X) authBase() string { return orDefault(x.AuthBase, XAuthBase) }
func (x *X) apiBase() string  { return orDefault(x.APIBase, XAPIBase) }

func (x *X) stateKey() []byte { return stateKey(x.ClientSecret, "spool-marketing-x-connect-state/v1") }

// NewState signs st (a fresh nonce is added).
func (x *X) NewState(st State) string { return signState(x.stateKey(), st) }

// VerifyState checks s's MAC and expiry at now and returns what it binds.
func (x *X) VerifyState(s string, now time.Time) (State, error) {
	return verifyState(x.stateKey(), s, now)
}

// Verifier is the PKCE code verifier of the connect state s: 43 base64url
// characters (RFC 7636 4.1), the same on every hub instance.
func (x *X) Verifier(s string) string {
	m := hmac.New(sha256.New, stateKey(x.ClientSecret, "spool-marketing-x-pkce/v1"))
	m.Write([]byte(s))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// Challenge is the S256 code challenge of verifier.
func Challenge(verifier string) string {
	h := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(h[:])
}

// AuthorizeURL is where the member's browser goes to approve the app.
func (x *X) AuthorizeURL(state string) string {
	q := url.Values{
		"response_type":         {"code"},
		"client_id":             {x.ClientID},
		"redirect_uri":          {x.RedirectURI},
		"scope":                 {XScopes},
		"state":                 {state},
		"code_challenge":        {Challenge(x.Verifier(state))},
		"code_challenge_method": {"S256"},
	}
	return x.authBase() + "/i/oauth2/authorize?" + q.Encode()
}

// Exchange trades the authorization code of connect state for a token pair.
func (x *X) Exchange(ctx context.Context, code, state string, now time.Time) (XToken, error) {
	return x.token(ctx, url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {x.RedirectURI},
		"code_verifier": {x.Verifier(state)},
	}, now, "x token exchange")
}

// Refresh trades the refresh token for a new pair. X may rotate the refresh
// token: when the answer carries none, the old one stays.
func (x *X) Refresh(ctx context.Context, refresh Plaintext, now time.Time) (XToken, error) {
	tok, err := x.token(ctx, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh.Reveal()}}, now, "x token refresh")
	if err == nil && tok.Refresh.Reveal() == "" {
		tok.Refresh = refresh
	}
	return tok, err
}

func (x *X) token(ctx context.Context, form url.Values, now time.Time, what string) (XToken, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, x.apiBase()+"/2/oauth2/token", strings.NewReader(form.Encode()))
	if err != nil {
		return XToken{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetBasicAuth(x.ClientID, x.ClientSecret.Reveal())
	var body struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
	}
	if err := x.doJSON(req, &body); err != nil {
		return XToken{}, fmt.Errorf("%s: %w", what, err)
	}
	if body.AccessToken == "" || body.ExpiresIn <= 0 {
		return XToken{}, errors.New(what + ": no token in the answer")
	}
	return XToken{Access: NewPlaintext(body.AccessToken), Refresh: NewPlaintext(body.RefreshToken),
		ExpiresAt: now.Add(time.Duration(body.ExpiresIn) * time.Second)}, nil
}

// Me reads the member behind tok.
func (x *X) Me(ctx context.Context, tok Plaintext) (XUser, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, x.apiBase()+"/2/users/me", nil)
	if err != nil {
		return XUser{}, err
	}
	req.Header.Set("Authorization", "Bearer "+tok.Reveal())
	var body struct {
		Data XUser `json:"data"`
	}
	if err := x.doJSON(req, &body); err != nil {
		return XUser{}, fmt.Errorf("x users/me: %w", err)
	}
	if body.Data.ID == "" {
		return XUser{}, errors.New("x users/me: no user id")
	}
	return body.Data, nil
}

// Post creates one post with text and returns its id. Over the length limit
// it is refused before X is called. A failure after the request went out is
// ErrXUnknownOutcome (never retried).
func (x *X) Post(ctx context.Context, tok Plaintext, text string) (string, error) {
	if XWeightedLength(text) > XPostMaxWeight {
		return "", ErrXTooLong
	}
	b, err := json.Marshal(map[string]string{"text": text})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, x.apiBase()+"/2/tweets", bytes.NewReader(b))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+tok.Reveal())
	req.Header.Set("Content-Type", "application/json")
	resp, err := x.client().Do(req)
	if err != nil {
		if dialFailed(err) {
			return "", err
		}
		return "", fmt.Errorf("%w (%s)", ErrXUnknownOutcome, err.Error())
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		return "", xError(resp, rb)
	}
	var out struct {
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if json.Unmarshal(rb, &out) != nil || out.Data.ID == "" {
		return "", fmt.Errorf("%w (no post id in the answer)", ErrXUnknownOutcome)
	}
	return out.Data.ID, nil
}

func dialFailed(err error) bool {
	var oe *net.OpError
	return errors.As(err, &oe) && oe.Op == "dial"
}

// XRetryable: X refused before doing the work (429, 503), or the connection
// failed before anything was sent. Any other 5xx may come after the post was
// made, so it is not retried.
func XRetryable(err error) bool {
	var xe *XError
	if errors.As(err, &xe) {
		return xe.Status == http.StatusTooManyRequests || xe.Status == http.StatusServiceUnavailable
	}
	return dialFailed(err)
}

// XTokenRefused: X no longer accepts the token pair (a 401, or a token
// call answered 400 with an invalid token or grant): connect again.
func XTokenRefused(err error) bool {
	var xe *XError
	if !errors.As(err, &xe) {
		return false
	}
	return xe.Status == http.StatusUnauthorized ||
		(xe.Status == http.StatusBadRequest && strings.Contains(strings.ToLower(xe.Message), "invalid"))
}

func (x *X) doJSON(req *http.Request, out any) error {
	resp, err := x.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		return xError(resp, b)
	}
	return json.Unmarshal(b, out)
}

// xError keeps only X's message fields, cut short, and on a 429 the reset.
func xError(resp *http.Response, body []byte) *XError {
	var e struct {
		Detail           string `json:"detail"`
		Title            string `json:"title"`
		Error            string `json:"error"`
		ErrorDescription string `json:"error_description"`
		Errors           []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	_ = json.Unmarshal(body, &e)
	msg := strings.TrimPrefix(strings.Join(nonEmpty(e.Error, e.ErrorDescription), ": "), ": ")
	for _, m := range []string{e.Detail, e.Title} {
		if msg == "" {
			msg = m
		}
	}
	if msg == "" && len(e.Errors) > 0 {
		msg = e.Errors[0].Message
	}
	if len(msg) > 200 {
		msg = msg[:200]
	}
	xe := &XError{Status: resp.StatusCode, Message: msg}
	if resp.StatusCode == http.StatusTooManyRequests {
		if reset, err := strconv.ParseInt(resp.Header.Get("x-rate-limit-reset"), 10, 64); err == nil {
			xe.RetryAfter = max(time.Until(time.Unix(reset, 0)), 0)
		}
	}
	return xe
}

func nonEmpty(ss ...string) []string {
	out := []string{}
	for _, s := range ss {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

// Bundle is the token pair as one Plaintext, sealed into one channel token.
func (t XToken) Bundle() Plaintext {
	b, _ := json.Marshal(map[string]any{"a": t.Access.Reveal(), "r": t.Refresh.Reveal(), "e": t.ExpiresAt.Unix()}) //nolint:errchkjson // strings and an int
	return NewPlaintext(string(b))
}

// ParseXToken reads a Bundle back.
func ParseXToken(p Plaintext) (XToken, error) {
	var b struct {
		A string `json:"a"`
		R string `json:"r"`
		E int64  `json:"e"`
	}
	if err := json.Unmarshal([]byte(p.Reveal()), &b); err != nil || b.A == "" {
		return XToken{}, errors.New("x: the sealed token is not a token pair")
	}
	return XToken{Access: NewPlaintext(b.A), Refresh: NewPlaintext(b.R), ExpiresAt: time.Unix(b.E, 0)}, nil
}

// xLightRanges weigh 1; every other character weighs 2 (X's counting).
var xLightRanges = [][2]rune{{0, 4351}, {8192, 8205}, {8208, 8223}, {8242, 8247}}

func xRuneWeight(r rune) int {
	for _, lr := range xLightRanges {
		if r >= lr[0] && r <= lr[1] {
			return 1
		}
	}
	return 2
}

// XWeightedLength is text's length as X counts it: a whitespace-separated
// http(s) link is XURLWeight, a character outside the light ranges 2. An
// emoji sequence counts at least what X counts, never less.
func XWeightedLength(text string) int {
	n, i := 0, 0
	for i < len(text) {
		if strings.HasPrefix(text[i:], "https://") || strings.HasPrefix(text[i:], "http://") {
			end := strings.IndexAny(text[i:], " \t\n\r")
			if end < 0 {
				end = len(text) - i
			}
			n += XURLWeight
			i += end
			continue
		}
		r, size := utf8.DecodeRuneInString(text[i:])
		n += xRuneWeight(r)
		i += size
	}
	return n
}

// XPostText is the post for blog post p: the title, the summary, the link.
// The summary is shortened to fit XPostMaxWeight, and with no room left for
// it, the title. The link is never cut.
func XPostText(appURL string, p BlogPost) string {
	head, tail := strings.TrimSpace(p.Title), "\n\n"+BlogPostURL(appURL, p.ID)
	summary := strings.TrimSpace(p.Summary)
	if summary != "" {
		summary = "\n\n" + summary
	}
	if XWeightedLength(head+summary+tail) <= XPostMaxWeight {
		return head + summary + tail
	}
	if s := xFit(summary, XPostMaxWeight-XWeightedLength(head+tail)-xEllipsisWeight); s != "" {
		return head + s + "…" + tail
	}
	if XWeightedLength(head+tail) > XPostMaxWeight {
		return xFit(head, XPostMaxWeight-XWeightedLength(tail)-xEllipsisWeight) + "…" + tail
	}
	return head + "…" + tail
}

// xEllipsisWeight is what the "…" a shortened text ends with weighs (2).
var xEllipsisWeight = xRuneWeight('…')

// xFit is the longest prefix of s that weighs at most room, trailing space
// cut ("" when nothing but space fits).
func xFit(s string, room int) string {
	n, cut := 0, 0
	for i, r := range s {
		if n+xRuneWeight(r) > room {
			break
		}
		n += xRuneWeight(r)
		cut = i + utf8.RuneLen(r)
	}
	out := strings.TrimRight(s[:cut], " \t\n")
	if strings.TrimSpace(out) == "" {
		return ""
	}
	return out
}
