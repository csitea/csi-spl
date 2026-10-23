// Package gcal is the Google side of the per-member Google Calendar connect
// (spec 149, row B4): the OAuth connect (this file) and the Calendar API
// calls the sync needs (client.go). Tests run against fakegcal, never Google.
//
// No Google host, client id or secret is written here: every endpoint comes
// from Config, which the hub fills from cnf at runtime (row B5). A Config
// with a hole answers ErrNotConfigured, which the routes turn into 503
// gcal_not_configured (spec 149 section 2.8).
//
// Tokens travel as marketing.Plaintext, so a token never prints, encodes
// or logs; Reveal is called only to build a request.
package gcal

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

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
)

// stateLabel keys the connect state MAC apart from every other use of the
// client secret (spec 149 section 2.2).
const stateLabel = "spool-gcal-connect-state/v1"

var (
	// ErrNotConfigured is a Config missing a client or an endpoint.
	ErrNotConfigured = errors.New("gcal: not configured")
	// ErrState is any connect state that does not verify (forged, expired, malformed).
	ErrState = errors.New("gcal: connect state does not verify")
	// ErrInvalidGrant is the token endpoint refusing a code or a refresh
	// token: the member revoked access, or the code was used or expired.
	ErrInvalidGrant = errors.New("gcal: invalid_grant")
	// ErrUnauthorized is a Calendar call refused for its access token (401).
	ErrUnauthorized = errors.New("gcal: access token refused")
	// ErrNotFound is a Calendar call on a calendar or event that is gone (404).
	ErrNotFound = errors.New("gcal: not found")
	// ErrSyncTokenGone is events.list refusing a syncToken (410): the caller
	// clears it and lists in full (spec 149 section 2.5).
	ErrSyncTokenGone = errors.New("gcal: sync token gone")
)

// Config is the OAuth client and the Google endpoints, all from cnf.
type Config struct {
	ClientID     string
	ClientSecret marketing.Plaintext
	RedirectURI  string
	Scopes       string // space separated, cnf gcal.scopes

	AuthURL      string // the browser's consent page
	TokenURL     string // code exchange and refresh
	RevokeURL    string
	UserinfoURL  string // OpenID Connect userinfo: the Google email
	CalendarBase string // the Calendar API v3 root

	HTTP *http.Client
}

// Validate answers ErrNotConfigured when any field the flow needs is empty.
func (c Config) Validate() error {
	var missing []string
	for name, v := range map[string]string{
		"client id": c.ClientID, "client secret": c.ClientSecret.Reveal(), "redirect uri": c.RedirectURI,
		"scopes": c.Scopes, "auth url": c.AuthURL, "token url": c.TokenURL, "revoke url": c.RevokeURL,
		"userinfo url": c.UserinfoURL, "calendar base": c.CalendarBase,
	} {
		if strings.TrimSpace(v) == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("%w: %d field(s) empty", ErrNotConfigured, len(missing))
	}
	return nil
}

// Google is the Google client of one hub: the OAuth connect and the
// Calendar calls. It holds no member token; each call takes one.
type Google struct {
	cfg Config
}

// New checks cfg and returns the client.
func New(cfg Config) (*Google, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	cfg.CalendarBase = strings.TrimRight(cfg.CalendarBase, "/")
	return &Google{cfg: cfg}, nil
}

func (g *Google) client() *http.Client {
	if g.cfg.HTTP != nil {
		return g.cfg.HTTP
	}
	return &http.Client{Timeout: 20 * time.Second}
}

// State is what a connect state binds: the workspace, the member who started
// the flow, when it stops being valid, and the nonce the cookie must echo.
type State struct {
	Tenant string `json:"t"`
	Member string `json:"m"`
	Exp    int64  `json:"e"`
	Nonce  string `json:"n"`
}

func (g *Google) stateKey() []byte {
	m := hmac.New(sha256.New, []byte(g.cfg.ClientSecret.Reveal()))
	m.Write([]byte(stateLabel))
	return m.Sum(nil)
}

