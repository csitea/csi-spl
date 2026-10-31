package hub

import (
	"context"
	"crypto/subtle"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A member connects their own Google Calendar (spec 149, build row B5,
// SPL-3208): the connect handshake, the status, the disconnect.
//
//	GET    /v1/me/google-calendar                     the member's connection, never a token
//	POST   /v1/me/google-calendar/connect?workspace=  {authorize_url} (the WUI)
//	GET    /v1/me/google-calendar/connect?workspace=  302 to Google (a plain link)
//	GET    /v1/me/google-calendar/callback?code&state Google's redirect, on the WUI origin
//	DELETE /v1/me/google-calendar?remove_imported=0|1 revoke at Google, delete the row
//	POST   /v1/me/google-calendar/sync?workspace=     "Sync now": 202, the cycle runs (gcal_sync.go)
//
// The kill switch is GcalConnect.Workspaces (cnf gcal.workspaces): outside it
// every route answers 404 not_found (section 2.9). The callback carries no
// session, so it trusts the signed state (workspace, member, 15 min) only
// together with the nonce cookie the connect set in the member's browser
// (P3): a leaked state alone connects nobody's Google account. Both tokens
// are sealed under GcalPurpose before the store sees them, and never reach
// a log line or an answer.

// GcalConnect is what the hub needs for the Google Calendar connect. nil in
// Options = off: every route answers 404. Google or Sealer nil = not
// configured: connect answers 503 gcal_not_configured (section 2.8).
type GcalConnect struct {
	Google *gcal.Google
	Sealer *marketing.Sealer
	// Workspaces is the allow-list (cnf gcal.workspaces): workspace ids, or
	// the one entry "all". Empty = off everywhere.
	Workspaces []string
	// The nonce cookie: cnf SPOOL_HUB_AUTH_STATE_COOKIE_NAME (the one cookie
	// Hosting forwards) and the auth cookie domain and Secure flag.
	CookieName   string
	CookieDomain string
	CookieSecure bool
	// WorkspaceURL answers the WUI origin of a workspace, where the callback
	// sends the browser back (GcalWorkspaceURL).
	WorkspaceURL func(tenant string) string
	// ReadCalendars: the cnf scopes hold a read scope, so the sync reads the
	// member's existing Google calendars in (GcalReadsCalendars, poll
	// d93654e1 B).
	ReadCalendars bool
}

// GcalPurpose is the AAD the calendar tokens are sealed under (spec 149
// 2.4, P6): a calendar token never opens as a marketing token.
const GcalPurpose = "spool-gcal-token/v1"

// GcalCallbackPath is the redirect URI's path, on the WUI origin (Hosting's
// /v1/** rewrite reaches the hub); the owner registers it on the client (S3).
const GcalCallbackPath = "/v1/me/google-calendar/callback"

// gcalCookiePath keeps the nonce cookie on the connect routes only.
const gcalCookiePath = "/v1/me/google-calendar/"

// gcalStateTTL is how long a started connect may take.
const gcalStateTTL = 15 * time.Minute

// gcalSettingsPath is the WUI settings section the callback lands on, its
// query open for one more parameter.
const gcalSettingsPath = "/?settings=calendar-google&"

// GcalCalendarTitle is the target calendar's name (spec 149 2.3, P4).
func GcalCalendarTitle(t store.Tenant) string {
	name := t.DisplayName
	if name == "" {
		name = t.ID
	}
	return "Spool Hub (" + name + ")"
}

// GcalWorkspaceURL builds GcalConnect.WorkspaceURL from the tenant host
// pattern ("{tenant}.<fqdn>"): https://<tenant>.<fqdn>, and the apex
// https://<fqdn> for the apex workspace. With no pattern every workspace
// lands on appURL.
func GcalWorkspaceURL(pattern, apexTenant, appURL string) func(string) string {
	appURL = strings.TrimRight(appURL, "/")
	apex, ok := strings.CutPrefix(pattern, "{tenant}.")
	return func(tenant string) string {
		switch {
		case !ok || apex == "":
			return appURL
		case tenant == apexTenant:
			return "https://" + apex
		default:
			return "https://" + tenant + "." + apex
		}
	}
}

func (g *GcalConnect) listed(tenant string) bool {
	return g != nil && (slices.Equal(g.Workspaces, []string{"all"}) || slices.Contains(g.Workspaces, tenant))
}

func (g *GcalConnect) configured() bool {
	return g != nil && g.Google != nil && g.Sealer != nil
}

func writeGcalOff(w http.ResponseWriter) {
	writeErr(w, http.StatusNotFound, "not_found", "google calendar is not available in this workspace")
}

func writeGcalNotConfigured(w http.ResponseWriter) {
	writeErr(w, http.StatusServiceUnavailable, "gcal_not_configured", "google calendar is not configured on this hub")
}

// gcalMember resolves the signed-in member and the workspace (?workspace=<id>
// of which they are a member, else the session's own), checks perm, and
// writes 404 when the workspace is not on the list or the store keeps no
// connections.
func (s *Server) gcalMember(w http.ResponseWriter, r *http.Request, perm string) (store.Tenant, string, store.Gcal, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.gcalWorkspace(w, r)
	if !ok {
		return store.Tenant{}, "", nil, false
	}
	if hum == "" {
		writeForbidden(w, perm, "google calendar needs a signed-in member session")
		return store.Tenant{}, "", nil, false
	}
	// the role first: a demo_user is refused (403) wherever it asks
	if !s.permit(w, r, t.ID, hum, perm) {
		return store.Tenant{}, "", nil, false
	}
	gs, has := s.o.Store.(store.Gcal)
	if !s.o.Gcal.listed(t.ID) || !has {
		writeGcalOff(w)
		return store.Tenant{}, "", nil, false
	}
	return t, hum, gs, true
}

func (s *Server) gcalWorkspace(w http.ResponseWriter, r *http.Request) (store.Tenant, string, bool) {
	ws := r.URL.Query().Get("workspace")
	if ws == "" || s.o.Auth == nil {
		return s.humanTenant(w, r)
	}
	sess, has := s.o.Auth.SessionFromRequest(r)
	if !has || sess.HumanID == "" {
		writeErr(w, http.StatusUnauthorized, "view_door", "sign in to spool-hub first, then open this link again")
		return store.Tenant{}, "", false
	}
	t, found := s.loadTenant(w, r, ws)
	return t, sess.HumanID, found
}

// gcalStart signs the state, sets the nonce cookie and answers the URL of
// Google's consent page; false after writing the refusal.
func (s *Server) gcalStart(w http.ResponseWriter, r *http.Request) (string, bool) {
	t, hum, _, ok := s.gcalMember(w, r, rbac.SelfKeys)
	if !ok {
		return "", false
	}
	g := s.o.Gcal
	if !g.configured() {
		writeGcalNotConfigured(w)
		return "", false
	}
	state, nonce := g.Google.NewState(gcal.State{Tenant: t.ID, Member: hum, Exp: s.o.Now().Add(gcalStateTTL).Unix()})
	// nosemgrep: go.lang.security.audit.net.cookie-missing-secure.cookie-missing-secure -- Secure = the auth cookie posture (SPOOL_HUB_AUTH_COOKIE_SECURE, "true" in dev+prd cnf), as the sign-in state cookie.
	http.SetCookie(w, &http.Cookie{
		Name: g.CookieName, Value: nonce, Path: gcalCookiePath, Domain: g.CookieDomain,
		MaxAge: int(gcalStateTTL.Seconds()), HttpOnly: true, Secure: g.CookieSecure, SameSite: http.SameSiteLaxMode,
	})
	return g.Google.AuthorizeURL(state), true
}

// POST /v1/me/google-calendar/connect: the WUI gets the URL to open.
func (s *Server) handleGcalConnect(w http.ResponseWriter, r *http.Request) {
	if u, ok := s.gcalStart(w, r); ok {
		writeJSON(w, http.StatusOK, map[string]string{"authorize_url": u})
	}
}

// GET /v1/me/google-calendar/connect: the browser goes on to Google.
func (s *Server) handleGcalConnectGo(w http.ResponseWriter, r *http.Request) {
	if u, ok := s.gcalStart(w, r); ok {
		// nosemgrep: go.lang.security.injection.open-redirect.open-redirect -- the target is the configured Google consent page (cnf), not a request value.
		http.Redirect(w, r, u, http.StatusFound)
	}
}

// gcalVerify checks the state and that this browser started it (the nonce
// cookie), and clears the cookie; false after writing 400 invalid_state.
func (s *Server) gcalVerify(w http.ResponseWriter, r *http.Request) (gcal.State, bool) {
	g := s.o.Gcal
	// nosemgrep: go.lang.security.audit.net.cookie-missing-secure.cookie-missing-secure -- clears the nonce cookie; Secure as when it was set.
	http.SetCookie(w, &http.Cookie{Name: g.CookieName, Value: "", Path: gcalCookiePath, Domain: g.CookieDomain,
		MaxAge: -1, HttpOnly: true, Secure: g.CookieSecure, SameSite: http.SameSiteLaxMode})
	st, err := g.Google.VerifyState(r.URL.Query().Get("state"), s.o.Now())
	c, cerr := r.Cookie(g.CookieName)
	if err != nil || cerr != nil || subtle.ConstantTimeCompare([]byte(c.Value), []byte(st.Nonce)) != 1 {
		s.connectPage(w, http.StatusBadRequest, "Google Calendar was not connected",
			"This connect link is not valid, has expired or was started in another browser (invalid_state). Nothing was stored. Start again from the settings.")
		return gcal.State{}, false
	}
	return st, true
}

// GET /v1/me/google-calendar/callback: Google sends the browser back here.
func (s *Server) handleGcalCallback(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	g := s.o.Gcal
	gs, has := s.o.Store.(store.Gcal)
	if g == nil || !has {
		writeGcalOff(w)
		return
	}
	if !g.configured() {
		writeGcalNotConfigured(w)
		return
	}
	st, ok := s.gcalVerify(w, r)
	if !ok {
		return
	}
	if !g.listed(st.Tenant) {
		writeGcalOff(w)
		return
	}
	back := s.gcalBackURL(st.Tenant)
	if r.URL.Query().Get("error") != "" {
		http.Redirect(w, r, back+"gcal_error=cancelled", http.StatusFound)
		return
	}
	conn, err := s.connectGcal(r.Context(), gs, st, r.URL.Query().Get("code"))
	if errors.Is(err, gcal.ErrScopeMissing) {
		s.o.Log.Warn().Str("tenant", st.Tenant).Str("member", st.Member).Str("err", err.Error()).Msg("gcal: connect refused, calendar permission not granted")
		http.Redirect(w, r, back+"gcal_error=scope_missing", http.StatusFound)
		return
	}
	// an expired or already used code (a reload of this page): the member
	// connects again, nothing is wrong with the hub (SPL-4492)
	if errors.Is(err, gcal.ErrInvalidGrant) {
		s.o.Log.Warn().Str("tenant", st.Tenant).Str("member", st.Member).Str("err", err.Error()).Msg("gcal: connect refused, the code expired or was used")
		http.Redirect(w, r, back+"gcal_error=code_expired", http.StatusFound)
		return
	}
	if err != nil {
		s.o.Log.Error().Str("tenant", st.Tenant).Str("member", st.Member).Str("err", err.Error()).Msg("gcal: connect failed")
		http.Redirect(w, r, back+"gcal_error=exchange_failed", http.StatusFound)
		return
	}
	s.o.Log.Info().Str("tenant", st.Tenant).Str("member", st.Member).Str("connection", conn.ID).Msg("gcal: connected")
	http.Redirect(w, r, back+"gcal=connected", http.StatusFound)
}

// gcalBackURL is the settings section on the workspace's own host (section
// 2.2 step 3): the redirect URI is one fixed host, so without it a member
// who started on their workspace host would land in another workspace.
func (s *Server) gcalBackURL(tenant string) string {
	base := ""
	if f := s.o.Gcal.WorkspaceURL; f != nil {
		base = strings.TrimRight(f(tenant), "/")
	}
	return base + gcalSettingsPath
}

// connectGcal exchanges the code, reads the Google email, seals both tokens
// and stores the connection. Errors carry no token text. The target
// calendar is created by the sync cycle, which holds the lease that writes
// calendar_id (store.Gcal SetGcalCalendar).
func (s *Server) connectGcal(ctx context.Context, gs store.Gcal, st gcal.State, code string) (store.GcalConnection, error) {
	if code == "" {
		return store.GcalConnection{}, errors.New("no code in the callback")
	}
	g, now := s.o.Gcal, s.o.Now()
	tok, err := g.Google.Exchange(ctx, code, now)
	if err != nil {
		return store.GcalConnection{}, err
	}
	if tok.Refresh.Reveal() == "" {
		return store.GcalConnection{}, errors.New("google answered no refresh token")
	}
	email, err := g.Google.Userinfo(ctx, tok.Access)
	if err != nil {
		return store.GcalConnection{}, err
	}
	acc, keyID, err := g.Sealer.Seal(ctx, tok.Access)
	if err != nil {
		return store.GcalConnection{}, err
	}
	ref, _, err := g.Sealer.Seal(ctx, tok.Refresh)
	if err != nil {
		return store.GcalConnection{}, err
	}
	return gs.ConnectGcal(ctx, store.GcalConnection{Tenant: st.Tenant, Human: st.Member, GoogleEmail: email},
		store.GcalTokens{AccessSealed: acc, RefreshSealed: ref, KMSKeyID: keyID, AccessExpiry: tok.ExpiresAt}, now)
}

// gcalStatus is GET /v1/me/google-calendar: never a token or a sealed text.
type gcalStatus struct {
	Connected     bool       `json:"connected"`
	GoogleEmail   string     `json:"google_email,omitempty"`
	CalendarTitle string     `json:"calendar_title,omitempty"`
	Status        string     `json:"status,omitempty"`
	StatusDetail  string     `json:"status_detail,omitempty"`
	LastSyncedAt  *time.Time `json:"last_synced_at,omitempty"`
}

// GET /v1/me/google-calendar
func (s *Server) handleGcalGet(w http.ResponseWriter, r *http.Request) {
	t, hum, gs, ok := s.gcalMember(w, r, rbac.TopicsRead)
	if !ok {
		return
	}
	c, err := gs.GcalConnection(r.Context(), t.ID, hum)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeJSON(w, http.StatusOK, gcalStatus{})
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "google calendar connection unavailable")
	default:
		writeJSON(w, http.StatusOK, gcalStatus{Connected: true, GoogleEmail: c.GoogleEmail, CalendarTitle: GcalCalendarTitle(t),
			Status: c.Status, StatusDetail: c.StatusDetail, LastSyncedAt: c.LastSyncedAt})
	}
}

