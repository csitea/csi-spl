package auth

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// Microsoft is the Microsoft identity platform (Entra ID v2.0) client, spec
// 018: authorization code + PKCE S256 for a confidential web client, the
// identity from a validated id_token, and the email trusted only when
// Microsoft verified it (personal accounts) or the account's tenant verified
// the domain (xms_edov) — the nOAuth rule. It is its own client, not the
// generic OIDC one, because its issuer and email trust depend on the
// signed-in account's tenant.
type Microsoft struct {
	ClientID, ClientSecret, RedirectURI, Scopes string
	// Tenant is the authority segment: common | consumers | organizations |
	// a tenant GUID (config validates it).
	Tenant string
	// LoginBase is "https://login.microsoftonline.com/", or the fake IdP base
	// + "/" (lde, tests). Every URL and the expected issuer hang off it.
	LoginBase string
	// TrustEmail accepts a work account's email without xms_edov (OQ-M2 (b);
	// config refuses it in prd).
	TrustEmail bool
	HTTP       *http.Client

	pkceKey []byte
	jwks    *jwksCache
	now     func() time.Time
}

const (
	microsoftLoginBase = "https://login.microsoftonline.com/"
	// microsoftConsumersTID is the tenant id of every personal Microsoft
	// account: Microsoft itself verified their email.
	microsoftConsumersTID = "9188040d-6c67-4c5b-b112-36a304b66dad"
	// labelPKCE derives the PKCE verifier key from the session key.
	labelPKCE = "spool-auth-pkce-v1"
	// idTokenSkew tolerates clock drift on exp / nbf / iat.
	idTokenSkew = 5 * time.Minute
)

// Microsoft authority keywords (SPOOL_HUB_AUTH_MICROSOFT_TENANT).
const (
	MicrosoftCommon        = "common"
	MicrosoftConsumers     = "consumers"
	MicrosoftOrganizations = "organizations"
)

var guidRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$`)

// validMicrosoftTenant: one of the three keywords, or a tenant GUID.
func validMicrosoftTenant(t string) bool {
	switch t {
	case MicrosoftCommon, MicrosoftConsumers, MicrosoftOrganizations:
		return true
	}
	return guidRE.MatchString(t)
}

// Paths under LoginBase, per authority (the fake IdP serves the same).
func MicrosoftAuthPath(tenant string) string  { return tenant + "/oauth2/v2.0/authorize" }
func MicrosoftTokenPath(tenant string) string { return tenant + "/oauth2/v2.0/token" }
func MicrosoftKeysPath(tenant string) string  { return tenant + "/discovery/v2.0/keys" }

// MicrosoftIssuer is the v2.0 id_token issuer of a tenant.
func MicrosoftIssuer(loginBase, tid string) string { return loginBase + tid + "/v2.0" }

// MicrosoftConsumersTenantID is exported for the fake IdP and tests.
const MicrosoftConsumersTenantID = microsoftConsumersTID

// nonceExchanger is an IdP whose exchange is bound to the flow's nonce (the
// id_token nonce and the PKCE verifier). The callback prefers it over Exchange.
type nonceExchanger interface {
	ExchangeNonce(ctx context.Context, code, nonce string) (Identity, error)
}

func newMicrosoft(c *Config, base string, hc *http.Client) *Microsoft {
	m := &Microsoft{ClientID: c.MicrosoftClientID, ClientSecret: c.MicrosoftClientSecret,
		RedirectURI: c.MicrosoftRedirectURI, Scopes: c.MicrosoftScopes,
		Tenant: strings.TrimSpace(c.MicrosoftTenant), LoginBase: microsoftLoginBase,
		TrustEmail: c.MicrosoftTrustEmail, HTTP: hc, pkceKey: subkey(c.SessionKey, labelPKCE)}
	if base != "" {
		m.LoginBase = base + "/"
	}
	m.jwks = newJWKSCache(m.LoginBase+MicrosoftKeysPath(m.Tenant), hc, nil)
	return m
}

func (m *Microsoft) Name() string { return ProviderMicrosoft }

func (m *Microsoft) clock() time.Time {
	if m.now != nil {
		return m.now()
	}
	return time.Now()
}

// verifier is the PKCE code_verifier of the flow that carries nonce: 43
// base64url chars, derived with the hub's key, so it needs no storage and
// never reaches the browser (FR-002).
func (m *Microsoft) verifier(nonce string) string {
	h := hmac.New(sha256.New, m.pkceKey)
	h.Write([]byte(nonce))
	return base64.RawURLEncoding.EncodeToString(h.Sum(nil))
}

// PKCEChallenge is S256(verifier) as RFC 7636 §4.2 defines it.
func PKCEChallenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func (m *Microsoft) AuthCodeURL(state, nonce string) string {
	q := url.Values{}
	q.Set("client_id", m.ClientID)
	q.Set("redirect_uri", m.RedirectURI)
	q.Set("response_type", "code")
	q.Set("response_mode", "query")
	q.Set("scope", m.Scopes)
	q.Set("state", state)
	q.Set("nonce", nonce)
	q.Set("code_challenge", PKCEChallenge(m.verifier(nonce)))
	q.Set("code_challenge_method", "S256")
	q.Set("prompt", "select_account")
	return m.LoginBase + MicrosoftAuthPath(m.Tenant) + "?" + q.Encode()
}

// Exchange without the flow's nonce cannot check the id_token; the callback
// always calls ExchangeNonce.
func (m *Microsoft) Exchange(context.Context, string) (Identity, error) {
	return Identity{}, fmt.Errorf("%w: microsoft needs the flow nonce", errExchange)
}

// microsoftClaims are the v2.0 id_token claims the hub reads.
type microsoftClaims struct {
	Iss     string          `json:"iss"`
	Aud     json.RawMessage `json:"aud"`
	Exp     int64           `json:"exp"`
	Nbf     int64           `json:"nbf"`
	Iat     int64           `json:"iat"`
	Nonce   string          `json:"nonce"`
	Tid     string          `json:"tid"`
	Oid     string          `json:"oid"`
	Email   string          `json:"email"`
	Name    string          `json:"name"`
	XmsEdov json.RawMessage `json:"xms_edov"`
}

func (m *Microsoft) ExchangeNonce(ctx context.Context, code, nonce string) (Identity, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("client_id", m.ClientID)
	form.Set("client_secret", m.ClientSecret)
	form.Set("redirect_uri", m.RedirectURI)
	form.Set("code_verifier", m.verifier(nonce))
	form.Set("scope", m.Scopes)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.LoginBase+MicrosoftTokenPath(m.Tenant),
		strings.NewReader(form.Encode()))
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %v", errExchange, err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := httpClient(m.HTTP).Do(req)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: token: %v", errExchange, err)
	}
	var tok struct {
		IDToken string `json:"id_token"`
		Error   string `json:"error"`
		// error_codes carries the AADSTS number (no secret, safe to log).
		ErrorCodes []int `json:"error_codes"`
	}
	if err := readJSON(resp, &tok); err != nil || resp.StatusCode != http.StatusOK || tok.IDToken == "" {
		return Identity{}, fmt.Errorf("%w: token status %d %s %v", errExchange, resp.StatusCode, tok.Error, tok.ErrorCodes)
	}
	var c microsoftClaims
	if err := verifyRS256(ctx, m.jwks, tok.IDToken, &c); err != nil {
		return Identity{}, fmt.Errorf("%w: %v", errExchange, err)
	}
	if err := m.checkClaims(c, nonce); err != nil {
		return Identity{}, fmt.Errorf("%w: %v", errExchange, err)
	}
	email := strings.ToLower(strings.TrimSpace(c.Email))
	if email == "" {
		return Identity{}, fmt.Errorf("%w: no email claim", errEmailUnverified)
	}
	if !strings.EqualFold(c.Tid, microsoftConsumersTID) && !m.TrustEmail && !claimTrue(c.XmsEdov) {
		return Identity{}, fmt.Errorf("%w: work account without xms_edov", errEmailUnverified)
	}
	return Identity{Provider: ProviderMicrosoft, Subject: strings.ToLower(c.Tid) + "/" + strings.ToLower(c.Oid),
		Email: email, Name: strings.TrimSpace(c.Name)}, nil
}

// checkClaims is FR-003 + the FR-001 tenant rule, after the signature.
func (m *Microsoft) checkClaims(c microsoftClaims, nonce string) error {
	if !guidRE.MatchString(c.Tid) || !guidRE.MatchString(c.Oid) {
		return fmt.Errorf("%w: tid/oid not GUIDs", errIDToken)
	}
	if c.Iss != MicrosoftIssuer(m.LoginBase, c.Tid) {
		return fmt.Errorf("%w: iss does not match tid", errIDToken)
	}
	if !audHas(c.Aud, m.ClientID) {
		return fmt.Errorf("%w: aud is not this client", errIDToken)
	}
	now := m.clock()
	if c.Exp == 0 || now.After(time.Unix(c.Exp, 0).Add(idTokenSkew)) {
		return fmt.Errorf("%w: expired", errIDToken)
	}
	if c.Nbf != 0 && now.Add(idTokenSkew).Before(time.Unix(c.Nbf, 0)) {
		return fmt.Errorf("%w: not yet valid", errIDToken)
	}
	if c.Iat != 0 && now.Add(idTokenSkew).Before(time.Unix(c.Iat, 0)) {
		return fmt.Errorf("%w: issued in the future", errIDToken)
	}
	if nonce == "" || !hmac.Equal([]byte(c.Nonce), []byte(nonce)) {
		return fmt.Errorf("%w: nonce", errIDToken)
	}
	personal := strings.EqualFold(c.Tid, microsoftConsumersTID)
	switch m.Tenant {
	case MicrosoftCommon:
	case MicrosoftConsumers:
		if !personal {
			return fmt.Errorf("%w: tenant mode consumers, work account", errIDToken)
		}
	case MicrosoftOrganizations:
		if personal {
			return fmt.Errorf("%w: tenant mode organizations, personal account", errIDToken)
		}
	default:
		if !strings.EqualFold(c.Tid, m.Tenant) {
			return fmt.Errorf("%w: tid is not the configured tenant", errIDToken)
		}
	}
	return nil
}

// audHas: aud is a string or an array of strings holding id.
func audHas(raw json.RawMessage, id string) bool {
	var one string
	if json.Unmarshal(raw, &one) == nil {
		return one != "" && one == id
	}
	var many []string
	if json.Unmarshal(raw, &many) == nil {
		for _, a := range many {
			if a == id {
				return true
			}
		}
	}
	return false
}

// claimTrue reads a boolean-ish optional claim: true, "true" or 1.
func claimTrue(raw json.RawMessage) bool {
	if jsonTruthy(raw) {
		return true
	}
	var n json.Number
	return json.Unmarshal(raw, &n) == nil && n.String() == "1"
}
