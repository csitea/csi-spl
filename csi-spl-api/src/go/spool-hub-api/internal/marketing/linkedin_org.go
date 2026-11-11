package marketing

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// linkedin_org.go is the LinkedIn Company Page side of a marketing channel
// (spec 090 phase 4, T041, SPL-5258; linkedin-company-page.md sections 3-5):
// a SECOND LinkedIn developer app that holds only the Community Management
// API (LinkedIn bars any other product on it), so the personal-profile app
// (linkedin_oauth.go, linkedin_post.go) stays as it is.
//
//   - Connect: the authorize URL with the organization scopes, the code
//     exchange (an access token of 60 days, and on an approved app a
//     refresh token of 365 days), then the Pages the member administers
//     (organizationAcls, role ADMINISTRATOR or CONTENT_ADMIN, state
//     APPROVED) with each Page's name and vanity slug.
//   - Publish: the thumbnail is uploaded owned by the organization, and the
//     post is made with author urn:li:organization:<id>, never a person.
//   - Refresh: grant_type=refresh_token before the access token ends; the
//     refresh token keeps its first 365-day end.
//
// No PKCE (a confidential web client, as for the personal app). The state
// key has its own label, so a personal-profile state never verifies here
// and the other way round.

// LinkedInOrgScopes are the default scopes of the Company Page connect
// (cnf marketing.linkedin_org.scopes may name others).
const LinkedInOrgScopes = "w_organization_social r_organization_social rw_organization_admin"

// The Page roles that may post organic content as the Page (section 4.1):
// Super admin and Content admin. Every other role is ignored.
const (
	LinkedInOrgRoleAdmin        = "ADMINISTRATOR"
	LinkedInOrgRoleContentAdmin = "CONTENT_ADMIN"
)

// linkedInOrgURN is the author / owner urn prefix of an organization.
const linkedInOrgURN = "urn:li:organization:"

// LinkedInOrg is the Company Page app client. ClientSecret is a Plaintext
// so it never prints; Reveal is called only to build the HTTP form.
type LinkedInOrg struct {
	ClientID     string
	ClientSecret Plaintext
	RedirectURI  string
	Version      string // the LinkedIn-Version header of the REST API (YYYYMM)
	Scopes       string // "" = LinkedInOrgScopes
	AuthBase     string
	APIBase      string
	HTTP         *http.Client
}

// OrgToken is the Page connection's token bundle: the access token (60
// days) and, on an approved app, the refresh token (365 days from the
// first consent). Refresh is empty when LinkedIn issued none.
type OrgToken struct {
	Access           Plaintext
	ExpiresAt        time.Time
	Refresh          Plaintext
	RefreshExpiresAt time.Time
}

// ConsentEnd is when the member has to connect again: the refresh token's
// end, or the access token's when there is no refresh token.
func (t OrgToken) ConsentEnd() time.Time {
	if t.Refresh.Reveal() != "" && t.RefreshExpiresAt.After(t.ExpiresAt) {
		return t.RefreshExpiresAt
	}
	return t.ExpiresAt
}

// OrgPage is one Company Page the connecting member may post as.
type OrgPage struct {
	ID         string // the numeric organization id
	Name       string // localizedName
	VanityName string // the linkedin.com/company/<vanity> slug
	Role       string // ADMINISTRATOR or CONTENT_ADMIN
}

// URN is the Page's organization urn.
func (p OrgPage) URN() string { return linkedInOrgURN + p.ID }

// li is the shared LinkedIn REST plumbing on this app's credentials.
func (o *LinkedInOrg) li() *LinkedIn {
	return &LinkedIn{ClientID: o.ClientID, ClientSecret: o.ClientSecret, RedirectURI: o.RedirectURI,
		Version: o.Version, AuthBase: o.AuthBase, APIBase: o.APIBase, HTTP: o.HTTP}
}

func (o *LinkedInOrg) scopes() string {
	if s := strings.TrimSpace(o.Scopes); s != "" {
		return s
	}
	return LinkedInOrgScopes
}

func (o *LinkedInOrg) stateKey() []byte {
	return stateKey(o.ClientSecret, "spool-marketing-linkedin-org-state/v1")
}

// NewState signs st (a fresh nonce is added).
func (o *LinkedInOrg) NewState(st State) string { return signState(o.stateKey(), st) }

// VerifyState checks s's MAC and expiry at now and returns what it binds.
func (o *LinkedInOrg) VerifyState(s string, now time.Time) (State, error) {
	return verifyState(o.stateKey(), s, now)
}