// DELETE /v1/me/google-calendar?remove_imported=0|1: revoke the grant at
// Google, then delete the connection (its map rows cascade). Events that
// came from Google stay as the member's private events unless
// remove_imported=1, which moves them to the member's trash (section 2.4).
func (s *Server) handleGcalDelete(w http.ResponseWriter, r *http.Request) {
	t, hum, gs, ok := s.gcalMember(w, r, rbac.SelfKeys)
	if !ok {
		return
	}
	rm := r.URL.Query().Get("remove_imported")
	if rm != "" && rm != "0" && rm != "1" {
		writeErr(w, http.StatusBadRequest, "bad_remove_imported", "remove_imported is 0 or 1")
		return
	}
	ctx := r.Context()
	c, err := gs.GcalConnection(ctx, t.ID, hum)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no google calendar connection")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "google calendar connection unavailable")
		return
	}
	var imported []string
	if rm == "1" {
		imported = s.gcalImported(ctx, gs, c)
	}
	s.gcalRevoke(ctx, gs, c)
	if _, err := gs.DeleteGcalConnection(ctx, t.ID, hum); err != nil && !errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusInternalServerError, "internal", "google calendar connection not deleted")
		return
	}
	s.gcalTrash(ctx, c, imported)
	s.o.Log.Info().Str("tenant", t.ID).Str("member", hum).Str("connection", c.ID).Int("removed_imported", len(imported)).Msg("gcal: disconnected")
	w.WriteHeader(http.StatusNoContent)
}

