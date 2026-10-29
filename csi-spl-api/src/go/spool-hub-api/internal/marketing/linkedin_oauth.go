package marketing

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// linkedin_oauth.go is the LinkedIn side of connecting an account (spec 090
// T006, SPL-1634): the authorize URL, the code exchange and the member id.
// The app is "Spool Hub" (linkedin-app-setup.md): products "Share on
// LinkedIn" (w_member_social) and "Sign In with LinkedIn using OpenID
// Connect" (openid profile). A member access token lives 60 days and comes
// with no refresh token, so the hub reminds the member to re-connect.
//
// No PKCE: LinkedIn supports it only for native apps; this is a web app with
// a client secret. The state is an HMAC of (workspace, member, expiry, nonce)
// keyed from the client secret, so any hub instance verifies it and nobody
// without the secret can forge one.

// LinkedInScopes are the scopes the connect flow asks for.
const LinkedInScopes = "openid profile w_member_social"

// The LinkedIn hosts; LinkedIn's fields point them at a fake in tests.
const (
	LinkedInAuthBase = "https://www.linkedin.com"
	LinkedInAPIBase  = "https://api.linkedin.com"
)

// ErrState is any connect state that does not verify (forged, expired, malformed).
var ErrState = errors.New("marketing: connect state does not verify")

// LinkedIn is the LinkedIn app client. ClientSecret is a Plaintext so it
// never prints; Reveal is called only to build the HTTP form.
type LinkedIn struct {
	ClientID     string
	ClientSecret Plaintext
	RedirectURI  string
	Version      string // the LinkedIn-Version header of the REST API (YYYYMM)
	AuthBase     string
	APIBase      string
	HTTP         *http.Client
}

// Token is a member access token from the code exchange.
type Token struct {
	Access    Plaintext
	ExpiresAt time.Time
}

// Member is the LinkedIn member from userinfo: Sub is the person id
// (urn:li:person:<Sub>).
type Member struct {
	Sub  string `json:"sub"`
	Name string `json:"name"`
}

func (l *LinkedIn) client() *http.Client {
	if l.HTTP != nil {
		return l.HTTP
	}
	return &http.Client{Timeout: 20 * time.Second}
}

func (l *LinkedIn) authBase() string { return orDefault(l.AuthBase, LinkedInAuthBase) }
func (l *LinkedIn) apiBase() string  { return orDefault(l.APIBase, LinkedInAPIBase) }

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return strings.TrimRight(v, "/")
}

// State is what a connect state binds: the workspace, the member who started
// the flow, and when it stops being valid.
type State struct {
	Tenant string `json:"t"`
	Member string `json:"m"`
	Exp    int64  `json:"e"`
	Nonce  string `json:"n"`
}

func (l *LinkedIn) stateKey() []byte {
	return stateKey(l.ClientSecret, "spool-marketing-connect-state/v1")
}

// NewState signs st (a fresh nonce is added): "<payload>.<mac>", base64url.
func (l *LinkedIn) NewState(st State) string { return signState(l.stateKey(), st) }

// VerifyState checks s's MAC and expiry at now and returns what it binds.
func (l *LinkedIn) VerifyState(s string, now time.Time) (State, error) {
	return verifyState(l.stateKey(), s, now)
}

// stateKey derives a connect-state key from an app secret, one label per
// app, so a state minted for one app never verifies for another.
func stateKey(secret Plaintext, label string) []byte {
	m := hmac.New(sha256.New, []byte(secret.Reveal()))
	m.Write([]byte(label))
	return m.Sum(nil)
}

