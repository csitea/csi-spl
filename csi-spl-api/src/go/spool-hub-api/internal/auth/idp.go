package auth

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Identity is the portable result of a successful exchange. Privilege is never
// read from it: the hub's Registrar decides what the person becomes.
type Identity struct {
	Provider string // google | facebook
	Subject  string // the IdP's stable subject (sub / Graph id)
	Email    string // lower-cased, provider-verified
	Name     string
}

// IdP is one provider's authorization-code client. Adding Microsoft, LinkedIn
// or xAI (spec 010, Planned) means one more implementation of this.
type IdP interface {
	Name() string
	AuthCodeURL(state, nonce string) string
	Exchange(ctx context.Context, code string) (Identity, error)
}

var (
	errExchange        = errors.New("auth: provider exchange failed")
	errEmailUnverified = errors.New("auth: provider email missing or unverified")
)

// Real endpoints. Tests and lde swap the host with SPOOL_HUB_AUTH_IDP_BASE_URL
// (fakeidp serves the same paths).
const (
	googleAuthURL     = "https://accounts.google.com/o/oauth2/v2/auth"
	googleTokenURL    = "https://oauth2.googleapis.com/token"
	googleUserinfoURL = "https://openidconnect.googleapis.com/v1/userinfo"
	facebookDialog    = "https://www.facebook.com"
	facebookGraph     = "https://graph.facebook.com"
	// FacebookGraphVersion pins the Graph API version (csi-rel 052 pins v25.0,
	// long-lived to 2028-07).
	FacebookGraphVersion = "v25.0"
)

// Paths the fake IdP must serve when it stands in for both providers.
const (
	GoogleAuthPath     = "/o/oauth2/v2/auth"
	GoogleTokenPath    = "/token"
	GoogleUserinfoPath = "/v1/userinfo"
	FacebookDialogPath = "/" + FacebookGraphVersion + "/dialog/oauth"
	FacebookTokenPath  = "/" + FacebookGraphVersion + "/oauth/access_token"
	FacebookMePath     = "/" + FacebookGraphVersion + "/me"
)

func httpClient(c *http.Client) *http.Client {
	if c != nil {
		return c
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func readJSON(resp *http.Response, v any) error {
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	return json.Unmarshal(body, v)
}

// Google is the OIDC authorization-code client. The identity comes from the
// userinfo endpoint, called server-to-server over TLS with the access token
// just issued to our confidential client; the id_token is therefore not
// needed as a second, signature-checked copy of the same claims.
type Google struct {
	ClientID, ClientSecret, RedirectURI, Scopes string
	AuthURL, TokenURL, UserinfoURL              string
	HTTP                                        *http.Client
}

func (g *Google) Name() string { return ProviderGoogle }

func (g *Google) AuthCodeURL(state, nonce string) string {
	q := url.Values{}
	q.Set("client_id", g.ClientID)
	q.Set("redirect_uri", g.RedirectURI)
	q.Set("response_type", "code")
	q.Set("scope", g.Scopes)
	q.Set("access_type", "online")
	q.Set("prompt", "select_account")
	q.Set("state", state)
	q.Set("nonce", nonce)
	return g.AuthURL + "?" + q.Encode()
}

func (g *Google) Exchange(ctx context.Context, code string) (Identity, error) {
	form := url.Values{}
	form.Set("code", code)
	form.Set("client_id", g.ClientID)
	form.Set("client_secret", g.ClientSecret)
	form.Set("redirect_uri", g.RedirectURI)
	form.Set("grant_type", "authorization_code")
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %v", errExchange, err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := httpClient(g.HTTP).Do(req)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: token: %v", errExchange, err)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	if err := readJSON(resp, &tok); err != nil || resp.StatusCode != http.StatusOK || tok.AccessToken == "" {
		return Identity{}, fmt.Errorf("%w: token status %d %s", errExchange, resp.StatusCode, tok.Error)
	}

	ui, err := http.NewRequestWithContext(ctx, http.MethodGet, g.UserinfoURL, nil)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %v", errExchange, err)
	}
	ui.Header.Set("Authorization", "Bearer "+tok.AccessToken)
	uresp, err := httpClient(g.HTTP).Do(ui)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: userinfo: %v", errExchange, err)
	}
	var info struct {
		Sub           string `json:"sub"`
		Email         string `json:"email"`
		EmailVerified bool   `json:"email_verified"`
		Name          string `json:"name"`
	}
	if err := readJSON(uresp, &info); err != nil || uresp.StatusCode != http.StatusOK || info.Sub == "" {
		return Identity{}, fmt.Errorf("%w: userinfo status %d", errExchange, uresp.StatusCode)
	}
	email := strings.ToLower(strings.TrimSpace(info.Email))
	if email == "" || !info.EmailVerified {
		return Identity{}, errEmailUnverified
	}
	return Identity{Provider: ProviderGoogle, Subject: info.Sub, Email: email, Name: strings.TrimSpace(info.Name)}, nil
}