// gcalRevoke revokes the member's grant at Google (the refresh token revokes
// the whole grant). A failure is logged and the disconnect goes on: the
// member asked to cut the link, and the row with the tokens goes either way.
func (s *Server) gcalRevoke(ctx context.Context, gs store.Gcal, c store.GcalConnection) {
	g := s.o.Gcal
	if !g.configured() {
		s.o.Log.Warn().Str("connection", c.ID).Msg("gcal: disconnect without a google client, grant not revoked")
		return
	}
	tok, err := gs.GcalTokens(ctx, c.Tenant, c.Human)
	if err == nil {
		var p marketing.Plaintext
		if p, err = g.Sealer.Open(ctx, tok.RefreshSealed); err == nil {
			err = g.Google.Revoke(ctx, p)
		}
	}
	if err != nil {
		s.o.Log.Warn().Str("connection", c.ID).Str("err", err.Error()).Msg("gcal: revoke failed")
	}
}

// gcalImported answers the member's events that came from this connection's
// Google calendars: its map rows whose event carries the connection's
// source_key family `gcal:<connection>:` (section 2.5), and the read-only
// imports of the member's existing calendars (section 2.10). Read before the
// delete, which cascades the map rows away.
func (s *Server) gcalImported(ctx context.Context, gs store.Gcal, c store.GcalConnection) []string {
	cal, ok := s.o.Store.(store.Calendar)
	maps, err := gs.GcalEventMaps(ctx, c.Tenant, c.Human)
	if !ok || err != nil {
		return nil
	}
	prefix := "gcal:" + c.ID + ":"
	var ids []string
	for _, m := range maps {
		ev, err := cal.GetCalendarEvent(ctx, c.Tenant, c.Human, m.EventID)
		if err == nil && strings.HasPrefix(ev.SourceKey, prefix) {
			ids = append(ids, ev.ID)
		}
	}
	// the read-only imports of the member's existing calendars have no map
	// row (gcal_sync_sources.go): found by their key family
	if src, ok := s.o.Store.(store.CalendarSourced); ok {
		evs, _ := src.CalendarBySourceKey(ctx, c.Tenant, c.Human, gcalSourceKey(c.ID, "", ""))
		for _, ev := range evs {
			if ev.CreatorID == c.Human {
				ids = append(ids, ev.ID)
			}
		}
	}
	return ids
}

