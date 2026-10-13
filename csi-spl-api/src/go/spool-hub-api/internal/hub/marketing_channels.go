package hub

import (
	"context"
	"errors"
	"html"
	"net/http"
	"net/url"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Connecting a LinkedIn account (spec 090 T006, SPL-1634; owner HUM-10,
// topic add4fbf4 msg 489d18e6: the blog shares on his LinkedIn profile with
// nothing for him to do but connect once).
//
//	GET  /v1/marketing/linkedin/connect?workspace=<id>  302 to LinkedIn: the
//	     one-click link (a browser navigation, the member's session cookie)
//	POST /v1/marketing/linkedin/connect?workspace=<id>  {authorize_url} (WUI)
//	GET  /v1/marketing/linkedin/callback?code&state     LinkedIn's redirect
//	GET  /v1/marketing/channels                         the workspace's
//	     connected accounts, never a token (marketingRoute)
//
// Only an admin (rbac.TenantSettings) of an allow-listed workspace with
// marketing switched on may connect. The callback reaches the hub through
// the WUI host's /api rewrite, which carries no session cookie, so it trusts
// only the signed state: the workspace and the member who started, valid 15
// minutes. The token is sealed (KMS envelope, T005) before the store sees
// it, and it never reaches a log or an answer.

// MarketingLinkedIn is what the hub needs to connect LinkedIn accounts and
// share with them. nil in Options = not configured: connect answers 503 and
// the share sweep does nothing.
type MarketingLinkedIn struct {
	LinkedIn *marketing.LinkedIn
	Sealer   *marketing.Sealer
	// AppURL is the WUI origin: the blog index, the post links and the page
	// the callback points back to.
	AppURL string
	// APIURL is the hub's public origin, where the member's session cookie
	// reaches the hub: the re-connect link in the reminder.
	APIURL string
	// Mail sends the re-connect reminder; nil = no mail relay (log only).
	Mail func(ctx context.Context, to, subject, body string) error
}

// connectStateTTL is how long a started connect may take.
const connectStateTTL = 15 * time.Minute

// connectAutoPublish: a channel connected here shares every new blog post
// with no review (the owner's word, 489d18e6).
const connectAutoPublish = true

// ConnectLink is the one-click (re-)connect link for workspace.
func (m *MarketingLinkedIn) ConnectLink(workspace string) string {
	return m.APIURL + "/v1/marketing/linkedin/connect?" + url.Values{"workspace": {workspace}}.Encode()
}

// marketingConnectActor resolves who may start a connect, and for which
// workspace: ?workspace=<id> (a member of it), else the session's own.
func (s *Server) marketingConnectActor(w http.ResponseWriter, r *http.Request) (tenant, hum string, ok bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if ws := r.URL.Query().Get("workspace"); ws != "" && s.o.Auth != nil {
		sess, has := s.o.Auth.SessionFromRequest(r)
		if !has || sess.HumanID == "" {
			writeErr(w, http.StatusUnauthorized, "view_door", "sign in to spool-hub first, then open this link again")
			return "", "", false
		}
		t, found := s.loadTenant(w, r, ws)
		if !found {
			return "", "", false
		}
		tenant, hum = t.ID, sess.HumanID
	} else {
		t, h, found := s.humanTenant(w, r)
		if !found {
			return "", "", false
		}
		tenant, hum = t.ID, h
	}
	if s.marketingDemo(w, tenant) || !s.marketingOn(w, r, tenant) {
		return "", "", false
	}
	if hum == "" {
		writeForbidden(w, rbac.TenantSettings, "connecting an account needs a member session")
		return "", "", false
	}
	if !s.permit(w, r, tenant, hum, rbac.TenantSettings) {
		return "", "", false
	}
	if s.o.MarketingLinkedIn == nil {
		writeErr(w, http.StatusServiceUnavailable, "linkedin_not_configured", "the LinkedIn app is not configured on this hub")
		return "", "", false
	}
	if _, has := s.o.Store.(store.Marketing); !has {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no marketing channels")
		return "", "", false
	}
	return tenant, hum, true
}

// marketingOn writes 404 unless tenant is allow-listed and switched on.
func (s *Server) marketingOn(w http.ResponseWriter, r *http.Request, tenant string) bool {
	if !s.marketingListed(tenant) {
		writeMarketingOff(w)
		return false
	}
	on, err := s.marketingEnabled(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "marketing switch unavailable")
		return false
	}
	if !on {
		writeMarketingOff(w)
	}
	return on
}

func (s *Server) marketingAuthorizeURL(tenant, hum string) string {
	li := s.o.MarketingLinkedIn.LinkedIn
	st := li.NewState(marketing.State{Tenant: tenant, Member: hum, Exp: s.o.Now().Add(connectStateTTL).Unix()})
	return li.AuthorizeURL(st)
}

// GET /v1/marketing/linkedin/connect: the browser goes on to LinkedIn.
func (s *Server) handleLinkedInConnectGo(w http.ResponseWriter, r *http.Request) {
	if tenant, hum, ok := s.marketingConnectActor(w, r); ok {
		http.Redirect(w, r, s.marketingAuthorizeURL(tenant, hum), http.StatusFound)
	}
}

// POST /v1/marketing/linkedin/connect: the WUI gets the URL to open.
func (s *Server) handleLinkedInConnect(w http.ResponseWriter, r *http.Request) {
	if tenant, hum, ok := s.marketingConnectActor(w, r); ok {
		writeJSON(w, http.StatusOK, map[string]string{"authorize_url": s.marketingAuthorizeURL(tenant, hum)})
	}
}

// GET /v1/marketing/linkedin/callback: LinkedIn sends the browser back here.
func (s *Server) handleLinkedInCallback(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	m := s.o.MarketingLinkedIn
	mk, has := s.o.Store.(store.Marketing)
	if m == nil || !has {
		writeErr(w, http.StatusServiceUnavailable, "linkedin_not_configured", "the LinkedIn app is not configured on this hub")
		return
	}
	q := r.URL.Query()
	st, err := m.LinkedIn.VerifyState(q.Get("state"), s.o.Now())
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_state", "this connect link is not valid or has expired; start again")
		return
	}
	if e := q.Get("error"); e != "" {
		s.connectPage(w, http.StatusOK, "LinkedIn was not connected", "LinkedIn answered: "+e+". Nothing was stored.")
		return
	}
	if s.marketingDemo(w, st.Tenant) || !s.marketingOn(w, r, st.Tenant) {
		return
	}
	ch, err := s.connectLinkedIn(r.Context(), m, mk, st, q.Get("code"))
	if err != nil {
		s.o.Log.Error().Str("tenant", st.Tenant).Str("member", st.Member).Str("err", err.Error()).Msg("marketing: linkedin connect failed")
		s.connectPage(w, http.StatusBadGateway, "LinkedIn was not connected", "The exchange with LinkedIn failed. Nothing was stored. Open the connect link again.")
		return
	}
	s.o.Log.Info().Str("tenant", st.Tenant).Str("channel", ch.ID).Str("member", st.Member).Msg("marketing: linkedin connected")
	until := ""
	if ch.ExpiresAt != nil {
		until = " LinkedIn lets this connection last until " + ch.ExpiresAt.UTC().Format("2006-01-02") +
			"; a week before that you get a mail with a one-click link to renew it."
	}
	s.connectPage(w, http.StatusOK, "LinkedIn connected",
		"Connected as "+ch.AccountName+" for workspace "+st.Tenant+". Every new blog post is shared on this profile."+until)
}

