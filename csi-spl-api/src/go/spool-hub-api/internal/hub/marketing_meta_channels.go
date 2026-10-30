package hub

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Connecting a Facebook Page and its Instagram Professional account (spec
// 090 T033, SPL-4254; spec.md §16.2). The LinkedIn connect's shape
// (marketing_channels.go), on the sign-in Meta app (meta-app-setup.md):
//
//	GET  /v1/marketing/facebook/connect?workspace=<id>  302 to Meta's OAuth
//	     dialog, asking the five Page + Instagram permissions
//	POST /v1/marketing/facebook/connect?workspace=<id>  {authorize_url} (WUI)
//	GET  /v1/marketing/facebook/callback?code&state     Meta's redirect, also
//	     at MetaCallbackPath, the path the WUI host's rewrite keeps
//	GET  /v1/marketing/facebook/pages                   the workspace's
//	     connected Pages, each with its Instagram account, never a token
//
// Who may connect is the LinkedIn rule (marketingConnectMember). The
// callback trusts only the signed state (15 minutes). It trades the code for
// a long-lived user token, lists the member's Pages (/me/accounts), seals
// each Page Access Token (KMS envelope, T005) and stores one channel per
// Page (facebook_page) and one per linked Instagram account
// (instagram_business, which publishes with its Page's token). The user
// token itself is never stored. Every channel is connected with
// auto_publish off: nothing is published without a human's approval
// (spec.md §16.3, §17.1). While the Meta app is not configured on this hub,
// every route answers 503 not_configured.

// MarketingMeta is what the hub needs to connect Facebook Pages and
// Instagram accounts. nil in Options = not configured.
type MarketingMeta struct {
	Meta   *marketing.Meta
	Sealer *marketing.Sealer
	// AppURL is the WUI origin: the page the callback points back to, the
	// blog index and the post links (T034).
	AppURL string
	// APIURL is the hub's public origin: the re-connect link mailed after
	// Meta refuses a token (T034). "" = the mail names the settings page.
	APIURL string
	// Mail tells the channel holder of a failure or a refused token (T034);
	// nil = no mail relay (log only).
	Mail func(ctx context.Context, to, subject, body string) error
	// ContainerWait is the pause between reads of an Instagram container's
	// status (T034); 0 = metaContainerWait.
	ContainerWait time.Duration
	// DailyCap is the most API posts a channel makes in 24 h (T034); 0 =
	// metaDailyCap. Instagram's own 100 still bounds it.
	DailyCap int
}

// ConnectLink is the one-click Facebook (re-)connect link for workspace.
func (m *MarketingMeta) ConnectLink(workspace string) string {
	if m.APIURL == "" {
		return m.AppURL + " (Tenant settings, Marketing: connect Facebook)"
	}
	return m.APIURL + "/v1/marketing/facebook/connect?" + url.Values{"workspace": {workspace}}.Encode()
}

// MetaCallbackPath is the callback as registered in the Meta app
// (meta-app-setup.md 2.1): on the WUI origin, whose Hosting rewrite
// (render-wui-firebase-json.sh) forwards it to the hub with the path as is.
const MetaCallbackPath = "/api/v1/marketing/facebook/callback"

// metaAutoPublish: a Meta channel holds every post for approval.
const metaAutoPublish = false

// metaConfigured writes 503 not_configured (or 501 for a store without
// marketing channels) unless the Meta connect can run.
func (s *Server) metaConfigured(w http.ResponseWriter) (*MarketingMeta, store.Marketing, bool) {
	m := s.o.MarketingMeta
	if m == nil || m.Meta == nil || m.Sealer == nil {
		writeErr(w, http.StatusServiceUnavailable, "not_configured", "the Meta app is not configured on this hub")
		return nil, nil, false
	}
	mk, has := s.o.Store.(store.Marketing)
	if !has {
		s.marketingStoreOK(w)
		return nil, nil, false
	}
	return m, mk, true
}

// metaAuthorizeURL starts a connect for (tenant, hum): the dialog URL.
func (s *Server) metaAuthorizeURL(w http.ResponseWriter, r *http.Request) (string, bool) {
	tenant, hum, ok := s.marketingConnectMember(w, r)
	if !ok {
		return "", false
	}
	m, _, ok := s.metaConfigured(w)
	if !ok {
		return "", false
	}
	st := m.Meta.NewState(marketing.State{Tenant: tenant, Member: hum, Exp: s.o.Now().Add(connectStateTTL).Unix()})
	au, err := m.Meta.AuthorizeURL(st)
	if err != nil {
		s.o.Log.Error().Str("err", err.Error()).Msg("marketing: meta connect off")
		writeErr(w, http.StatusServiceUnavailable, "not_configured", "the Meta app is not configured on this hub")
		return "", false
	}
	return au, true
}

// GET /v1/marketing/facebook/connect: the browser goes on to Meta.
func (s *Server) handleMetaConnectGo(w http.ResponseWriter, r *http.Request) {
	if au, ok := s.metaAuthorizeURL(w, r); ok {
		http.Redirect(w, r, au, http.StatusFound)
	}
}

// POST /v1/marketing/facebook/connect: the WUI gets the URL to open.
func (s *Server) handleMetaConnect(w http.ResponseWriter, r *http.Request) {
	if au, ok := s.metaAuthorizeURL(w, r); ok {
		writeJSON(w, http.StatusOK, map[string]string{"authorize_url": au})
	}
}

// GET /v1/marketing/facebook/callback: Meta sends the browser back here.
func (s *Server) handleMetaCallback(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	m, mk, ok := s.metaConfigured(w)
	if !ok {
		return
	}
	q := r.URL.Query()
	st, err := m.Meta.VerifyState(q.Get("state"), s.o.Now())
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_state", "this connect link is not valid or has expired; start again")
		return
	}
	if e := q.Get("error"); e != "" {
		connectPageBack(w, http.StatusOK, "Facebook was not connected", "Meta answered: "+e+". Nothing was stored.", m.AppURL)
		return
	}
	if s.marketingDemo(w, st.Tenant) || !s.marketingOn(w, r, st.Tenant) {
		return
	}
	pages, igs, err := s.connectMeta(r.Context(), m, mk, st, q.Get("code"))
	if err != nil {
		s.o.Log.Error().Str("tenant", st.Tenant).Str("member", st.Member).Str("err", err.Error()).Msg("marketing: meta connect failed")
		connectPageBack(w, http.StatusBadGateway, "Facebook was not connected",
			"The exchange with Meta failed. Open the connect link again.", m.AppURL)
		return
	}
	s.o.Log.Info().Str("tenant", st.Tenant).Str("member", st.Member).Int("pages", pages).Int("instagram", igs).Msg("marketing: meta connected")
	if pages == 0 {
		connectPageBack(w, http.StatusOK, "No Facebook Page found",
			"Meta lists no Page you manage for this app. Nothing was stored. Grant the app a Page, then connect again.", m.AppURL)
		return
	}
	connectPageBack(w, http.StatusOK, "Facebook connected",
		"Connected "+strconv.Itoa(pages)+" Facebook Page(s) and "+strconv.Itoa(igs)+" Instagram account(s) for workspace "+
			st.Tenant+". Nothing is published on them without your approval.", m.AppURL)
}

