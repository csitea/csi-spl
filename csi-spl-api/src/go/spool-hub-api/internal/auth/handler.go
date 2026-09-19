package auth

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// RoutePrefix is where the hub mounts this package (SPEC-spool-social-auth.md
// §1: /api/v1/auth/<slug>/{start,callback}). The WUI reaches it same-origin
// through the hosting rewrite, as csi-rel's storefront does.
const RoutePrefix = "/api/v1/auth/"

// stateCookie carries the nonce that binds a state to the browser that
// started the flow. Path-scoped to the auth routes.
const stateCookie = "spool_oauth_state"

// Callback failure codes, the ?auth_error= the WUI login page renders.
const (
	ErrCodeCancelled   = "cancelled"
	ErrCodeState       = "invalid_state"
	ErrCodeExchange    = "exchange_failed"
	ErrCodeUnverified  = "email_unverified"
	ErrCodeNotAllowed  = "not_allowed"
	ErrCodeUnavailable = "unavailable"
)

// Registrar is the hub's hook into a successful callback (spec 004 owns HUM-*
// ids, 006 tenancy). It returns the human id to put in the session, or
// ErrNotAllowed to refuse the sign-in. nil = no registration yet: the session
// carries the verified identity only.
type Registrar interface {
	Register(ctx context.Context, id Identity, tenant string) (humanID string, err error)
}

// ErrNotAllowed from a Registrar refuses the sign-in with auth_error=not_allowed.
var ErrNotAllowed = errors.New("auth: sign-in not allowed")

// Membership answers whether a registered human may read a tenant (spec 010
// T013, store-backed, owned by the hub). A session proves who signed in, never
// which tenant they may read (SEC-001); SessionForTenant asks this.
type Membership interface {
	Member(ctx context.Context, humanID, tenant string) (bool, error)
}

// Errors from SessionForTenant. The view door maps all of them to its 401.
var (
	ErrNoSession    = errors.New("auth: no valid session")
	ErrNoHuman      = errors.New("auth: session has no registered human")
	ErrNotMember    = errors.New("auth: human is not a member of the tenant")
	ErrNoMembership = errors.New("auth: no membership check configured")
)

// Handler serves the /api/v1/auth/* routes.
type Handler struct {
	cfg        *Config
	idps       map[string]IdP
	stateKey   []byte
	sessionKey []byte
	log        zerolog.Logger
	reg        Registrar
	members    Membership
	unlink     IdentityUnlinker
	native     *native // spec 015; nil = native sign-in off
	now        func() time.Time
}

// Options are the optional collaborators.
type Options struct {
	Registrar Registrar
	// Membership backs SessionForTenant; nil = every tenant check fails closed.
	Membership Membership
	// Unlinker severs a stored identity link when Meta's deauthorize /
	// data-deletion callback arrives (FR-013); nil = nothing is stored.
	Unlinker IdentityUnlinker
	HTTP     *http.Client // outbound to the IdPs; nil = 15s timeout client
	Now      func() time.Time
}

// New builds the handler from a validated Config.
func New(cfg *Config, log zerolog.Logger, o Options) *Handler {
	h := &Handler{
		cfg: cfg, idps: map[string]IdP{}, log: log.With().Str("component", "auth").Logger(),
		reg: o.Registrar, members: o.Membership, unlink: o.Unlinker, now: o.Now,
	}
	if h.now == nil {
		h.now = time.Now
	}
	if len(cfg.enabled) > 0 {
		h.stateKey = subkey(cfg.SessionKey, labelState)
		h.sessionKey = subkey(cfg.SessionKey, labelSession)
	}
	for _, p := range cfg.enabled {
		h.idps[p] = newIdP(cfg, p, o.HTTP)
	}
	return h
}

// Register mounts the routes on mux. Path patterns are Go 1.22 ServeMux.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET "+RoutePrefix+"providers", h.providers)
	mux.HandleFunc("GET "+RoutePrefix+"session", h.session)
	mux.HandleFunc("POST "+RoutePrefix+"logout", h.logout)
	mux.HandleFunc("GET "+RoutePrefix+"{provider}/start", h.start)
	mux.HandleFunc("GET "+RoutePrefix+"{provider}/callback", h.callback)
	h.registerFacebookCallbacks(mux)
	if h.native != nil {
		h.native.register(mux)
	}
}

