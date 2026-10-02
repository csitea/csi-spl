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
	Provider string // google | facebook | microsoft | linkedin | xai
	Subject  string // the IdP's stable subject (sub / Graph id)
	Email    string // lower-cased, provider-verified
	Name     string
	// Avatar is the IdP picture, fetched server-side at sign-in (010 T044,
	// SPEC-spool-avatars §3-4) and already checked by fetchAvatar; nil when
	// the IdP has none or the fetch failed (never blocks the sign-in).
	Avatar     []byte
	AvatarType string // image/png | image/jpeg | image/gif | image/webp
}

// IdP is one provider's authorization-code client: Google, Facebook,
// Microsoft (microsoft.go, spec 018), or the generic OIDC client (oidc.go) for
// LinkedIn and xAI.
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
	// AvatarHTTPBase: the one origin whose picture may be fetched over http
	// (the fake IdP base, lde/tests; "" in dev/prd = https only).
	AvatarHTTPBase string
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
		return Identity{}, fmt.Errorf("%w: %w", errExchange, err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := httpClient(g.HTTP).Do(req)
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

	ui, err := http.NewRequestWithContext(ctx, http.MethodGet, g.UserinfoURL, nil)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %w", errExchange, err)
	}
	ui.Header.Set("Authorization", "Bearer "+tok.AccessToken)
	uresp, err := httpClient(g.HTTP).Do(ui)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: userinfo: %w", errExchange, err)
	}
	var info struct {
		Sub           string `json:"sub"`
		Email         string `json:"email"`
		EmailVerified bool   `json:"email_verified"`
		Name          string `json:"name"`
		Picture       string `json:"picture"`
	}
	if err := readJSON(uresp, &info); err != nil || uresp.StatusCode != http.StatusOK || info.Sub == "" {
		return Identity{}, fmt.Errorf("%w: userinfo status %d", errExchange, uresp.StatusCode)
	}
	email := strings.ToLower(strings.TrimSpace(info.Email))
	if email == "" || !info.EmailVerified {
		return Identity{}, errEmailUnverified
	}
	id := Identity{Provider: ProviderGoogle, Subject: info.Sub, Email: email, Name: strings.TrimSpace(info.Name)}
	id.Avatar, id.AvatarType, _ = fetchAvatar(ctx, g.HTTP, info.Picture, g.AvatarHTTPBase)
	return id, nil
}

// Facebook is the Facebook Login client (OAuth 2.0; no id_token). The identity
// is Graph /me, signed with appsecret_proof so a stolen access token is
// useless against this app id.
type Facebook struct {
	ClientID, ClientSecret, RedirectURI, Scopes string
	DialogBase, GraphBase                       string
	HTTP                                        *http.Client
	AvatarHTTPBase                              string // see Google.AvatarHTTPBase
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
		return Identity{}, fmt.Errorf("%w: %w", errExchange, err)
	}
	resp, err := httpClient(f.HTTP).Do(req)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: token: %w", errExchange, err)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if err := readJSON(resp, &tok); err != nil || resp.StatusCode != http.StatusOK || tok.AccessToken == "" {
		return Identity{}, fmt.Errorf("%w: token status %d", errExchange, resp.StatusCode)
	}

	mq := url.Values{}
	mq.Set("fields", "id,email,name,picture.width(256).height(256)")
	mq.Set("access_token", tok.AccessToken)
	mq.Set("appsecret_proof", f.appSecretProof(tok.AccessToken))
	me, err := http.NewRequestWithContext(ctx, http.MethodGet, f.GraphBase+FacebookMePath+"?"+mq.Encode(), nil)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %w", errExchange, err)
	}
	mresp, err := httpClient(f.HTTP).Do(me)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: me: %w", errExchange, err)
	}
	var who struct {
		ID    string `json:"id"`
		Email string `json:"email"`
		Name  string `json:"name"`
		// Graph's picture edge; a silhouette is Facebook's own default, not
		// the person's picture, so it is not stored.
		Picture struct {
			Data struct {
				URL          string `json:"url"`
				IsSilhouette bool   `json:"is_silhouette"`
			} `json:"data"`
		} `json:"picture"`
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
	id := Identity{Provider: ProviderFacebook, Subject: who.ID, Email: email, Name: strings.TrimSpace(who.Name)}
	if !who.Picture.Data.IsSilhouette {
		id.Avatar, id.AvatarType, _ = fetchAvatar(ctx, f.HTTP, who.Picture.Data.URL, f.AvatarHTTPBase)
	}
	return id, nil
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
			g.AvatarHTTPBase = base
		}
		return g
	case ProviderFacebook:
		f := &Facebook{ClientID: c.FacebookClientID, ClientSecret: c.FacebookClientSecret,
			RedirectURI: c.FacebookRedirectURI, Scopes: c.FacebookScopes, HTTP: hc,
			DialogBase: facebookDialog, GraphBase: facebookGraph}
		if base != "" {
			f.DialogBase, f.GraphBase, f.AvatarHTTPBase = base, base, base
		}
		return f
	case ProviderMicrosoft:
		return newMicrosoft(c, base, hc)
	case ProviderLinkedIn, ProviderXAI:
		return newOIDC(c, p, base, hc)
	}
	return nil
}

