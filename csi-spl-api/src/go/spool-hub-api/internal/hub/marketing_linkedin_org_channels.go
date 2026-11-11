package hub

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Connecting a LinkedIn Company Page (spec 090 phase 4, T041, SPL-5258;
// linkedin-company-page.md sections 4-6; owner HUM-10, topic 12d8a588 msg
// 04836282). The X connect's shape (marketing_x_channels.go), on the second
// LinkedIn app, which holds only the Community Management API:
//
//	GET  /v1/marketing/linkedin-org/connect?workspace=<id>  302 to LinkedIn
//	POST /v1/marketing/linkedin-org/connect?workspace=<id>  {authorize_url}
//	GET  /v1/marketing/linkedin-org/callback?code&state     LinkedIn's
//	     redirect, also at LinkedInOrgCallbackPath (the WUI host's rewrite)
//	GET  /v1/marketing/linkedin-org/pages                   the workspace's
//	     connected Company Pages, never a token
//
// Who may connect is the LinkedIn rule (marketingConnectMember: a member
// holding rbac.TenantSettings of an allow-listed workspace with marketing
// on); on LinkedIn's side the member must be a Page Super admin or Content
// admin. The callback trusts only the signed state (15 minutes; its own key
// label, so a personal-profile state is refused). It trades the code for
// the token bundle, lists the Pages the member may post as and connects one
// channel per Page (platform linkedin_page, account_type page), each with
// the bundle sealed (KMS envelope, T005) and auto_publish off: nothing is
// posted without a human's press (spec.md 16.3, 17.1). No Page: nothing is
// stored. While the app is not configured on this hub (cnf
// marketing.linkedin_org.inject "false"), every route answers 503
// not_configured. Disconnect is the shared DELETE
// /v1/marketing/channels/{channel_id}.

// MarketingLinkedInOrg is what the hub needs to connect Company Pages and
// post as them. nil in Options = not configured.
type MarketingLinkedInOrg struct {
	Org    *marketing.LinkedInOrg
	Sealer *marketing.Sealer
	// AppURL is the WUI origin: the page the callback points back to, the
	// blog index and the post links.
	AppURL string
	// APIURL is the hub's public origin: the re-connect link mailed before
	// the connection ends or after LinkedIn refuses it. "" = the mail names
	// the settings page.
	APIURL string
	// Mail tells the member who connected the Page of a failure, a refused
	// token or the coming end; nil = no mail relay (log only).
	Mail func(ctx context.Context, to, subject, body string) error
	// DailyCap is the most API posts a Page makes in 24 h; 0 = metaDailyCap
	// (spec.md FR-007, the same cap as every channel).
	DailyCap int
}

// ConnectLink is the one-click Company Page (re-)connect link for workspace.
func (m *MarketingLinkedInOrg) ConnectLink(workspace string) string {
	if m.APIURL == "" {
		return m.AppURL + " (Tenant settings, Marketing: connect a LinkedIn Company Page)"
	}
	return m.APIURL + "/v1/marketing/linkedin-org/connect?" + url.Values{"workspace": {workspace}}.Encode()
}

// LinkedInOrgCallbackPath is the callback as registered in the Company Page
// app (linkedin-company-page.md 10.2 step 4): on the WUI origin, whose
// Hosting rewrite forwards it to the hub with the path as is.
const LinkedInOrgCallbackPath = "/api/v1/marketing/linkedin-org/callback"

// linkedInOrgAutoPublish: a Page channel holds every post for a human's press.
const linkedInOrgAutoPublish = false

// linkedInOrgConfigured writes 503 not_configured (or 501 for a store
// without marketing channels) unless the Company Page connect can run.
func (s *Server) linkedInOrgConfigured(w http.ResponseWriter) (*MarketingLinkedInOrg, store.Marketing, bool) {
	m := s.o.MarketingLinkedInOrg
	if m == nil || m.Org == nil || m.Sealer == nil {
		writeErr(w, http.StatusServiceUnavailable, "not_configured", "LinkedIn company page publishing is not configured on this hub")
		return nil, nil, false
	}
	mk, has := s.o.Store.(store.Marketing)
	if !has {
		s.marketingStoreOK(w)
		return nil, nil, false
	}
	return m, mk, true
}

// linkedInOrgAuthorizeURL starts a connect for the member: LinkedIn's consent URL.
func (s *Server) linkedInOrgAuthorizeURL(w http.ResponseWriter, r *http.Request) (string, bool) {
	tenant, hum, ok := s.marketingConnectMember(w, r)
	if !ok {
		return "", false
	}
	m, _, ok := s.linkedInOrgConfigured(w)
	if !ok {
		return "", false
	}
	st := m.Org.NewState(marketing.State{Tenant: tenant, Member: hum, Exp: s.o.Now().Add(connectStateTTL).Unix()})
	return m.Org.AuthorizeURL(st), true
}

// GET /v1/marketing/linkedin-org/connect: the browser goes on to LinkedIn.
func (s *Server) handleLinkedInOrgConnectGo(w http.ResponseWriter, r *http.Request) {
	if au, ok := s.linkedInOrgAuthorizeURL(w, r); ok {
		http.Redirect(w, r, au, http.StatusFound)
	}
}

// POST /v1/marketing/linkedin-org/connect: the WUI gets the URL to open.
func (s *Server) handleLinkedInOrgConnect(w http.ResponseWriter, r *http.Request) {
	if au, ok := s.linkedInOrgAuthorizeURL(w, r); ok {
		writeJSON(w, http.StatusOK, map[string]string{"authorize_url": au})
	}
}

// errNoOrgPage: LinkedIn named no Page the member may post as.
var errNoOrgPage = errors.New("no LinkedIn company page with an approved Super admin or Content admin role")

// GET /v1/marketing/linkedin-org/callback: LinkedIn sends the browser back here.
func (s *Server) handleLinkedInOrgCallback(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	m, mk, ok := s.linkedInOrgConfigured(w)
	if !ok {
		return
	}
	q := r.URL.Query()
	st, err := m.Org.VerifyState(q.Get("state"), s.o.Now())
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_state", "this connect link is not valid or has expired; start again")
		return
	}
	const failed = "LinkedIn company page was not connected"
	if e := q.Get("error"); e != "" {
		connectPageBack(w, http.StatusOK, failed, "LinkedIn answered: "+e+". Nothing was stored.", m.AppURL)
		return
	}
	if s.marketingDemo(w, st.Tenant) || !s.marketingOn(w, r, st.Tenant) {
		return
	}
	chs, err := s.connectLinkedInOrg(r.Context(), m, mk, st, q.Get("code"))
	switch {
	case errors.Is(err, errNoOrgPage):
		connectPageBack(w, http.StatusOK, failed, "LinkedIn returned no company page where you are an approved Super admin or "+
			"Content admin. Nothing was stored. Ask a Super admin of the page to give you one of those roles, then connect again.", m.AppURL)
		return
	case err != nil:
		s.o.Log.Error().Str("tenant", st.Tenant).Str("member", st.Member).Str("err", err.Error()).Msg("marketing: linkedin page connect failed")
		connectPageBack(w, http.StatusBadGateway, failed,
			"The exchange with LinkedIn failed. Nothing was stored. Open the connect link again.", m.AppURL)
		return
	}
	names := make([]string, len(chs))
	for i, ch := range chs {
		names[i] = ch.AccountName
		s.o.Log.Info().Str("tenant", st.Tenant).Str("channel", ch.ID).Str("member", st.Member).Msg("marketing: linkedin page connected")
	}
	connectPageBack(w, http.StatusOK, "LinkedIn company page connected", "Connected "+strings.Join(names, ", ")+" for workspace "+
		st.Tenant+". Nothing is posted on it until an admin or business owner presses Publish.", m.AppURL)
}