// ServeHTTP makes the Handler usable on its own (tests, the auth-demo).
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	mux := http.NewServeMux()
	h.Register(mux)
	mux.ServeHTTP(w, r)
}

func (h *Handler) providers(w http.ResponseWriter, _ *http.Request) {
	list := h.cfg.Enabled()
	if list == nil {
		list = []string{}
	}
	body := map[string]any{"providers": list}
	if h.native != nil {
		body["native"] = true // spec 015: the WUI shows the email + password form
	}
	writeJSON(w, http.StatusOK, body)
}

func (h *Handler) start(w http.ResponseWriter, r *http.Request) {
	p := r.PathValue("provider")
	idp, ok := h.idps[p]
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "unknown or disabled provider")
		return
	}
	nonce, err := newNonce()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "nonce")
		return
	}
	st := statePayload{Provider: p, Nonce: nonce, Redirect: safeRedirect(r.URL.Query().Get("redirect")),
		Exp: h.now().Add(h.cfg.StateTTL).Unix()}
	if t := r.URL.Query().Get("tenant"); validTenant(t) {
		st.Tenant = t
	}
	state, err := signToken(h.stateKey, st)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "state")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name: stateCookie, Value: nonce, Path: RoutePrefix, MaxAge: int(h.cfg.StateTTL.Seconds()),
		HttpOnly: true, Secure: h.cfg.CookieSecure, SameSite: http.SameSiteLaxMode,
	})
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, idp.AuthCodeURL(state, nonce), http.StatusFound)
}

func (h *Handler) callback(w http.ResponseWriter, r *http.Request) {
	p := r.PathValue("provider")
	idp, ok := h.idps[p]
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "unknown or disabled provider")
		return
	}
	// The state cookie is single-use: cleared on every callback outcome.
	http.SetCookie(w, &http.Cookie{Name: stateCookie, Value: "", Path: RoutePrefix, MaxAge: -1,
		HttpOnly: true, Secure: h.cfg.CookieSecure, SameSite: http.SameSiteLaxMode})
	w.Header().Set("Cache-Control", "no-store")
	q := r.URL.Query()

	var st statePayload
	if err := openToken(h.stateKey, q.Get("state"), &st, h.now()); err != nil || st.Provider != p {
		h.fail(w, r, p, "/", ErrCodeState, "state signature, expiry or provider")
		return
	}
	c, err := r.Cookie(stateCookie)
	if err != nil || subtle.ConstantTimeCompare([]byte(c.Value), []byte(st.Nonce)) != 1 {
		h.fail(w, r, p, st.Redirect, ErrCodeState, "state not bound to this browser")
		return
	}
	if e := q.Get("error"); e != "" {
		h.fail(w, r, p, st.Redirect, ErrCodeCancelled, e)
		return
	}
	code := q.Get("code")
	if code == "" {
		h.fail(w, r, p, st.Redirect, ErrCodeExchange, "no code")
		return
	}
	var id Identity
	if ne, ok := idp.(nonceExchanger); ok {
		id, err = ne.ExchangeNonce(r.Context(), code, st.Nonce) // id_token nonce + PKCE (018)
	} else {
		id, err = idp.Exchange(r.Context(), code)
	}
	if errors.Is(err, errEmailUnverified) {
		h.fail(w, r, p, st.Redirect, ErrCodeUnverified, err.Error())
		return
	}
	if err != nil {
		h.fail(w, r, p, st.Redirect, ErrCodeExchange, err.Error())
		return
	}
	sess := Session{V: 1, Provider: p, Subject: id.Subject, Email: id.Email, Name: id.Name,
		Tenant: st.Tenant, IssuedAt: h.now().Unix(), Exp: h.now().Add(h.cfg.SessionTTL).Unix()}
	if h.reg != nil {
		hum, err := h.reg.Register(r.Context(), id, st.Tenant)
		if errors.Is(err, ErrNotAllowed) {
			h.fail(w, r, p, st.Redirect, ErrCodeNotAllowed, "registrar refused")
			return
		}
		if err != nil {
			h.fail(w, r, p, st.Redirect, ErrCodeUnavailable, err.Error())
			return
		}
		sess.HumanID = hum
	}
	tok, err := signToken(h.sessionKey, sess)
	if err != nil {
		h.fail(w, r, p, st.Redirect, ErrCodeUnavailable, "sign session")
		return
	}
	http.SetCookie(w, h.sessionCookie(tok, int(h.cfg.SessionTTL.Seconds())))
	h.log.Info().Str("provider", p).Str("subject", digest(id.Subject)).Str("tenant", st.Tenant).
		Msg("auth.login_ok")
	http.Redirect(w, r, h.appURL(st.Redirect, nil), http.StatusFound)
}