// connectLinkedIn exchanges the code, reads the member, seals the token and
// stores the channel. Errors carry no token text.
func (s *Server) connectLinkedIn(ctx context.Context, m *MarketingLinkedIn, mk store.Marketing, st marketing.State, code string) (store.MarketingChannel, error) {
	if code == "" {
		return store.MarketingChannel{}, errors.New("no code in the callback")
	}
	now := s.o.Now()
	tok, err := m.LinkedIn.Exchange(ctx, code, now)
	if err != nil {
		return store.MarketingChannel{}, err
	}
	mem, err := m.LinkedIn.Userinfo(ctx, tok.Access)
	if err != nil {
		return store.MarketingChannel{}, err
	}
	sealed, keyID, err := m.Sealer.Seal(ctx, tok.Access)
	if err != nil {
		return store.MarketingChannel{}, err
	}
	exp := tok.ExpiresAt
	return mk.ConnectMarketingChannel(ctx, store.MarketingChannel{Tenant: st.Tenant, Platform: "linkedin",
		AccountRef: mem.Sub, AccountName: mem.Name, DelegatedBy: st.Member, AutoPublish: connectAutoPublish, ExpiresAt: &exp},
		store.MarketingToken{Ciphertext: sealed, KMSKeyID: keyID}, now)
}

// connectPage answers the browser with one short, escaped page.
func (s *Server) connectPage(w http.ResponseWriter, status int, title, text string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
	w.WriteHeader(status)
	back := ""
	if m := s.o.MarketingLinkedIn; m != nil && m.AppURL != "" {
		back = `<p><a href="` + html.EscapeString(m.AppURL) + `">Back to spool-hub</a></p>`
	}
	_, _ = w.Write([]byte(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>` +
		html.EscapeString(title) + `</title></head><body style="font-family:sans-serif;max-width:36em;margin:3em auto;padding:0 1em"><h1>` +
		html.EscapeString(title) + `</h1><p>` + html.EscapeString(text) + `</p>` + back + `</body></html>`))
}

// GET /v1/marketing/channels: the workspace's connected accounts.
func (s *Server) handleMarketingChannels(w http.ResponseWriter, r *http.Request, tenant string) {
	w.Header().Set("Cache-Control", "no-store")
	mk, ok := s.o.Store.(store.Marketing)
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"channels": []store.MarketingChannel{}})
		return
	}
	chs, err := mk.MarketingChannels(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "marketing channels unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"channels": chs})
}

// routeMarketingChannels registers the connect routes (from routeMarketing).
func (s *Server) routeMarketingChannels(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/marketing/linkedin/connect", s.handleLinkedInConnectGo)
	mux.HandleFunc("POST /v1/marketing/linkedin/connect", s.handleLinkedInConnect)
	mux.HandleFunc("GET /v1/marketing/linkedin/callback", s.handleLinkedInCallback)
	s.marketingRoute(mux, "GET /v1/marketing/channels", s.handleMarketingChannels)
}