// Facebook is the Facebook Login client (OAuth 2.0; no id_token). The identity
// is Graph /me, signed with appsecret_proof so a stolen access token is
// useless against this app id.
type Facebook struct {
	ClientID, ClientSecret, RedirectURI, Scopes string
	DialogBase, GraphBase                       string
	HTTP                                        *http.Client
}

func (f *Facebook) Name() string { return ProviderFacebook }

// AuthCodeURL: Facebook has no id_token to echo a nonce in, so the nonce lives
// only inside the signed state.
func (f *Facebook) AuthCodeURL(state, _ string) string {
	q := url.Values{}
	q.Set("client_id", f.ClientID)
	q.Set("redirect_uri", f.RedirectURI)
	q.Set("response_type", "code")
	q.Set("scope", f.Scopes)
	q.Set("auth_type", "rerequest")
	q.Set("state", state)
	return f.DialogBase + FacebookDialogPath + "?" + q.Encode()
}

func (f *Facebook) appSecretProof(token string) string {
	m := hmac.New(sha256.New, []byte(f.ClientSecret))
	m.Write([]byte(token))
	return hex.EncodeToString(m.Sum(nil))
}

func (f *Facebook) Exchange(ctx context.Context, code string) (Identity, error) {
	q := url.Values{}
	q.Set("client_id", f.ClientID)
	q.Set("client_secret", f.ClientSecret)
	q.Set("redirect_uri", f.RedirectURI)
	q.Set("code", code)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.GraphBase+FacebookTokenPath+"?"+q.Encode(), nil)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %v", errExchange, err)
	}
	resp, err := httpClient(f.HTTP).Do(req)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: token: %v", errExchange, err)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if err := readJSON(resp, &tok); err != nil || resp.StatusCode != http.StatusOK || tok.AccessToken == "" {
		return Identity{}, fmt.Errorf("%w: token status %d", errExchange, resp.StatusCode)
	}

	mq := url.Values{}
	mq.Set("fields", "id,email,name")
	mq.Set("access_token", tok.AccessToken)
	mq.Set("appsecret_proof", f.appSecretProof(tok.AccessToken))
	me, err := http.NewRequestWithContext(ctx, http.MethodGet, f.GraphBase+FacebookMePath+"?"+mq.Encode(), nil)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %v", errExchange, err)
	}
	mresp, err := httpClient(f.HTTP).Do(me)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: me: %v", errExchange, err)
	}
	var who struct {
		ID    string `json:"id"`
		Email string `json:"email"`
		Name  string `json:"name"`
	}
	if err := readJSON(mresp, &who); err != nil || mresp.StatusCode != http.StatusOK || who.ID == "" {
		return Identity{}, fmt.Errorf("%w: me status %d", errExchange, mresp.StatusCode)
	}
	// Graph omits email when the person declined the permission or never
	// confirmed it; a present address is Facebook's verification attestation.
	email := strings.ToLower(strings.TrimSpace(who.Email))
	if email == "" {
		return Identity{}, errEmailUnverified
	}
	return Identity{Provider: ProviderFacebook, Subject: who.ID, Email: email, Name: strings.TrimSpace(who.Name)}, nil
}

// newIdP builds the client for an enabled provider from the validated config.
func newIdP(c *Config, p string, hc *http.Client) IdP {
	base := strings.TrimRight(c.IdPBaseURL, "/")
	switch p {
	case ProviderGoogle:
		g := &Google{ClientID: c.GoogleClientID, ClientSecret: c.GoogleClientSecret,
			RedirectURI: c.GoogleRedirectURI, Scopes: c.GoogleScopes, HTTP: hc,
			AuthURL: googleAuthURL, TokenURL: googleTokenURL, UserinfoURL: googleUserinfoURL}
		if base != "" {
			g.AuthURL, g.TokenURL, g.UserinfoURL = base+GoogleAuthPath, base+GoogleTokenPath, base+GoogleUserinfoPath
		}
		return g
	case ProviderFacebook:
		f := &Facebook{ClientID: c.FacebookClientID, ClientSecret: c.FacebookClientSecret,
			RedirectURI: c.FacebookRedirectURI, Scopes: c.FacebookScopes, HTTP: hc,
			DialogBase: facebookDialog, GraphBase: facebookGraph}
		if base != "" {
			f.DialogBase, f.GraphBase = base, base
		}
		return f
	}
	return nil
}