// NewState signs st with a fresh nonce: "<payload>.<mac>", base64url. The
// nonce comes back so the caller can set it as the cookie.
func (g *Google) NewState(st State) (state, nonce string) {
	n := make([]byte, 16)
	rand.Read(n) //nolint:errcheck // crypto/rand.Read never fails since Go 1.24
	st.Nonce = base64.RawURLEncoding.EncodeToString(n)
	b, _ := json.Marshal(st) //nolint:errchkjson // plain strings and an int
	p := base64.RawURLEncoding.EncodeToString(b)
	m := hmac.New(sha256.New, g.stateKey())
	m.Write([]byte(p))
	return p + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil)), st.Nonce
}

// VerifyState checks s's MAC and expiry at now and returns what it binds.
// Comparing the nonce with the cookie is the caller's.
func (g *Google) VerifyState(s string, now time.Time) (State, error) {
	p, mac, ok := strings.Cut(s, ".")
	if !ok {
		return State{}, ErrState
	}
	got, err := base64.RawURLEncoding.DecodeString(mac)
	if err != nil {
		return State{}, ErrState
	}
	m := hmac.New(sha256.New, g.stateKey())
	m.Write([]byte(p))
	if !hmac.Equal(got, m.Sum(nil)) {
		return State{}, ErrState
	}
	b, err := base64.RawURLEncoding.DecodeString(p)
	if err != nil {
		return State{}, ErrState
	}
	var st State
	if json.Unmarshal(b, &st) != nil || st.Tenant == "" || st.Member == "" || st.Nonce == "" || now.Unix() > st.Exp {
		return State{}, ErrState
	}
	return st, nil
}

// AuthorizeURL is where the member's browser goes to approve the app:
// offline access (a refresh token) and a forced consent, so Google sends
// the refresh token again on a re-connect.
func (g *Google) AuthorizeURL(state string) string {
	q := url.Values{
		"response_type":          {"code"},
		"client_id":              {g.cfg.ClientID},
		"redirect_uri":           {g.cfg.RedirectURI},
		"scope":                  {g.cfg.Scopes},
		"access_type":            {"offline"},
		"include_granted_scopes": {"true"},
		"prompt":                 {"consent"},
		"state":                  {state},
	}
	sep := "?"
	if strings.Contains(g.cfg.AuthURL, "?") {
		sep = "&"
	}
	return g.cfg.AuthURL + sep + q.Encode()
}

// Token is the answer of a code exchange or a refresh. A refresh answers no
// new refresh token as a rule: Refresh is then empty and the stored one stays.
type Token struct {
	Access    marketing.Plaintext
	Refresh   marketing.Plaintext
	ExpiresAt time.Time
	Scope     string
}

// Exchange trades an authorization code for the member's tokens.
func (g *Google) Exchange(ctx context.Context, code string, now time.Time) (Token, error) {
	tok, err := g.token(ctx, url.Values{
		"grant_type":   {"authorization_code"},
		"code":         {code},
		"redirect_uri": {g.cfg.RedirectURI},
	}, now)
	if err != nil {
		return Token{}, fmt.Errorf("gcal token exchange: %w", err)
	}
	if tok.Refresh.Reveal() == "" {
		return Token{}, errors.New("gcal token exchange: no refresh token in the answer")
	}
	return tok, nil
}

// Refresh trades the refresh token for a new access token. ErrInvalidGrant
// means the connection is revoked (spec 149 section 2.4).
func (g *Google) Refresh(ctx context.Context, refresh marketing.Plaintext, now time.Time) (Token, error) {
	tok, err := g.token(ctx, url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {refresh.Reveal()},
	}, now)
	if err != nil {
		return Token{}, fmt.Errorf("gcal token refresh: %w", err)
	}
	return tok, nil
}