// session answers who the cookie belongs to: 200 + claims, or 401.
func (h *Handler) session(w http.ResponseWriter, r *http.Request) {
	s, ok := h.SessionFromRequest(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no valid session")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, s)
}

func (h *Handler) logout(w http.ResponseWriter, _ *http.Request) {
	http.SetCookie(w, h.sessionCookie("", -1))
	w.WriteHeader(http.StatusNoContent)
}

// SessionFromRequest verifies the session cookie. The hub calls this to gate
// the WUI read API (spec 003) on a signed-in person.
func (h *Handler) SessionFromRequest(r *http.Request) (Session, bool) {
	if h.sessionKey == nil {
		return Session{}, false
	}
	c, err := r.Cookie(h.cfg.CookieName)
	if err != nil {
		return Session{}, false
	}
	var s Session
	if openToken(h.sessionKey, c.Value, &s, h.now()) != nil || s.V != 1 {
		return Session{}, false
	}
	return s, true
}

// SessionForTenant is the door check for tenant-scoped reads (003 T033b): a
// valid session, a registered HUM-* in it, and Membership saying yes for the
// Host tenant. It fails closed: no Membership configured, no human, or a
// lookup error all refuse. session.t is never consulted (SEC-001).
func (h *Handler) SessionForTenant(r *http.Request, tenant string) (Session, error) {
	s, ok := h.SessionFromRequest(r)
	if !ok {
		return Session{}, ErrNoSession
	}
	if s.HumanID == "" {
		return Session{}, ErrNoHuman
	}
	if h.members == nil {
		return Session{}, ErrNoMembership
	}
	ok, err := h.members.Member(r.Context(), s.HumanID, tenant)
	if err != nil {
		return Session{}, err
	}
	if !ok {
		return Session{}, ErrNotMember
	}
	return s, nil
}

func (h *Handler) sessionCookie(v string, maxAge int) *http.Cookie {
	return &http.Cookie{Name: h.cfg.CookieName, Value: v, Path: "/", Domain: h.cfg.CookieDomain,
		MaxAge: maxAge, HttpOnly: true, Secure: h.cfg.CookieSecure, SameSite: http.SameSiteLaxMode}
}

func (h *Handler) fail(w http.ResponseWriter, r *http.Request, p, redirect, code, why string) {
	h.log.Warn().Str("provider", p).Str("reason", code).Str("detail", why).Msg("auth.callback_fail")
	http.Redirect(w, r, h.appURL("/login", url.Values{"auth_error": {code}, "redirect": {safeRedirect(redirect)}}),
		http.StatusFound)
}

func (h *Handler) appURL(path string, q url.Values) string {
	u := strings.TrimRight(h.cfg.AppURL, "/") + safeRedirect(path)
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	return u
}

// digest keeps the IdP subject out of the logs while still correlating lines.
func digest(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:6])
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}

// writeErr uses the hub's shared error envelope (003 contracts/http-v1.md).
func writeErr(w http.ResponseWriter, status int, token, detail string) {
	writeJSON(w, status, wire.ErrorBody{Error: token, Detail: detail})
}