// connectLinkedInOrg exchanges the code, lists the Pages the member may post
// as and connects one channel per Page, each with the bundle sealed. Errors
// carry no token text.
func (s *Server) connectLinkedInOrg(ctx context.Context, m *MarketingLinkedInOrg, mk store.Marketing, st marketing.State, code string) ([]store.MarketingChannel, error) {
	if code == "" {
		return nil, errors.New("no code in the callback")
	}
	tok, err := m.Org.Exchange(ctx, code, s.o.Now())
	if err != nil {
		return nil, err
	}
	pages, err := m.Org.AdminPages(ctx, tok.Access)
	if err != nil {
		return nil, err
	}
	if len(pages) == 0 {
		return nil, errNoOrgPage
	}
	end := tok.ConsentEnd()
	out := make([]store.MarketingChannel, 0, len(pages))
	for _, p := range pages {
		sealed, keyID, err := m.Sealer.Seal(ctx, tok.Bundle())
		if err != nil {
			return out, err
		}
		ch, err := mk.ConnectMarketingChannel(ctx, store.MarketingChannel{Tenant: st.Tenant, Platform: store.MarketingPlatformLinkedInPage,
			AccountType: "page", AccountRef: p.ID, AccountName: p.Name, DelegatedBy: st.Member, AutoPublish: linkedInOrgAutoPublish,
			ExpiresAt: &end, Metadata: map[string]any{"organization_urn": p.URN(), "vanity_name": p.VanityName, "role": p.Role}},
			store.MarketingToken{Ciphertext: sealed, KMSKeyID: keyID}, s.o.Now())
		if err != nil {
			return out, err
		}
		out = append(out, ch)
	}
	return out, nil
}

