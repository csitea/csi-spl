package marketing

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// meta_client.go is the Meta Graph API client for Facebook Pages and
// Instagram Professional accounts (spec 090 T032, SPL-3875; spec.md §16,
// §21): the token exchange, the Page list, a Page post and the Instagram
// container -> poll -> publish flow. It is not wired to a route yet (T033,
// T034). It uses the existing sign-in Meta app (spec 049): the owner adds the
// Page + Instagram products and permissions to that app (meta-app-setup.md,
// T030); until then it is tested only against an httptest fake.
//
// Tokens: every token-bearing call sends the token in the Authorization
// header (never in a URL) with appsecret_proof, and the app secret goes in a
// POST form. A transport error is re-wrapped without its URL, so no error
// string ever carries a token or the secret.
//
// Retries: a call that is safe to repeat (a read, a token extension, an
// Instagram container, which expires unpublished after 24 h) is retried on a
// transient failure with exponential backoff. A call that makes something
// public (a Page post, media_publish) or spends a one-time code is retried
// only when the connection failed before anything was sent; a failure after
// the request went out is ErrMetaUnknownOutcome, so a post is never made twice.
// A rate limit is never retried here: the dispatcher reschedules (T034).

// MetaGraphBase is Meta's Graph API host; Meta.GraphBase points it at a fake in tests.
const MetaGraphBase = "https://graph.facebook.com"

// MetaDefaultVersion is the Graph API version when cnf names none
// (marketing.facebook.api_version, spec.md §16.1).
const MetaDefaultVersion = "v26.0"

// metaDefaultLongLivedTTL is assumed when Meta's exchange answer carries no
// expires_in: a long-lived user token lives about 60 days (spec.md §16.1.1).
const metaDefaultLongLivedTTL = 60 * 24 * time.Hour

var metaVersionRx = regexp.MustCompile(`^v[0-9]+\.[0-9]+$`)

// ErrMetaUnknownOutcome is a failure after which Meta may or may not have made
// the post (the connection broke once the request was sent). Never retried.
var ErrMetaUnknownOutcome = errors.New("meta: the request was sent but no answer came back; the outcome is unknown")

// Meta is the Meta app client. AppSecret is a Plaintext so it never prints.
type Meta struct {
	AppID       string
	AppSecret   Plaintext
	RedirectURI string
	Version     string // Graph API version, e.g. v26.0
	GraphBase   string
	// DialogBase is the host of the OAuth dialog (meta_oauth.go); Scopes the
	// comma-separated permissions it asks for. Empty = MetaDialogBase,
	// MetaScopes.
	DialogBase string
	Scopes     string
	HTTP       *http.Client
	// Attempts is the most tries of one retry-safe call (default 3).
	Attempts int
	// BackoffBase is the first wait between tries, doubled each time up to
	// BackoffMax (defaults 1 s and 8 s).
	BackoffBase, BackoffMax time.Duration
	// Sleep waits d or until ctx ends; tests replace it.
	Sleep func(ctx context.Context, d time.Duration) error
	// Now is the clock for token expiry; tests replace it.
	Now func() time.Time
}

func (m *Meta) client() *http.Client {
	if m.HTTP != nil {
		return m.HTTP
	}
	return &http.Client{Timeout: 30 * time.Second}
}

func (m *Meta) graphBase() string { return orDefault(m.GraphBase, MetaGraphBase) }

func (m *Meta) version() (string, error) {
	v := orDefault(m.Version, MetaDefaultVersion)
	if !metaVersionRx.MatchString(v) {
		return "", fmt.Errorf("meta: api version %q is not vNN.N", v)
	}
	return v, nil
}

func (m *Meta) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

func (m *Meta) attempts() int {
	if m.Attempts > 0 {
		return m.Attempts
	}
	return 3
}