// AuthorizeURL is where the member's browser goes to approve the app.
func (o *LinkedInOrg) AuthorizeURL(state string) string {
	q := url.Values{
		"response_type": {"code"},
		"client_id":     {o.ClientID},
		"redirect_uri":  {o.RedirectURI},
		"state":         {state},
		"scope":         {o.scopes()},
	}
	return o.li().authBase() + "/oauth/v2/authorization?" + q.Encode()
}

// Exchange trades an authorization code for the token bundle.
func (o *LinkedInOrg) Exchange(ctx context.Context, code string, now time.Time) (OrgToken, error) {
	return o.token(ctx, url.Values{"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {o.RedirectURI}},
		now, "linkedin org token exchange")
}

// Refresh trades tok's refresh token for a fresh access token. A refresh
// token and its end missing from the answer keep tok's.
func (o *LinkedInOrg) Refresh(ctx context.Context, tok OrgToken, now time.Time) (OrgToken, error) {
	fresh, err := o.token(ctx, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {tok.Refresh.Reveal()}},
		now, "linkedin org token refresh")
	if err != nil {
		return OrgToken{}, err
	}
	if fresh.Refresh.Reveal() == "" {
		fresh.Refresh = tok.Refresh
	}
	if fresh.RefreshExpiresAt.IsZero() {
		fresh.RefreshExpiresAt = tok.RefreshExpiresAt
	}
	return fresh, nil
}