// gcalTrash moves the imported events to the member's trash.
func (s *Server) gcalTrash(ctx context.Context, c store.GcalConnection, ids []string) {
	cal, ok := s.o.Store.(store.Calendar)
	if !ok {
		return
	}
	for _, id := range ids {
		if _, err := cal.TrashCalendarEvent(ctx, c.Tenant, c.Human, id, time.Time{}, s.o.Now()); err != nil {
			s.o.Log.Warn().Str("connection", c.ID).Str("event", id).Str("err", err.Error()).Msg("gcal: imported event not removed")
		}
	}
}

// gcalPreflight: the methods of the path and the headers every browser
// route allows (as /v1/me/hours: no new request header, see 032).
func (s *Server) gcalPreflight(methods string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.allowOrigin(w, r) {
			h := w.Header()
			h.Set("Access-Control-Allow-Methods", methods)
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
			h.Set("Access-Control-Max-Age", corsMaxAge)
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// routeGcal registers the connect routes. With Options.Gcal nil they answer
// as for a workspace off the list (404), after the role check.
func (s *Server) routeGcal(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/me/google-calendar", s.handleGcalGet)
	mux.HandleFunc("DELETE /v1/me/google-calendar", s.handleGcalDelete)
	mux.HandleFunc("OPTIONS /v1/me/google-calendar", s.gcalPreflight("GET, DELETE"))
	mux.HandleFunc("GET /v1/me/google-calendar/connect", s.handleGcalConnectGo)
	mux.HandleFunc("POST /v1/me/google-calendar/connect", s.handleGcalConnect)
	mux.HandleFunc("OPTIONS /v1/me/google-calendar/connect", s.gcalPreflight("GET, POST"))
	mux.HandleFunc("POST /v1/me/google-calendar/sync", s.handleGcalSyncNow)
	mux.HandleFunc("OPTIONS /v1/me/google-calendar/sync", s.gcalPreflight("POST"))
	// = GcalCallbackPath, a literal for the demo tests' route scan; the
	// callback tests call it by the constant, so the two cannot drift apart
	mux.HandleFunc("GET /v1/me/google-calendar/callback", s.handleGcalCallback)
}