// linkedInPage is one connected Company Page in GET /v1/marketing/linkedin-org/pages.
type linkedInPage struct {
	ChannelID       string `json:"channel_id"`
	OrganizationID  string `json:"organization_id"`
	OrganizationURN string `json:"organization_urn"`
	Name            string `json:"name"`
	VanityName      string `json:"vanity_name"`
	Role            string `json:"role"`
	Status          string `json:"status"`
	ExpiresAt       string `json:"expires_at,omitempty"`
	DelegatedBy     string `json:"delegated_by"`
}

// GET /v1/marketing/linkedin-org/pages: the workspace's connected Company Pages.
func (s *Server) handleLinkedInOrgPages(w http.ResponseWriter, r *http.Request, tenant string) {
	w.Header().Set("Cache-Control", "no-store")
	_, mk, ok := s.linkedInOrgConfigured(w)
	if !ok {
		return
	}
	chs, err := mk.MarketingChannels(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "marketing channels unavailable")
		return
	}
	out := []linkedInPage{}
	for _, c := range chs {
		if c.Platform != store.MarketingPlatformLinkedInPage {
			continue
		}
		urn, _ := c.Metadata["organization_urn"].(string)
		vanity, _ := c.Metadata["vanity_name"].(string)
		role, _ := c.Metadata["role"].(string)
		p := linkedInPage{ChannelID: c.ID, OrganizationID: c.AccountRef, OrganizationURN: urn, Name: c.AccountName,
			VanityName: vanity, Role: role, Status: c.Status, DelegatedBy: c.DelegatedBy}
		if c.ExpiresAt != nil {
			p.ExpiresAt = c.ExpiresAt.UTC().Format("2006-01-02T15:04:05Z")
		}
		out = append(out, p)
	}
	writeJSON(w, http.StatusOK, map[string]any{"pages": out})
}

// routeMarketingLinkedInOrg registers the Company Page connect routes (from routeMarketing).
func (s *Server) routeMarketingLinkedInOrg(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/marketing/linkedin-org/connect", s.handleLinkedInOrgConnectGo)
	mux.HandleFunc("POST /v1/marketing/linkedin-org/connect", s.handleLinkedInOrgConnect)
	mux.HandleFunc("GET /v1/marketing/linkedin-org/callback", s.handleLinkedInOrgCallback)
	// = LinkedInOrgCallbackPath, a literal for the route scans; the connect
	// test calls it by the constant, so the two cannot drift apart
	mux.HandleFunc("GET /api/v1/marketing/linkedin-org/callback", s.handleLinkedInOrgCallback)
	s.marketingRoute(mux, "GET /v1/marketing/linkedin-org/pages", s.handleLinkedInOrgPages)
	mux.HandleFunc("OPTIONS /v1/marketing/linkedin-org/pages", s.marketingPreflightFor("GET"))
	mux.HandleFunc("OPTIONS /v1/marketing/linkedin-org/connect", s.marketingPreflightFor("GET, POST"))
}
