package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// OIDC is the generic OpenID Connect authorization-code client behind
// LinkedIn and xAI (spec 010 FR-012; donor csi-rel oidc_idp.go). Microsoft has
// its own client since spec 018 (microsoft.go).
// Per provider only the endpoints, the scopes and the email-trust rule
// differ. As with Google, the identity is the userinfo response fetched
// server-to-server with the access token just issued to our confidential
// client, so the id_token is not needed as a second copy of the same claims;
// the nonce stays bound to the browser through the signed state + cookie.
type OIDC struct {
	Provider                            string
	ClientID, ClientSecret, RedirectURI string
	Scopes                              string
	AuthURL, TokenURL, UserinfoURL      string
	// A truthy email_verified claim is always required (Microsoft, which
	// could lack one, has its own client since spec 018).
	HTTP *http.Client
	// AvatarHTTPBase: see Google.AvatarHTTPBase.
	AvatarHTTPBase string
}

func (o *OIDC) Name() string { return o.Provider }

func (o *OIDC) AuthCodeURL(state, nonce string) string {
	q := url.Values{}
	q.Set("client_id", o.ClientID)
	q.Set("redirect_uri", o.RedirectURI)
	q.Set("response_type", "code")
	q.Set("scope", o.Scopes)
	q.Set("state", state)
	q.Set("nonce", nonce)
	sep := "?"
	if strings.Contains(o.AuthURL, "?") {
		sep = "&"
	}
	return o.AuthURL + sep + q.Encode()
}

func (o *OIDC) Exchange(ctx context.Context, code string) (Identity, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("client_id", o.ClientID)
	form.Set("client_secret", o.ClientSecret)
	form.Set("redirect_uri", o.RedirectURI)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %w", errExchange, err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := httpClient(o.HTTP).Do(req)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: token: %w", errExchange, err)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	if err := readJSON(resp, &tok); err != nil || resp.StatusCode != http.StatusOK || tok.AccessToken == "" {
		return Identity{}, fmt.Errorf("%w: token status %d %s", errExchange, resp.StatusCode, tok.Error)
	}

	ui, err := http.NewRequestWithContext(ctx, http.MethodGet, o.UserinfoURL, nil)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %w", errExchange, err)
	}
	ui.Header.Set("Authorization", "Bearer "+tok.AccessToken)
	ui.Header.Set("Accept", "application/json")
	uresp, err := httpClient(o.HTTP).Do(ui)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: userinfo: %w", errExchange, err)
	}
	var info struct {
		Sub           string          `json:"sub"`
		Email         string          `json:"email"`
		EmailVerified json.RawMessage `json:"email_verified"`
		Name          string          `json:"name"`
		Picture       string          `json:"picture"`
	}
	if err := readJSON(uresp, &info); err != nil || uresp.StatusCode != http.StatusOK || info.Sub == "" {
		return Identity{}, fmt.Errorf("%w: userinfo status %d", errExchange, uresp.StatusCode)
	}
	email := strings.ToLower(strings.TrimSpace(info.Email))
	if email == "" || !jsonTruthy(info.EmailVerified) {
		return Identity{}, errEmailUnverified
	}
	id := Identity{Provider: o.Provider, Subject: info.Sub, Email: email, Name: strings.TrimSpace(info.Name)}
	id.Avatar, id.AvatarType, _ = fetchAvatar(ctx, o.HTTP, info.Picture, o.AvatarHTTPBase)
	return id, nil
}

// jsonTruthy reads an email_verified claim that may be a JSON bool or a
// quoted "true" (providers disagree on its type).
func jsonTruthy(raw json.RawMessage) bool {
	var b bool
	if json.Unmarshal(raw, &b) == nil {
		return b
	}
	var s string
	return json.Unmarshal(raw, &s) == nil && strings.EqualFold(strings.TrimSpace(s), "true")
}

// Real endpoints of the generic OIDC providers with a published, fixed issuer.
// xAI has none here: its endpoints are cnf (FR-012).
const (
	linkedinAuthURL     = "https://www.linkedin.com/oauth/v2/authorization"
	linkedinTokenURL    = "https://www.linkedin.com/oauth/v2/accessToken"
	linkedinUserinfoURL = "https://api.linkedin.com/v2/userinfo"
)

// OIDC paths the fake IdP serves per provider (auth.OIDCAuthPath("xai") …).
func OIDCAuthPath(p string) string     { return "/oidc/" + p + "/authorize" }
func OIDCTokenPath(p string) string    { return "/oidc/" + p + "/token" }
func OIDCUserinfoPath(p string) string { return "/oidc/" + p + "/userinfo" }

// newOIDC builds a generic OIDC client from the validated config; base is the
// fake IdP override ("" in dev/prd).
func newOIDC(c *Config, p, base string, hc *http.Client) *OIDC {
	id, secret, redirect := c.creds(p)
	o := &OIDC{Provider: p, ClientID: id, ClientSecret: secret, RedirectURI: redirect, HTTP: hc}
	switch p {
	case ProviderLinkedIn:
		o.Scopes, o.AuthURL, o.TokenURL, o.UserinfoURL = c.LinkedInScopes, linkedinAuthURL, linkedinTokenURL, linkedinUserinfoURL
	case ProviderXAI:
		o.Scopes, o.AuthURL, o.TokenURL, o.UserinfoURL = c.XAIScopes, c.XAIAuthURL, c.XAITokenURL, c.XAIUserinfoURL
	default:
		return nil
	}
	if base != "" {
		o.AuthURL, o.TokenURL, o.UserinfoURL = base+OIDCAuthPath(p), base+OIDCTokenPath(p), base+OIDCUserinfoPath(p)
		o.AvatarHTTPBase = base
	}
	return o
}