// connectMeta exchanges the code, lists the member's Pages and stores a
// channel per Page and per linked Instagram account, each with its Page's
// sealed token. Errors carry no token text.
func (s *Server) connectMeta(ctx context.Context, m *MarketingMeta, mk store.Marketing, st marketing.State, code string) (pages, igs int, err error) {
	if code == "" {
		return 0, 0, errors.New("no code in the callback")
	}
	tok, err := m.Meta.ExchangeLongLivedUserToken(ctx, code)
	if err != nil {
		return 0, 0, err
	}
	accts, err := m.Meta.ListAccounts(ctx, tok.Access)
	if err != nil {
		return 0, 0, err
	}
	for _, p := range accts {
		if p.ID == "" || p.AccessToken.Reveal() == "" {
			continue
		}
		sealed, keyID, err := m.Sealer.Seal(ctx, p.AccessToken)
		if err != nil {
			return pages, igs, err
		}
		stored := store.MarketingToken{Ciphertext: sealed, KMSKeyID: keyID}
		if _, err := mk.ConnectMarketingChannel(ctx, metaPageChannel(st, p), stored, s.o.Now()); err != nil {
			return pages, igs, err
		}
		pages++
		if p.Instagram == nil || p.Instagram.ID == "" {
			continue
		}
		if _, err := mk.ConnectMarketingChannel(ctx, metaInstagramChannel(st, p), stored, s.o.Now()); err != nil {
			return pages, igs, err
		}
		igs++
	}
	return pages, igs, nil
}