func (o *LinkedInOrg) token(ctx context.Context, form url.Values, now time.Time, what string) (OrgToken, error) {
	form.Set("client_id", o.ClientID)
	form.Set("client_secret", o.ClientSecret.Reveal())
	l := o.li()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, l.authBase()+"/oauth/v2/accessToken", strings.NewReader(form.Encode()))
	if err != nil {
		return OrgToken{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var body struct {
		AccessToken           string `json:"access_token"`
		ExpiresIn             int64  `json:"expires_in"`
		RefreshToken          string `json:"refresh_token"`
		RefreshTokenExpiresIn int64  `json:"refresh_token_expires_in"`
	}
	if err := l.doJSON(req, &body); err != nil {
		return OrgToken{}, fmt.Errorf("%s: %w", what, err)
	}
	if body.AccessToken == "" || body.ExpiresIn <= 0 {
		return OrgToken{}, errors.New(what + ": no token in the answer")
	}
	tok := OrgToken{Access: NewPlaintext(body.AccessToken), ExpiresAt: now.Add(time.Duration(body.ExpiresIn) * time.Second),
		Refresh: NewPlaintext(body.RefreshToken)}
	if body.RefreshToken != "" && body.RefreshTokenExpiresIn > 0 {
		tok.RefreshExpiresAt = now.Add(time.Duration(body.RefreshTokenExpiresIn) * time.Second)
	}
	return tok, nil
}

// AdminPages lists the Company Pages the member behind tok may post as: an
// APPROVED ADMINISTRATOR or CONTENT_ADMIN role (section 4.1), one entry per
// Page (Super admin wins over Content admin), each with its name and slug,
// ordered by id.
func (o *LinkedInOrg) AdminPages(ctx context.Context, tok Plaintext) ([]OrgPage, error) {
	l := o.li()
	req, err := l.restRequest(ctx, http.MethodGet, "/rest/organizationAcls?q=roleAssignee&state=APPROVED&count=100", tok, nil)
	if err != nil {
		return nil, err
	}
	var acls struct {
		Elements []struct {
			Organization string `json:"organization"`
			Role         string `json:"role"`
			State        string `json:"state"`
		} `json:"elements"`
	}
	if err := l.doJSON(req, &acls); err != nil {
		return nil, fmt.Errorf("linkedin organizationAcls: %w", err)
	}
	roles := map[string]string{}
	for _, e := range acls.Elements {
		id, ok := strings.CutPrefix(e.Organization, linkedInOrgURN)
		if !ok || id == "" || e.State != "APPROVED" || (e.Role != LinkedInOrgRoleAdmin && e.Role != LinkedInOrgRoleContentAdmin) {
			continue
		}
		if roles[id] != LinkedInOrgRoleAdmin {
			roles[id] = e.Role
		}
	}
	out := make([]OrgPage, 0, len(roles))
	for id, role := range roles {
		p, err := o.page(ctx, l, tok, id)
		if err != nil {
			return nil, err
		}
		p.Role = role
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// page reads one organization's name and vanity slug.
func (o *LinkedInOrg) page(ctx context.Context, l *LinkedIn, tok Plaintext, id string) (OrgPage, error) {
	req, err := l.restRequest(ctx, http.MethodGet, "/rest/organizations/"+url.PathEscape(id), tok, nil)
	if err != nil {
		return OrgPage{}, err
	}
	var org struct {
		LocalizedName string `json:"localizedName"`
		VanityName    string `json:"vanityName"`
	}
	if err := l.doJSON(req, &org); err != nil {
		return OrgPage{}, fmt.Errorf("linkedin organizations: %w", err)
	}
	name := strings.TrimSpace(org.LocalizedName)
	if name == "" {
		name = linkedInOrgURN + id
	}
	return OrgPage{ID: id, Name: name, VanityName: strings.TrimSpace(org.VanityName)}, nil
}

// UploadImage puts pic on LinkedIn owned by the Page orgID and returns its
// image urn.
func (o *LinkedInOrg) UploadImage(ctx context.Context, tok Plaintext, orgID string, pic []byte) (string, error) {
	return o.li().uploadImageAs(ctx, tok, linkedInOrgURN+orgID, pic)
}

// Post publishes a on the Page orgID's feed, the Page as the author, and
// returns the post urn. A failure after the request went out is
// ErrUnknownOutcome (never retried).
func (o *LinkedInOrg) Post(ctx context.Context, tok Plaintext, orgID string, a Article, thumbnail string) (string, error) {
	return o.li().postAs(ctx, tok, linkedInOrgURN+orgID, a, thumbnail)
}

// uploadImageAs puts pic on LinkedIn owned by the urn owner (a person or an
// organization) and returns its image urn.
func (l *LinkedIn) uploadImageAs(ctx context.Context, tok Plaintext, owner string, pic []byte) (string, error) {
	req, err := l.restRequest(ctx, http.MethodPost, "/rest/images?action=initializeUpload", tok,
		map[string]any{"initializeUploadRequest": map[string]any{"owner": owner}})
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

// postAs publishes a with the urn author (a person or an organization) and
// returns the post urn. An Article with no URL is a text post: the
// commentary alone, no card. A failure after the request went out is
// ErrUnknownOutcome (never retried).
func (l *LinkedIn) postAs(ctx context.Context, tok Plaintext, author string, a Article, thumbnail string) (string, error) {
	body := map[string]any{
		"author":     author,
		"commentary": EscapeLittleText(a.Commentary),
		"visibility": "PUBLIC",
		"distribution": map[string]any{"feedDistribution": "MAIN_FEED", "targetEntities": []any{},
			"thirdPartyDistributionChannels": []any{}},
		"lifecycleState":            "PUBLISHED",
		"isReshareDisabledByAuthor": false,
	}
	if a.URL != "" {
		article := map[string]any{"source": a.URL, "title": a.Title, "description": a.Description}
		if thumbnail != "" {
			article["thumbnail"] = thumbnail
		}
		body["content"] = map[string]any{"article": article}
	}
	req, err := l.restRequest(ctx, http.MethodPost, "/rest/posts", tok, body)
	if err != nil {
		return "", err
	}
	resp, err := l.client().Do(req)
	if err != nil {
		if dialFailed(err) {
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

// LinkedInPostPermalink is a post urn's public address ("" for no urn).
func LinkedInPostPermalink(urn string) string {
	if urn == "" {
		return ""
	}
	return LinkedInAuthBase + "/feed/update/" + urn
}

// OrgTokenRefused: LinkedIn no longer accepts the Page connection (section
// 5.4): a 401, a 403 (the member lost the Page role), or a refresh refused
// with 400 (invalid_grant: an expired or revoked refresh token). Connect
// again.
func OrgTokenRefused(err error) bool {
	var he *HTTPError
	if !errors.As(err, &he) {
		return false
	}
	return he.Status == http.StatusUnauthorized || he.Status == http.StatusForbidden || he.Status == http.StatusBadRequest
}

// Bundle is the token bundle as one Plaintext, sealed into one channel token.
func (t OrgToken) Bundle() Plaintext {
	b, _ := json.Marshal(map[string]any{"a": t.Access.Reveal(), "e": t.ExpiresAt.Unix(), //nolint:errchkjson // strings and ints
		"r": t.Refresh.Reveal(), "re": unixOrZero(t.RefreshExpiresAt)})
	return NewPlaintext(string(b))
}

func unixOrZero(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

// ParseOrgToken reads a Bundle back.
func ParseOrgToken(p Plaintext) (OrgToken, error) {
	var b struct {
		A  string `json:"a"`
		E  int64  `json:"e"`
		R  string `json:"r"`
		RE int64  `json:"re"`
	}
	if err := json.Unmarshal([]byte(p.Reveal()), &b); err != nil || b.A == "" {
		return OrgToken{}, errors.New("linkedin org: the sealed token is not a token bundle")
	}
	tok := OrgToken{Access: NewPlaintext(b.A), ExpiresAt: time.Unix(b.E, 0), Refresh: NewPlaintext(b.R)}
	if b.RE > 0 {
		tok.RefreshExpiresAt = time.Unix(b.RE, 0)
	}
	return tok, nil
}
