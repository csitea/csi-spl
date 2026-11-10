package hub

import (
	"context"
	"errors"
	"net/http"
	"net/url"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Connecting an X (x.com) account (spec 090 X row, SPL-5194; owner HUM-10,
// t1 19ef7d51 msgs 24e18169, 8c73a054: X the same way as LinkedIn, Facebook
// and Instagram, for any business owner or admin of the workspace). The
// Meta connect's shape (marketing_meta_channels.go), on the X developer app
// (x-app-setup.md):
//
//	GET  /v1/marketing/x/connect?workspace=<id>  302 to X's consent page
//	     (OAuth 2.0 authorization code + PKCE S256)
//	POST /v1/marketing/x/connect?workspace=<id>  {authorize_url} (WUI)
//	GET  /v1/marketing/x/callback?code&state     X's redirect, also at
//	     XCallbackPath, the path the WUI host's rewrite keeps
//	GET  /v1/marketing/x/accounts                the workspace's connected
//	     X accounts, never a token
//
// Who may connect is the LinkedIn rule (marketingConnectMember: an admin,
// rbac.TenantSettings, of an allow-listed workspace with marketing on). The
// callback trusts only the signed state (15 minutes), from which it also
// derives the PKCE verifier. It trades the code for the token pair (access,
// two hours; refresh, offline.access), reads the member (users/me) and seals
// the pair as one token (KMS envelope, T005). The channel is connected with
// auto_publish off: nothing is posted without a human's press (spec.md
// §16.3, §17.1). While the X app is not configured on this hub (cnf
// marketing.x.inject "false"), every route answers 503 not_configured.
// Disconnect is the shared DELETE /v1/marketing/channels/{channel_id}.

// MarketingX is what the hub needs to connect X accounts and post with
// them. nil in Options = not configured.
type MarketingX struct {
	X      *marketing.X
	Sealer *marketing.Sealer
	// AppURL is the WUI origin: the page the callback points back to, the
	// blog index and the post links.
	AppURL string
	// APIURL is the hub's public origin: the re-connect link mailed after X
	// refuses the token. "" = the mail names the settings page.
	APIURL string
	// Mail tells the channel holder of a failure or a refused token; nil =
	// no mail relay (log only).
	Mail func(ctx context.Context, to, subject, body string) error
	// DailyCap is the most API posts a channel makes in 24 h; 0 =
	// metaDailyCap (spec.md FR-007, the same cap as every channel).
	DailyCap int
}

// ConnectLink is the one-click X (re-)connect link for workspace.
func (m *MarketingX) ConnectLink(workspace string) string {
	if m.APIURL == "" {
		return m.AppURL + " (Tenant settings, Marketing: connect X)"
	}
	return m.APIURL + "/v1/marketing/x/connect?" + url.Values{"workspace": {workspace}}.Encode()
}

// XCallbackPath is the callback as registered in the X app (x-app-setup.md
// 2): on the WUI origin, whose Hosting rewrite forwards /api/** to the hub
// with the path as is.
const XCallbackPath = "/api/v1/marketing/x/callback"

// xAutoPublish: an X channel holds every post for a human's press.
const xAutoPublish = false

// xConfigured writes 503 not_configured (or 501 for a store without
// marketing channels) unless the X connect can run.
func (s *Server) xConfigured(w http.ResponseWriter) (*MarketingX, store.Marketing, bool) {
	m := s.o.MarketingX
	if m == nil || m.X == nil || m.Sealer == nil {
		writeErr(w, http.StatusServiceUnavailable, "not_configured", "the X app is not configured on this hub")
		return nil, nil, false
	}
	mk, has := s.o.Store.(store.Marketing)
	if !has {
		s.marketingStoreOK(w)
		return nil, nil, false
	}
	return m, mk, true
}

// xAuthorizeURL starts a connect for the member: X's consent URL.
func (s *Server) xAuthorizeURL(w http.ResponseWriter, r *http.Request) (string, bool) {
	tenant, hum, ok := s.marketingConnectMember(w, r)
	if !ok {
		return "", false
	}
	m, _, ok := s.xConfigured(w)
	if !ok {
		return "", false
	}
	st := m.X.NewState(marketing.State{Tenant: tenant, Member: hum, Exp: s.o.Now().Add(connectStateTTL).Unix()})
	return m.X.AuthorizeURL(st), true
}

// GET /v1/marketing/x/connect: the browser goes on to X.
func (s *Server) handleXConnectGo(w http.ResponseWriter, r *http.Request) {
	if au, ok := s.xAuthorizeURL(w, r); ok {
		http.Redirect(w, r, au, http.StatusFound)
	}
}

// POST /v1/marketing/x/connect: the WUI gets the URL to open.
func (s *Server) handleXConnect(w http.ResponseWriter, r *http.Request) {
	if au, ok := s.xAuthorizeURL(w, r); ok {
		writeJSON(w, http.StatusOK, map[string]string{"authorize_url": au})
	}
}

// GET /v1/marketing/x/callback: X sends the browser back here.
func (s *Server) handleXCallback(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	m, mk, ok := s.xConfigured(w)
	if !ok {
		return
	}
	q := r.URL.Query()
	st, err := m.X.VerifyState(q.Get("state"), s.o.Now())
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_state", "this connect link is not valid or has expired; start again")
		return
	}
	if e := q.Get("error"); e != "" {
		connectPageBack(w, http.StatusOK, "X was not connected", "X answered: "+e+". Nothing was stored.", m.AppURL)
		return
	}
	if s.marketingDemo(w, st.Tenant) || !s.marketingOn(w, r, st.Tenant) {
		return
	}
	ch, err := s.connectX(r.Context(), m, mk, st, q.Get("code"), q.Get("state"))
	if err != nil {
		s.o.Log.Error().Str("tenant", st.Tenant).Str("member", st.Member).Str("err", err.Error()).Msg("marketing: x connect failed")
		connectPageBack(w, http.StatusBadGateway, "X was not connected",
			"The exchange with X failed. Nothing was stored. Open the connect link again.", m.AppURL)
		return
	}
	s.o.Log.Info().Str("tenant", st.Tenant).Str("channel", ch.ID).Str("member", st.Member).Msg("marketing: x connected")
	connectPageBack(w, http.StatusOK, "X connected",
		"Connected "+ch.AccountName+" for workspace "+st.Tenant+". Nothing is posted on it until a member presses Publish.", m.AppURL)
}

// connectX exchanges the code, reads the member, seals the token pair and
// stores the channel. Errors carry no token text.
func (s *Server) connectX(ctx context.Context, m *MarketingX, mk store.Marketing, st marketing.State, code, state string) (store.MarketingChannel, error) {
	if code == "" {
		return store.MarketingChannel{}, errors.New("no code in the callback")
	}
	tok, err := m.X.Exchange(ctx, code, state, s.o.Now())
	if err != nil {
		return store.MarketingChannel{}, err
	}
	u, err := m.X.Me(ctx, tok.Access)
	if err != nil {
		return store.MarketingChannel{}, err
	}
	sealed, keyID, err := m.Sealer.Seal(ctx, tok.Bundle())
	if err != nil {
		return store.MarketingChannel{}, err
	}
	name := "@" + u.Username
	if u.Username == "" {
		name = u.Name
	}
	return mk.ConnectMarketingChannel(ctx, store.MarketingChannel{Tenant: st.Tenant, Platform: store.MarketingPlatformX,
		AccountType: "personal", AccountRef: u.ID, AccountName: name, DelegatedBy: st.Member, AutoPublish: xAutoPublish,
		Metadata: map[string]any{"username": u.Username, "name": u.Name}},
		store.MarketingToken{Ciphertext: sealed, KMSKeyID: keyID}, s.o.Now())
}

// xAccount is one connected X account in GET /v1/marketing/x/accounts.
type xAccount struct {
	ChannelID   string `json:"channel_id"`
	UserID      string `json:"user_id"`
	Username    string `json:"username"`
	Name        string `json:"name"`
	Status      string `json:"status"`
	DelegatedBy string `json:"delegated_by"`
}

// GET /v1/marketing/x/accounts: the workspace's connected X accounts.
func (s *Server) handleXAccounts(w http.ResponseWriter, r *http.Request, tenant string) {
	w.Header().Set("Cache-Control", "no-store")
	_, mk, ok := s.xConfigured(w)
	if !ok {
		return
	}
	chs, err := mk.MarketingChannels(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "marketing channels unavailable")
		return
	}
	out := []xAccount{}
	for _, c := range chs {
		if c.Platform == store.MarketingPlatformX {
			username, _ := c.Metadata["username"].(string)
			name, _ := c.Metadata["name"].(string)
			out = append(out, xAccount{ChannelID: c.ID, UserID: c.AccountRef, Username: username, Name: name,
				Status: c.Status, DelegatedBy: c.DelegatedBy})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"accounts": out})
}

// routeMarketingX registers the X connect routes (from routeMarketing).
func (s *Server) routeMarketingX(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/marketing/x/connect", s.handleXConnectGo)
	mux.HandleFunc("POST /v1/marketing/x/connect", s.handleXConnect)
	mux.HandleFunc("GET /v1/marketing/x/callback", s.handleXCallback)
	// = XCallbackPath, a literal for the route scans; the connect test calls
	// it by the constant, so the two cannot drift apart
	mux.HandleFunc("GET /api/v1/marketing/x/callback", s.handleXCallback)
	s.marketingRoute(mux, "GET /v1/marketing/x/accounts", s.handleXAccounts)
	mux.HandleFunc("OPTIONS /v1/marketing/x/accounts", s.marketingPreflightFor("GET"))
	mux.HandleFunc("OPTIONS /v1/marketing/x/connect", s.marketingPreflightFor("GET, POST"))
}