func (g *Google) token(ctx context.Context, form url.Values, now time.Time) (Token, error) {
	form.Set("client_id", g.cfg.ClientID)
	form.Set("client_secret", g.cfg.ClientSecret.Reveal())
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.cfg.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return Token{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var body struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
		Scope        string `json:"scope"`
	}
	if err := g.doJSON(req, &body); err != nil {
		return Token{}, err
	}
	if body.AccessToken == "" || body.ExpiresIn <= 0 {
		return Token{}, errors.New("no access token in the answer")
	}
	return Token{
		Access:    marketing.NewPlaintext(body.AccessToken),
		Refresh:   marketing.NewPlaintext(body.RefreshToken),
		ExpiresAt: now.Add(time.Duration(body.ExpiresIn) * time.Second),
		Scope:     body.Scope,
	}, nil
}

// Revoke revokes tok (a refresh token revokes the whole grant). A token
// Google no longer knows is already revoked: that is not an error.
func (g *Google) Revoke(ctx context.Context, tok marketing.Plaintext) error {
	form := url.Values{"token": {tok.Reveal()}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.cfg.RevokeURL, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	err = g.doJSON(req, nil)
	var he *HTTPError
	if errors.As(err, &he) && he.Status == http.StatusBadRequest && he.Reason == "invalid_token" {
		return nil
	}
	if err != nil {
		return fmt.Errorf("gcal revoke: %w", err)
	}
	return nil
}

// Userinfo answers the Google email behind access (scope "openid email").
func (g *Google) Userinfo(ctx context.Context, access marketing.Plaintext) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.cfg.UserinfoURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+access.Reveal())
	var u struct {
		Email string `json:"email"`
	}
	if err := g.doJSON(req, &u); err != nil {
		return "", fmt.Errorf("gcal userinfo: %w", err)
	}
	if u.Email == "" {
		return "", errors.New("gcal userinfo: no email (scope email not granted)")
	}
	return u.Email, nil
}

// HTTPError is a non-2xx Google answer: the status, Google's reason code
// and message, never a request header (so never a token). errors.Is maps it
// to ErrInvalidGrant, ErrUnauthorized, ErrNotFound and ErrSyncTokenGone.
type HTTPError struct {
	Status  int
	Reason  string
	Message string
}

// Error implements error.
func (e *HTTPError) Error() string {
	return fmt.Sprintf("HTTP %d %s: %s", e.Status, e.Reason, e.Message)
}

// Is implements the errors.Is mapping.
func (e *HTTPError) Is(target error) bool {
	switch target {
	case ErrInvalidGrant:
		return e.Reason == "invalid_grant"
	case ErrUnauthorized:
		return e.Status == http.StatusUnauthorized
	case ErrNotFound:
		return e.Status == http.StatusNotFound
	case ErrSyncTokenGone:
		return e.Status == http.StatusGone
	}
	return false
}

func (g *Google) doJSON(req *http.Request, out any) error {
	resp, err := g.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode/100 != 2 {
		return httpError(resp.StatusCode, b)
	}
	if out == nil || len(b) == 0 {
		return nil
	}
	return json.Unmarshal(b, out)
}

// httpError reads both Google error shapes: the OAuth one
// {"error":"invalid_grant","error_description":"..."} and the API one
// {"error":{"code":410,"message":"...","errors":[{"reason":"..."}]}}.
func httpError(status int, body []byte) *HTTPError {
	e := &HTTPError{Status: status}
	var oauth struct {
		Error       string `json:"error"`
		Description string `json:"error_description"`
	}
	var api struct {
		Error struct {
			Message string `json:"message"`
			Status  string `json:"status"`
			Errors  []struct {
				Reason string `json:"reason"`
			} `json:"errors"`
		} `json:"error"`
	}
	switch {
	case json.Unmarshal(body, &oauth) == nil && oauth.Error != "":
		e.Reason, e.Message = oauth.Error, oauth.Description
	case json.Unmarshal(body, &api) == nil:
		e.Message, e.Reason = api.Error.Message, api.Error.Status
		if len(api.Error.Errors) > 0 && api.Error.Errors[0].Reason != "" {
			e.Reason = api.Error.Errors[0].Reason
		}
	}
	if len(e.Message) > 200 {
		e.Message = e.Message[:200]
	}
	return e
}