// Avatar fetch limits (010 T044): a small square raster, not an attachment.
const (
	AvatarMaxBytes     = 256 << 10
	avatarMaxRedirects = 3
)

var avatarTimeout = 5 * time.Second // a var so tests can shorten it

var errAvatar = errors.New("auth: avatar not fetched")

// avatarTypes are the stored picture types: the declared Content-Type AND the
// sniffed bytes must both be one of these, and agree (no SVG: it is script).
var avatarTypes = map[string]bool{"image/png": true, "image/jpeg": true, "image/gif": true, "image/webp": true}

// fetchAvatar GETs the IdP picture server-side so the WUI never hotlinks a
// third-party URL (SPEC-spool-avatars §4). The URL must be https, except on
// httpBase's own origin (the fake IdP in lde/tests; config refuses that base
// in prd); every redirect must be https, at most avatarMaxRedirects of them.
// The body is capped at AvatarMaxBytes and the whole fetch at avatarTimeout.
// Any failure wraps errAvatar and returns no bytes: the caller signs the
// person in without a picture.
func fetchAvatar(ctx context.Context, hc *http.Client, raw, httpBase string) ([]byte, string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, "", fmt.Errorf("%w: none", errAvatar)
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil {
		return nil, "", fmt.Errorf("%w: bad url", errAvatar)
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && sameOrigin(u, httpBase)) {
		return nil, "", fmt.Errorf("%w: %q is not https", errAvatar, u.Scheme)
	}
	c := &http.Client{Transport: httpClient(hc).Transport, Timeout: avatarTimeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) > avatarMaxRedirects {
				return fmt.Errorf("%w: too many redirects", errAvatar)
			}
			if req.URL.Scheme != "https" {
				return fmt.Errorf("%w: redirect to %q is not https", errAvatar, req.URL.Scheme)
			}
			return nil
		}}
	ctx, cancel := context.WithTimeout(ctx, avatarTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, "", fmt.Errorf("%w: %w", errAvatar, err)
	}
	req.Header.Set("Accept", "image/png, image/jpeg, image/gif, image/webp")
	resp, err := c.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("%w: %w", errAvatar, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("%w: status %d", errAvatar, resp.StatusCode)
	}
	if resp.ContentLength > AvatarMaxBytes {
		return nil, "", fmt.Errorf("%w: %d bytes over the cap", errAvatar, resp.ContentLength)
	}
	ct, _, _ := strings.Cut(resp.Header.Get("Content-Type"), ";")
	ct = strings.ToLower(strings.TrimSpace(ct))
	if !avatarTypes[ct] {
		return nil, "", fmt.Errorf("%w: content-type %q", errAvatar, ct)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, AvatarMaxBytes+1))
	if err != nil {
		return nil, "", fmt.Errorf("%w: %w", errAvatar, err)
	}
	if len(body) > AvatarMaxBytes {
		return nil, "", fmt.Errorf("%w: body over the cap", errAvatar)
	}
	if sniffed := http.DetectContentType(body); sniffed != ct {
		return nil, "", fmt.Errorf("%w: declared %s, bytes are %s", errAvatar, ct, sniffed)
	}
	return body, ct, nil
}

// sniffImage is the stored picture's type from its bytes, "" unless it is one
// fetchAvatar admits.
func sniffImage(b []byte) string {
	if ct := http.DetectContentType(b); avatarTypes[ct] {
		return ct
	}
	return ""
}

// sameOrigin: u is on base's scheme://host[:port]; base "" never matches.
func sameOrigin(u *url.URL, base string) bool {
	if base == "" {
		return false
	}
	b, err := url.Parse(base)
	return err == nil && b.Host != "" && strings.EqualFold(u.Scheme, b.Scheme) && strings.EqualFold(u.Host, b.Host)
}