// signState signs st with key (a fresh nonce is added): "<payload>.<mac>".
func signState(key []byte, st State) string {
	n := make([]byte, 16)
	rand.Read(n) //nolint:errcheck // crypto/rand.Read never fails since Go 1.24
	st.Nonce = base64.RawURLEncoding.EncodeToString(n)
	b, _ := json.Marshal(st) //nolint:errchkjson // plain strings and an int
	p := base64.RawURLEncoding.EncodeToString(b)
	m := hmac.New(sha256.New, key)
	m.Write([]byte(p))
	return p + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// verifyState checks s's MAC under key and its expiry at now.
func verifyState(key []byte, s string, now time.Time) (State, error) {
	p, mac, ok := strings.Cut(s, ".")
	if !ok {
		return State{}, ErrState
	}
	got, err := base64.RawURLEncoding.DecodeString(mac)
	if err != nil {
		return State{}, ErrState
	}
	m := hmac.New(sha256.New, key)
	m.Write([]byte(p))
	if !hmac.Equal(got, m.Sum(nil)) {
		return State{}, ErrState
	}
	b, err := base64.RawURLEncoding.DecodeString(p)
	if err != nil {
		return State{}, ErrState
	}
	var st State
	if json.Unmarshal(b, &st) != nil || st.Tenant == "" || st.Member == "" || now.Unix() > st.Exp {
		return State{}, ErrState
	}
	return st, nil
}

// AuthorizeURL is where the member's browser goes to approve the app.
func (l *LinkedIn) AuthorizeURL(state string) string {
	q := url.Values{
		"response_type": {"code"},
		"client_id":     {l.ClientID},
		"redirect_uri":  {l.RedirectURI},
		"state":         {state},
		"scope":         {LinkedInScopes},
	}
	return l.authBase() + "/oauth/v2/authorization?" + q.Encode()
}

// Exchange trades an authorization code for a member access token.
func (l *LinkedIn) Exchange(ctx context.Context, code string, now time.Time) (Token, error) {
	form := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {l.RedirectURI},
		"client_id":     {l.ClientID},
		"client_secret": {l.ClientSecret.Reveal()},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, l.authBase()+"/oauth/v2/accessToken", strings.NewReader(form.Encode()))
	if err != nil {
		return Token{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var body struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := l.doJSON(req, &body); err != nil {
		return Token{}, fmt.Errorf("linkedin token exchange: %w", err)
	}
	if body.AccessToken == "" || body.ExpiresIn <= 0 {
		return Token{}, errors.New("linkedin token exchange: no token in the answer")
	}
	return Token{Access: NewPlaintext(body.AccessToken), ExpiresAt: now.Add(time.Duration(body.ExpiresIn) * time.Second)}, nil
}

// Userinfo reads the member behind tok (OpenID Connect userinfo).
func (l *LinkedIn) Userinfo(ctx context.Context, tok Plaintext) (Member, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, l.apiBase()+"/v2/userinfo", nil)
	if err != nil {
		return Member{}, err
	}
	req.Header.Set("Authorization", "Bearer "+tok.Reveal())
	var m Member
	if err := l.doJSON(req, &m); err != nil {
		return Member{}, fmt.Errorf("linkedin userinfo: %w", err)
	}
	if m.Sub == "" {
		return Member{}, errors.New("linkedin userinfo: no member id")
	}
	return m, nil
}

// HTTPError is a non-2xx LinkedIn answer: the status and LinkedIn's own
// message, never a request header (so never a token).
type HTTPError struct {
	Status  int
	Message string
}

// Error implements error.
func (e *HTTPError) Error() string { return fmt.Sprintf("HTTP %d: %s", e.Status, e.Message) }

func (l *LinkedIn) doJSON(req *http.Request, out any) error {
	resp, err := l.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		return httpError(resp.StatusCode, b)
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(b, out)
}

// httpError keeps only LinkedIn's message fields, cut short.
func httpError(status int, body []byte) *HTTPError {
	var e struct {
		Message          string `json:"message"`
		ErrorDescription string `json:"error_description"`
		Error            string `json:"error"`
	}
	_ = json.Unmarshal(body, &e)
	msg := e.Message
	if msg == "" {
		msg = e.ErrorDescription
	}
	if msg == "" {
		msg = e.Error
	}
	if len(msg) > 200 {
		msg = msg[:200]
	}
	return &HTTPError{Status: status, Message: msg}
}