// backoff is the wait after failed try i (0-based): base * 2^i, capped.
func (m *Meta) backoff(i int) time.Duration {
	base, maxWait := m.BackoffBase, m.BackoffMax
	if base <= 0 {
		base = time.Second
	}
	if maxWait <= 0 {
		maxWait = 8 * time.Second
	}
	d := base
	for ; i > 0 && d < maxWait; i-- {
		d *= 2
	}
	return min(d, maxWait)
}

func (m *Meta) sleep(ctx context.Context, d time.Duration) error {
	if m.Sleep != nil {
		return m.Sleep(ctx, d)
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// appSecretProof is HMAC-SHA256(token, app secret), hex: Meta's proof that
// the call comes from the app's server ("Require App Secret").
func (m *Meta) appSecretProof(tok Plaintext) string {
	h := hmac.New(sha256.New, []byte(m.AppSecret.Reveal()))
	h.Write([]byte(tok.Reveal()))
	return hex.EncodeToString(h.Sum(nil))
}

// metaCall is one Graph API request. path is below the version ("/me/accounts").
type metaCall struct {
	method string
	path   string
	query  url.Values
	form   url.Values
	tok    Plaintext
	// safe: repeating it cannot make anything public twice.
	safe bool
}

// do runs c, retrying a transient failure of a safe call with backoff.
func (m *Meta) do(ctx context.Context, c metaCall, out any) error {
	n := m.attempts()
	for i := 0; ; i++ {
		err := m.once(ctx, c, out)
		if err == nil || i+1 >= n || !c.retryable(err) {
			return err
		}
		if m.sleep(ctx, m.backoff(i)) != nil {
			return err
		}
	}
}

func (c metaCall) retryable(err error) bool {
	if sentNothing(err) {
		return true
	}
	return c.safe && MetaKind(err) == MetaErrTransient
}

func (m *Meta) once(ctx context.Context, c metaCall, out any) error {
	req, err := m.request(ctx, c)
	if err != nil {
		return err
	}
	resp, err := m.client().Do(req)
	if err != nil {
		err = transportError(err)
		if !c.safe && !sentNothing(err) {
			return fmt.Errorf("%w (%s)", ErrMetaUnknownOutcome, err.Error())
		}
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		return parseMetaError(resp.StatusCode, resp.Header, b)
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(b, out); err != nil {
		return fmt.Errorf("meta %s: answer is not JSON: %w", c.path, err)
	}
	return nil
}

func (m *Meta) request(ctx context.Context, c metaCall) (*http.Request, error) {
	v, err := m.version()
	if err != nil {
		return nil, err
	}
	q := url.Values{}
	for k, vs := range c.query {
		q[k] = vs
	}
	if c.tok.Reveal() != "" && m.AppSecret.Reveal() != "" {
		q.Set("appsecret_proof", m.appSecretProof(c.tok))
	}
	u := m.graphBase() + "/" + v + c.path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	var body io.Reader
	if c.form != nil {
		body = strings.NewReader(c.form.Encode())
	}
	req, err := http.NewRequestWithContext(ctx, c.method, u, body)
	if err != nil {
		return nil, err
	}
	if c.form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if c.tok.Reveal() != "" {
		req.Header.Set("Authorization", "Bearer "+c.tok.Reveal())
	}
	return req, nil
}

// transportError drops the request URL (its query may hold appsecret_proof)
// and keeps the cause, so errors.As still finds a *net.OpError.
func transportError(err error) error {
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return fmt.Errorf("meta %s: %w", strings.ToLower(urlErr.Op), urlErr.Err)
	}
	return err
}

// sentNothing reports a connection that failed before the request went out.
func sentNothing(err error) bool {
	var oe *net.OpError
	return errors.As(err, &oe) && oe.Op == "dial"
}

// ExchangeLongLivedUserToken trades the authorization code from the OAuth
// callback for a short-lived user token, then that for a long-lived one
// (~60 days). The code is single-use, so that step is never repeated after
// it was sent.
func (m *Meta) ExchangeLongLivedUserToken(ctx context.Context, code string) (Token, error) {
	if code == "" {
		return Token{}, errors.New("meta token exchange: empty code")
	}
	short, err := m.tokenCall(ctx, false, url.Values{"redirect_uri": {m.RedirectURI}, "code": {code}})
	if err != nil {
		return Token{}, fmt.Errorf("meta code exchange: %w", err)
	}
	long, err := m.tokenCall(ctx, true, url.Values{"grant_type": {"fb_exchange_token"}, "fb_exchange_token": {short.Access.Reveal()}})
	if err != nil {
		return Token{}, fmt.Errorf("meta long-lived exchange: %w", err)
	}
	return long, nil
}

// tokenCall POSTs /oauth/access_token with the app's id and secret plus f.
func (m *Meta) tokenCall(ctx context.Context, safe bool, f url.Values) (Token, error) {
	f.Set("client_id", m.AppID)
	f.Set("client_secret", m.AppSecret.Reveal())
	var body struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := m.do(ctx, metaCall{method: http.MethodPost, path: "/oauth/access_token", form: f, safe: safe}, &body); err != nil {
		return Token{}, err
	}
	if body.AccessToken == "" {
		return Token{}, errors.New("no token in the answer")
	}
	ttl := metaDefaultLongLivedTTL
	if body.ExpiresIn > 0 {
		ttl = time.Duration(body.ExpiresIn) * time.Second
	}
	return Token{Access: NewPlaintext(body.AccessToken), ExpiresAt: m.now().Add(ttl)}, nil
}

// MetaInstagramAccount is the Instagram Professional account linked to a Page.
type MetaInstagramAccount struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Name     string `json:"name"`
}

// MetaPageAccount is one Page the member manages, with its Page Access Token
// (no expiry when fetched with a long-lived user token) and its Instagram
// account, nil when none is linked.
type MetaPageAccount struct {
	ID          string
	Name        string
	AccessToken Plaintext
	Tasks       []string
	Instagram   *MetaInstagramAccount
}

// metaAccountsMaxPages bounds the /me/accounts paging (100 Pages each).
const metaAccountsMaxPages = 10

type metaAccountsPage struct {
	Data []struct {
		ID          string                `json:"id"`
		Name        string                `json:"name"`
		AccessToken string                `json:"access_token"`
		Tasks       []string              `json:"tasks"`
		Instagram   *MetaInstagramAccount `json:"instagram_business_account"`
	} `json:"data"`
	Paging struct {
		Cursors struct {
			After string `json:"after"`
		} `json:"cursors"`
		Next string `json:"next"`
	} `json:"paging"`
}

// ListAccounts lists the Pages behind userToken (GET /me/accounts), following
// Meta's after cursor. The next URL Meta sends carries the token in its query,
// so it is never followed as is: only its cursor is reused.
func (m *Meta) ListAccounts(ctx context.Context, userToken Plaintext) ([]MetaPageAccount, error) {
	var all []MetaPageAccount
	after := ""
	for range metaAccountsMaxPages {
		q := url.Values{"fields": {"id,name,access_token,tasks,instagram_business_account{id,username,name}"}, "limit": {"100"}}
		if after != "" {
			q.Set("after", after)
		}
		var page metaAccountsPage
		if err := m.do(ctx, metaCall{method: http.MethodGet, path: "/me/accounts", query: q, tok: userToken, safe: true}, &page); err != nil {
			return nil, fmt.Errorf("meta list accounts: %w", err)
		}
		for _, p := range page.Data {
			all = append(all, MetaPageAccount{ID: p.ID, Name: p.Name, AccessToken: NewPlaintext(p.AccessToken), Tasks: p.Tasks, Instagram: p.Instagram})
		}
		if page.Paging.Next == "" || page.Paging.Cursors.After == "" {
			return all, nil
		}
		after = page.Paging.Cursors.After
	}
	return all, nil
}