// metaPageChannel is the facebook_page channel of Page p. A Page Access
// Token fetched with a long-lived user token does not expire (spec.md
// §16.1.1), so it has no expires_at.
func metaPageChannel(st marketing.State, p marketing.MetaPageAccount) store.MarketingChannel {
	tasks := p.Tasks
	if tasks == nil {
		tasks = []string{}
	}
	return store.MarketingChannel{Tenant: st.Tenant, Platform: "facebook_page", AccountType: "page",
		AccountRef: p.ID, AccountName: p.Name, DelegatedBy: st.Member, AutoPublish: metaAutoPublish,
		Metadata: map[string]any{"page_id": p.ID, "tasks": tasks}}
}

// metaInstagramChannel is the instagram_business channel linked to Page p.
func metaInstagramChannel(st marketing.State, p marketing.MetaPageAccount) store.MarketingChannel {
	ig := p.Instagram
	name := ig.Username
	if name == "" {
		name = ig.Name
	}
	return store.MarketingChannel{Tenant: st.Tenant, Platform: "instagram_business", AccountType: "business",
		AccountRef: ig.ID, AccountName: name, DelegatedBy: st.Member, AutoPublish: metaAutoPublish,
		Metadata: map[string]any{"ig_user_id": ig.ID, "username": ig.Username, "page_id": p.ID}}
}

// metaPage is one connected Page in GET /v1/marketing/facebook/pages.
type metaPage struct {
	ChannelID   string          `json:"channel_id"`
	PageID      string          `json:"page_id"`
	Name        string          `json:"name"`
	Status      string          `json:"status"`
	AutoPublish bool            `json:"auto_publish"`
	DelegatedBy string          `json:"delegated_by"`
	Instagram   *metaPageInstag `json:"instagram"`
}

// metaPageInstag is the Instagram account linked to a Page; nil = none.
type metaPageInstag struct {
	ChannelID   string `json:"channel_id"`
	IGUserID    string `json:"ig_user_id"`
	Username    string `json:"username"`
	Status      string `json:"status"`
	AutoPublish bool   `json:"auto_publish"`
}

// GET /v1/marketing/facebook/pages: the workspace's connected Pages.
func (s *Server) handleMetaPages(w http.ResponseWriter, r *http.Request, tenant string) {
	w.Header().Set("Cache-Control", "no-store")
	_, mk, ok := s.metaConfigured(w)
	if !ok {
		return
	}
	chs, err := mk.MarketingChannels(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "marketing channels unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"pages": metaPages(chs)})
}

// metaPages pairs each facebook_page channel with its Instagram channel.
func metaPages(chs []store.MarketingChannel) []metaPage {
	igByPage := map[string]*metaPageInstag{}
	for _, c := range chs {
		if c.Platform == "instagram_business" {
			username, _ := c.Metadata["username"].(string)
			page, _ := c.Metadata["page_id"].(string)
			igByPage[page] = &metaPageInstag{ChannelID: c.ID, IGUserID: c.AccountRef, Username: username, Status: c.Status, AutoPublish: c.AutoPublish}
		}
	}
	out := []metaPage{}
	for _, c := range chs {
		if c.Platform == "facebook_page" {
			out = append(out, metaPage{ChannelID: c.ID, PageID: c.AccountRef, Name: c.AccountName, Status: c.Status,
				AutoPublish: c.AutoPublish, DelegatedBy: c.DelegatedBy, Instagram: igByPage[c.AccountRef]})
		}
	}
	return out
}

// routeMarketingMeta registers the Meta connect routes (from routeMarketing).
func (s *Server) routeMarketingMeta(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/marketing/facebook/connect", s.handleMetaConnectGo)
	mux.HandleFunc("POST /v1/marketing/facebook/connect", s.handleMetaConnect)
	mux.HandleFunc("GET /v1/marketing/facebook/callback", s.handleMetaCallback)
	// = MetaCallbackPath, a literal for the route scans; the connect test
	// calls it by the constant, so the two cannot drift apart
	mux.HandleFunc("GET /api/v1/marketing/facebook/callback", s.handleMetaCallback)
	s.marketingRoute(mux, "GET /v1/marketing/facebook/pages", s.handleMetaPages)
}
