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
	"unicode"
	"unicode/utf8"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// RoutePrefix is where the hub mounts this package (SPEC-spool-social-auth.md
// §1: /api/v1/auth/<slug>/{start,callback}). The WUI reaches it same-origin
// through the hosting rewrite, as csi-rel's storefront does.
const RoutePrefix = "/api/v1/auth/"

// The state cookie (Config.StateCookieName) carries the nonce that binds a
// state to the browser that started the flow. Path-scoped to the auth routes,
// on Config.CookieDomain (T056: /start and /callback may be different hosts).

// Callback failure codes, the ?auth_error= the WUI login page renders.
const (
	ErrCodeCancelled  = "cancelled"
	ErrCodeState      = "invalid_state"
	ErrCodeExchange   = "exchange_failed"
	ErrCodeUnverified = "email_unverified"
	ErrCodeNotAllowed = "not_allowed"
	// ErrCodeInviteExpired: the address had a pending invite to the tenant that
	// has lapsed — a fresh invite is needed, told apart from not_allowed so the
	// login page can say so (CLE-77781, SPL-1229).
	ErrCodeInviteExpired = "invite_expired"
	ErrCodeUnavailable   = "unavailable"
	// ErrCodeInvalidDisplayName: PUT preferences display_name is not a name
	// ValidDisplayName admits.
	ErrCodeInvalidDisplayName = "invalid_display_name"
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

// ErrInviteExpired from a Registrar refuses the sign-in with
// auth_error=invite_expired: the address is invited but the invite lapsed
// (CLE-77781, SPL-1229). Distinct from ErrNotAllowed so the copy differs.
var ErrInviteExpired = errors.New("auth: invitation expired")

// InviteLander is an optional Registrar hook (SPL-1230): the workspace a
// sign-in that named NO tenant should land in — the newest live invite for the
// provider-verified address — or "" for none. Without it such a sign-in stays
// tenant-less, so an invitee who opened the plain sign-in page (not the mailed
// link) landed nowhere and the invite stayed pending.
type InviteLander interface {
	InvitedTenant(ctx context.Context, email string) (string, error)
}

// Membership answers whether a registered human may read a tenant (spec 010
// T013, store-backed, owned by the hub). A session proves who signed in, never
// which tenant they may read (SEC-001); SessionForTenant asks this.
type Membership interface {
	Member(ctx context.Context, humanID, tenant string) (bool, error)
}

// AvatarSource serves a signed-in human's own stored IdP picture (CLE-3406,
// GET /api/v1/auth/avatar): the bytes, or ErrNoAvatar when there is none.
// It needs no tenant membership: it is the person's own picture, so the
// top-right avatar shows it before an invite is accepted too.
type AvatarSource interface {
	OwnAvatar(ctx context.Context, humanID string) ([]byte, error)
}

// ErrNoAvatar from an AvatarSource: the human has no stored picture (404).
var ErrNoAvatar = errors.New("auth: no stored picture")

// Preferences is the hub's store of a person's settings (CLE-3403: the
// language; CLE-34963: the "Debug pane" checkbox). Store-backed like
// Membership; nil = the session answers preferred_locale null and
// diagnostics_enabled false, and PUT preferences is 503.
type Preferences interface {
	// PreferredLocale is the human's picked locale, "" when never picked.
	// An unknown human is ErrNoHuman.
	PreferredLocale(ctx context.Context, humanID string) (string, error)
	// SetPreferredLocale stores locale ("" clears it). Unknown human = ErrNoHuman.
	SetPreferredLocale(ctx context.Context, humanID, locale string) error
	// PreferredTheme is the human's colour theme, "" when never picked.
	// 'light' is the light-blue palette. An unknown human is ErrNoHuman.
	PreferredTheme(ctx context.Context, humanID string) (string, error)
	// SetPreferredTheme stores theme ("" clears it), already admitted by
	// IsTheme. Unknown human = ErrNoHuman.
	SetPreferredTheme(ctx context.Context, humanID, theme string) error
	// SubmitKey is how Enter behaves in the human's text fields (SPL-976),
	// one of SubmitKeys, "" when never picked. Unknown human = ErrNoHuman.
	SubmitKey(ctx context.Context, humanID string) (string, error)
	// SetSubmitKey stores it ("" clears), already admitted by IsSubmitKey.
	// Unknown human = ErrNoHuman.
	SetSubmitKey(ctx context.Context, humanID, key string) error
	// RailOrder is the human's left-rail order (SPL-979), a permutation of
	// RailTabs, nil when never reordered. Unknown human = ErrNoHuman.
	RailOrder(ctx context.Context, humanID string) ([]string, error)
	// SetRailOrder stores it (nil clears), already admitted by IsRailOrder.
	// Unknown human = ErrNoHuman.
	SetRailOrder(ctx context.Context, humanID string, order []string) error
	// ViewPref is one of the human's layout choices (topic c6994436): key is
	// a ViewPrefs key, the answer one of its values, "" when never picked.
	// Unknown human = ErrNoHuman.
	ViewPref(ctx context.Context, humanID, key string) (string, error)
	// SetViewPref stores it ("" clears), already admitted by IsViewPref.
	// Unknown human = ErrNoHuman.
	SetViewPref(ctx context.Context, humanID, key, value string) error
	// IssueColumns is the human's Issues sheet column widths (SPL-1132),
	// column -> px, nil when never sized. Unknown human = ErrNoHuman.
	IssueColumns(ctx context.Context, humanID string) (map[string]int, error)
	// SetIssueColumns stores them (nil clears), already admitted by
	// IsIssueColumns. Unknown human = ErrNoHuman.
	SetIssueColumns(ctx context.Context, humanID string, cols map[string]int) error
	// IdentityLocale is the picked locale of the human a (provider, subject)
	// sign-in belongs to; "" when there is no such human or nothing is picked.
	IdentityLocale(ctx context.Context, provider, subject string) (string, error)
	// DiagnosticsEnabled is the human's own "Debug pane" setting, false when
	// never set. An unknown human is ErrNoHuman.
	DiagnosticsEnabled(ctx context.Context, humanID string) (bool, error)
	// SetDiagnosticsEnabled stores it. Unknown human = ErrNoHuman.
	SetDiagnosticsEnabled(ctx context.Context, humanID string, on bool) error
	// DisplayName is the human's shown name (humans.display_name),
	// "" when none. An unknown human is ErrNoHuman.
	DisplayName(ctx context.Context, humanID string) (string, error)
	// SetDisplayName stores name, already admitted by ValidDisplayName.
	// Unknown human = ErrNoHuman.
	SetDisplayName(ctx context.Context, humanID, name string) error
	// Interests is the human's free-text interests (humans.interests, rdb
	// 0086, CLE-77794), "" when none. An unknown human is ErrNoHuman.
	Interests(ctx context.Context, humanID string) (string, error)
	// SetInterests stores it ("" clears it), already admitted by
	// ValidInterests. Unknown human = ErrNoHuman.
	SetInterests(ctx context.Context, humanID, interests string) error
}

// FederatedLookup tells the forgot-password route that an address it holds no
// password credential for is nonetheless a known account that signs in with an
// IdP (CLE-3451 defect 1). nil = that route cannot tell such an address from
// one that does not exist, and behaves exactly as it did before.
type FederatedLookup interface {
	// FederatedAccount lists the providers whose VERIFIED identity carries
	// email - never ProviderPassword - sorted, plus the human's picked locale
	// ("" when none). No such account is an empty list and a nil error.
	FederatedAccount(ctx context.Context, email string) (providers []string, locale string, err error)
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
	avatars    AvatarSource
	prefs      Preferences
	federated  FederatedLookup
	defLocale  string        // SPOOL_HUB_DEFAULT_LOCALE (i18n)
	native     *native       // spec 015; nil = native sign-in off
	imp        Impersonation // specs/054 act-as; nil = act-as routes off
	now        func() time.Time
	pageTenant func(*http.Request) string // SPL-959; nil = off
	audit      ActivityRecorder           // CLE-77799 auth events; nil = off
	hops       int                        // trusted proxy hops, for the audit's client IP
}

// Options are the optional collaborators.
type Options struct {
	Registrar Registrar
	// Membership backs SessionForTenant; nil = every tenant check fails closed.
	Membership Membership
	// Unlinker severs a stored identity link when Meta's deauthorize /
	// data-deletion callback arrives (FR-013); nil = nothing is stored.
	Unlinker IdentityUnlinker
	// Avatars serves GET /api/v1/auth/avatar; nil = that route answers 404.
	Avatars AvatarSource
	// Preferences backs preferred_locale (session + PUT preferences); nil = off.
	Preferences Preferences
	// Federated backs the forgot-password route's "you signed up with Google"
	// mail; nil = that route falls silent on such an address, as
	// it did before.
	Federated FederatedLookup
	// DefaultLocale is SPOOL_HUB_DEFAULT_LOCALE: the mail locale when the
	// request names none, and the locale WUI links carry no prefix for
	// (prefix_except_default). "" = i18n.DefaultLocale.
	DefaultLocale string
	// PageTenant names the tenant of the WUI page a request comes from (its
	// tenant host, SPL-959); nil or "" = the session's `t` decides, as before.
	PageTenant func(*http.Request) string
	// Impersonation backs the act-as routes (specs/054); nil = they are not
	// mounted (e.g. the memory store, which has no clone support).
	Impersonation Impersonation
	HTTP          *http.Client // outbound to the IdPs; nil = 15s timeout client
	Now           func() time.Time
	// Audit records sign-in / sign-out events for the per-person Activity log
	// (CLE-77799); nil = auth auditing off (e.g. the memory store).
	Audit ActivityRecorder
	// TrustedProxyHops is how many proxies the hub trusts, so the audit reads
	// the real client IP (edge.ClientIP); mirrors the native config's value.
	TrustedProxyHops int
}

// New builds the handler from a validated Config.
func New(cfg *Config, log zerolog.Logger, o Options) *Handler {
	h := &Handler{
		cfg: cfg, idps: map[string]IdP{}, log: log.With().Str("component", "auth").Logger(),
		reg: o.Registrar, members: o.Membership, unlink: o.Unlinker, avatars: o.Avatars, prefs: o.Preferences,
		federated: o.Federated, now: o.Now, imp: o.Impersonation,
		defLocale: o.DefaultLocale, pageTenant: o.PageTenant,
		audit: o.Audit, hops: o.TrustedProxyHops,
	}
	if h.now == nil {
		h.now = time.Now
	}
	if !i18n.IsSupported(h.defLocale) {
		h.defLocale = i18n.DefaultLocale
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
	mux.HandleFunc("GET "+RoutePrefix+"avatar", h.avatar)
	mux.HandleFunc("POST "+RoutePrefix+"logout", h.logout)
	mux.HandleFunc("PUT "+RoutePrefix+"preferences", h.putPreferences)
	mux.HandleFunc("POST "+RoutePrefix+"tenant", h.switchTenant) // specs/026 §6
	if h.imp != nil {
		mux.HandleFunc("POST "+RoutePrefix+"act-as", h.startActAs)     // specs/054
		mux.HandleFunc("POST "+RoutePrefix+"act-as/exit", h.stopActAs) // specs/054
	}
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
	// The list changes only with a deploy's cnf, and the sign-in page asked
	// for it twice per load (prd /login, CLE-35076): five minutes in the
	// browser's own cache answers the second read and every reload in that
	// window without a round trip.
	w.Header().Set("Cache-Control", providersCacheControl)
	writeJSON(w, http.StatusOK, body)
}

// providersCacheControl: private (the answer carries this origin's CORS
// headers), fresh for 5 minutes.
const providersCacheControl = "private, max-age=300"

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
	// nosemgrep: go.lang.security.audit.net.cookie-missing-secure.cookie-missing-secure -- Secure = cfg.CookieSecure (env SPOOL_HUB_AUTH_COOKIE_SECURE; "true" in dev+prd cnf, "false" only for local http dev/lde). SPL-1285.
	http.SetCookie(w, &http.Cookie{
		Name: h.cfg.StateCookieName, Value: nonce, Path: RoutePrefix, Domain: h.cfg.CookieDomain,
		MaxAge: int(h.cfg.StateTTL.Seconds()), HttpOnly: true, Secure: h.cfg.CookieSecure, SameSite: http.SameSiteLaxMode,
	})
	w.Header().Set("Cache-Control", "no-store")
	// nosemgrep: go.lang.security.injection.open-redirect.open-redirect -- target is the configured provider's authorize endpoint (idp.AuthCodeURL built from cnf), not a request value; state+nonce are server-minted. Any redirect that lands a user-supplied path goes through safeRedirect (token.go). SPL-1288.
	http.Redirect(w, r, withLoginHint(idp.AuthCodeURL(state, nonce), p, r.URL.Query().Get("login_hint")), http.StatusFound)
}

// withLoginHint pre-selects the invited address at the providers that honour
// login_hint, Google and Microsoft (SPL-1231: an invitee arriving from the
// invite link should not have to guess which account to pick). Anything that
// is not a plain address is dropped. The hint never decides who signs in: the
// provider-verified address still does.
func withLoginHint(target, provider, hint string) string {
	hint = normEmail(hint)
	if hint == "" || (provider != ProviderGoogle && provider != ProviderMicrosoft) {
		return target
	}
	u, err := url.Parse(target)
	if err != nil {
		return target
	}
	q := u.Query()
	q.Set("login_hint", hint)
	u.RawQuery = q.Encode()
	return u.String()
}

// registerLanding runs the Registrar. A sign-in that named no tenant lands in
// the workspace its verified address is invited to (SPL-1230); if that
// admission is refused (a seat cap, a race with a revoke) it falls back to the
// tenant-less sign-in it was before. It answers the human and the tenant the
// session should carry.
func (h *Handler) registerLanding(ctx context.Context, id Identity, tenant string) (string, string, error) {
	if l, ok := h.reg.(InviteLander); ok && tenant == "" && id.Email != "" {
		if t, err := l.InvitedTenant(ctx, id.Email); err == nil && validTenant(t) {
			hum, err := h.reg.Register(ctx, id, t)
			if err == nil {
				h.log.Info().Str("tenant", t).Msg("auth.invite_landing")
				return hum, t, nil
			}
			h.log.Warn().Err(err).Str("tenant", t).Msg("auth.invite_landing_refused")
		}
	}
	hum, err := h.reg.Register(ctx, id, tenant)
	return hum, tenant, err
}

func (h *Handler) callback(w http.ResponseWriter, r *http.Request) {
	p := r.PathValue("provider")
	idp, ok := h.idps[p]
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "unknown or disabled provider")
		return
	}
	// The state cookie is single-use: cleared on every callback outcome.
	// nosemgrep: go.lang.security.audit.net.cookie-missing-secure.cookie-missing-secure -- Secure = cfg.CookieSecure (env SPOOL_HUB_AUTH_COOKIE_SECURE; "true" in dev+prd cnf, "false" only for local http dev/lde). SPL-1285.
	http.SetCookie(w, &http.Cookie{Name: h.cfg.StateCookieName, Value: "", Path: RoutePrefix, Domain: h.cfg.CookieDomain,
		MaxAge: -1, HttpOnly: true, Secure: h.cfg.CookieSecure, SameSite: http.SameSiteLaxMode})
	w.Header().Set("Cache-Control", "no-store")
	q := r.URL.Query()

	var st statePayload
	if err := openToken(h.stateKey, q.Get("state"), &st, h.now()); err != nil || st.Provider != p {
		h.fail(w, r, p, "/", ErrCodeState, "state signature, expiry or provider")
		return
	}
	c, err := r.Cookie(h.cfg.StateCookieName)
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
	id.Name = CleanDisplayName(id.Name) // it seeds display_name (Admit)
	sess := Session{V: 1, Provider: p, Subject: id.Subject, Email: id.Email, Name: id.Name,
		Tenant: st.Tenant, IssuedAt: h.now().Unix(), Exp: h.now().Add(h.cfg.SessionTTL).Unix()}
	if h.reg != nil {
		hum, landed, err := h.registerLanding(r.Context(), id, st.Tenant)
		if errors.Is(err, ErrInviteExpired) {
			h.fail(w, r, p, st.Redirect, ErrCodeInviteExpired, "invite expired")
			return
		}
		if errors.Is(err, ErrNotAllowed) {
			h.fail(w, r, p, st.Redirect, ErrCodeNotAllowed, "registrar refused")
			return
		}
		if err != nil {
			h.fail(w, r, p, st.Redirect, ErrCodeUnavailable, err.Error())
			return
		}
		sess.HumanID, sess.Tenant = hum, landed
		h.bindTenant(r.Context(), &sess)
	}
	tok, err := signToken(h.sessionKey, sess)
	if err != nil {
		h.fail(w, r, p, st.Redirect, ErrCodeUnavailable, "sign session")
		return
	}
	http.SetCookie(w, h.sessionCookie(tok, int(h.cfg.SessionTTL.Seconds())))
	h.log.Info().Str("provider", p).Str("subject", digest(id.Subject)).Str("tenant", sess.Tenant).
		Msg("auth.login_ok")
	// CLE-77799: the durable sign-in event for the Activity log (method = the IdP).
	h.recordAuth(r, sess.Tenant, sess.HumanID, "sign_in", p)
	http.Redirect(w, r, h.appURL(st.Redirect, nil), http.StatusFound)
}

// sessionResp is the session claims plus the signed-in human's settings,
// read from the store on every call (the cookie is stateless and would go
// stale). preferred_locale is null when unset, or with no registered human.
type sessionResp struct {
	Session
	PreferredLocale *string `json:"preferred_locale"`
	// PreferredTheme is the colour theme, null when unset. 'light' is the
	// light-blue palette. Read on every session call, like the locale.
	PreferredTheme *string `json:"preferred_theme"`
	// SubmitKey is Settings -> Behaviour "Text fields" (SPL-976), null when
	// unset (the WUI then applies its default, spec 023 3.7).
	SubmitKey *string `json:"submit_key"`
	// RailOrder is Settings -> Behaviour "Left panel order" (SPL-979), null
	// when never reordered (the WUI then draws its default order).
	RailOrder []string `json:"rail_order"`
	// MessageOrder and ComposerPosition are Settings -> Behaviour "Message
	// order" / "Omnibox position" (topic c6994436), null when never picked
	// (the WUI then keeps today's layout: newest first, Omnibox at the top).
	MessageOrder     *string `json:"message_order"`
	ComposerPosition *string `json:"composer_position"`
	// IssuesView is the Issues page's view (SPL-1028), null when never
	// picked (the WUI then shows the list).
	IssuesView *string `json:"issues_view"`
	// CloseButtons is Settings -> Behaviour "Close buttons" (SPL-1133), null
	// when never picked (the WUI then draws them Mac style, top left).
	CloseButtons *string `json:"close_buttons"`
	// LinkPreviews is Settings -> Behaviour "Link previews" (topic
	// e1f8f797), null when never picked (the WUI then shows them: on).
	LinkPreviews *string `json:"link_previews"`
	// IssuesColumns is the Issues sheet's column widths (SPL-1132), column
	// -> px, null when never sized (the WUI then keeps its automatic layout).
	IssuesColumns map[string]int `json:"issues_columns"`
	// IssuesSort is the Issues list default sort (CLE-35099), null when never
	// picked (the WUI then sorts priority ascending, 1 at the top).
	IssuesSort *IssuesSort `json:"issues_sort"`
	// PaneSizes is the two vertical dividers' widths as fractions of the
	// window (CLE-35099, SPL-1182), null when never dragged (default layout).
	PaneSizes map[string]float64 `json:"pane_sizes"`
	// TimeZone is the IANA zone the WUI prints times in (CLE-77908), per
	// tenant, null when never picked (the WUI then follows the browser).
	TimeZone *string `json:"time_zone"`
	// KeyboardShortcuts is the message shortcuts switch (HUM-10 ae2e5093),
	// per tenant, null when never picked (the WUI then treats it as on).
	KeyboardShortcuts *bool `json:"keyboard_shortcuts"`
	// DiagnosticsEnabled is the human's own "Debug pane" setting,
	// which shows the WUI diagnostics panel (005 T035). It sits HERE and not
	// in Session on purpose: Session is what gets signed into the cookie, and
	// a setting that rode the cookie would outlive its unticking by a whole
	// session TTL. See diagnosticsGrant.
	DiagnosticsEnabled bool `json:"diagnostics_enabled"`
	// specs/026 §3: the tenant this session works in (null when none
	// resolves) and every membership (the phase 2 switcher's list).
	ActiveTenant *string      `json:"active_tenant"`
	Tenants      []TenantRole `json:"tenants"`
}

// session answers who the cookie belongs to: 200 + claims, or 401.
func (h *Handler) session(w http.ResponseWriter, r *http.Request) {
	s, ok := h.SessionFromRequest(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no valid session")
		return
	}
	// Read the human's memberships ONCE (rdb 0078 carries each tenant's settings
	// override on it): the per-tenant overlay and the tenants list both read
	// from this, so the overlay costs no extra round trip. The tenant for the
	// overlay is the SPL-959 page host, else the session `t` — from the request,
	// no round trip; a non-member tenant yields no override (falls back to the
	// global), and sessionTenants resolves the validated active tenant for the claim.
	roles := h.memberRoles(r.Context(), s)
	override := overrideFromRoles(roles, h.requestTenant(r, s))
	ctx := h.withSettings(r.Context(), s, override) // one settings read for the whole answer (SPL-1100)
	out := sessionResp{Session: s, DiagnosticsEnabled: h.diagnosticsGrant(ctx, s)}
	out.Name = h.shownName(ctx, s)
	h.sessionTenants(r, &out, roles)
	if s.HumanID != "" && h.prefs != nil {
		// A settings lookup never fails the session: the WUI then follows the browser.
		if loc, err := h.settings(ctx, s.HumanID).PreferredLocale(ctx, s.HumanID); err != nil {
			h.log.Warn().Err(err).Msg("auth.session preferred_locale lookup")
		} else if i18n.IsSupported(loc) {
			out.PreferredLocale = &loc
		}
		out.PreferredTheme = h.preferredTheme(ctx, s)
		out.SubmitKey = h.submitKey(ctx, s)
		out.RailOrder = h.railOrder(ctx, s)
		out.MessageOrder = h.viewPref(ctx, s, PrefMessageOrder)
		out.ComposerPosition = h.viewPref(ctx, s, PrefComposerPosition)
		out.IssuesView = h.viewPref(ctx, s, PrefIssuesView)
		out.CloseButtons = h.viewPref(ctx, s, PrefCloseButtons)
		out.LinkPreviews = h.viewPref(ctx, s, PrefLinkPreviews)
		out.IssuesColumns = h.issueColumns(ctx, s)
		out.IssuesSort = h.issuesSort(ctx, s)
		out.PaneSizes = h.paneSizes(ctx, s)
		out.TimeZone = h.timeZone(ctx, s)
		out.KeyboardShortcuts = h.keyboardShortcuts(ctx, s)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// preferredTheme is the session human's stored colour theme, nil when unset,
// with no registered human or no store, or when the read fails (the WUI then
// keeps the browser's own). GET /session and the native POST /login answer
// both carry it: the WUI adopts the login answer with no second probe, so a
// theme missing there was never applied after a password sign-in.
func (h *Handler) preferredTheme(ctx context.Context, s Session) *string {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	theme, err := h.settings(ctx, s.HumanID).PreferredTheme(ctx, s.HumanID)
	if err != nil {
		h.log.Warn().Err(err).Msg("auth preferred_theme lookup")
		return nil
	}
	if theme == "" {
		return nil
	}
	return &theme
}

// submitKey is the session human's stored Behaviour "Text fields" choice
// (SPL-976), nil when unset, with no human or store, or when the read fails.
// Like preferredTheme it rides GET /session and the native POST /login answer.
func (h *Handler) submitKey(ctx context.Context, s Session) *string {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	key, err := h.settings(ctx, s.HumanID).SubmitKey(ctx, s.HumanID)
	if err != nil {
		h.log.Warn().Err(err).Msg("auth submit_key lookup")
		return nil
	}
	if key == "" {
		return nil
	}
	return &key
}

// railOrder is the session human's stored left-rail order (SPL-979), nil
// when unset, with no human or store, or when the read fails. It rides GET
// /session and the native POST /login answer, like submitKey.
func (h *Handler) railOrder(ctx context.Context, s Session) []string {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	order, err := h.settings(ctx, s.HumanID).RailOrder(ctx, s.HumanID)
	if err != nil {
		h.log.Warn().Err(err).Msg("auth rail_order lookup")
		return nil
	}
	return order
}

// viewPref is one stored layout choice of the session human (topic
// c6994436), nil when unset, with no human or store, or when the read fails.
// It rides GET /session and the native POST /login answer, like submitKey.
func (h *Handler) viewPref(ctx context.Context, s Session, key string) *string {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	v, err := h.settings(ctx, s.HumanID).ViewPref(ctx, s.HumanID, key)
	if err != nil {
		h.log.Warn().Err(err).Str("key", key).Msg("auth view pref lookup")
		return nil
	}
	if v == "" {
		return nil
	}
	return &v
}

// diagnosticsGrant answers the WUI's `diagnostics_enabled` claim (005 T035,
// 010 auth-v1 section 3): did THIS signed-in human tick "Debug pane" in their
// settings (rdb 0038 humans.diagnostics_enabled)?
//
// The setting is the SOLE gate. It replaced the operator list
// SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS: under "list OR setting" unticking the box
// would change nothing for a listed address (the donor's section 2.7 lesson).
//
// Two properties it exists to hold:
//
//  1. The answer is read from the store on EVERY session read and is never a
//     field of the signed session cookie. There is no such key in Session to
//     carry, so nothing the browser sends can assert it — a cookie whose
//     payload names it included — and unticking hides the panel at the next
//     probe, not at the end of a 12h session.
//  2. It FAILS SHUT: no registered human, no store wired, an unknown human
//     and a store error are all "no".
func (h *Handler) diagnosticsGrant(ctx context.Context, s Session) bool {
	if s.HumanID == "" || h.prefs == nil {
		return false
	}
	on, err := h.settings(ctx, s.HumanID).DiagnosticsEnabled(ctx, s.HumanID)
	if err != nil {
		if !errors.Is(err, ErrNoHuman) {
			h.log.Warn().Err(err).Msg("auth.session diagnostics_enabled lookup")
		}
		return false
	}
	return on
}

// shownName is the `name` claim the WUI renders for the signed-in human
// the display name they set in Settings (humans.display_name),
// read from the store on every call, else the cookie's IdP name. The cookie
// carries the name as it was at sign-in, so a rename would otherwise show
// only at the next sign-in. A lookup error never fails the session.
func (h *Handler) shownName(ctx context.Context, s Session) string {
	if s.HumanID == "" || h.prefs == nil {
		return s.Name
	}
	name, err := h.settings(ctx, s.HumanID).DisplayName(ctx, s.HumanID)
	if err != nil {
		if !errors.Is(err, ErrNoHuman) {
			h.log.Warn().Err(err).Msg("auth.session display_name lookup")
		}
		return s.Name
	}
	if name == "" {
		return s.Name
	}
	return name
}

// MaxDisplayNameLen is humans.display_name's CHECK (rdb 0006), in characters.
const MaxDisplayNameLen = 200

// ValidDisplayName trims raw and answers it when it is 1..200 characters of
// valid UTF-8 with no control character (C0, DEL, C1), no line or paragraph
// separator and no bidi control: the name is one line wherever the WUI
// shows it, and "\u202enimda" cannot render as "admin" to a CLI or agent
// reader (the WUI strips them too, 13b04912).
func ValidDisplayName(raw string) (string, bool) {
	name := strings.TrimSpace(raw)
	if name == "" || !utf8.ValidString(name) || utf8.RuneCountInString(name) > MaxDisplayNameLen {
		return "", false
	}
	for _, c := range name {
		if !nameRune(c) {
			return "", false
		}
	}
	return name, true
}

// CleanDisplayName is the rule for a name the human did not type into the
// preferences form - an IdP claim, the native register form - which seeds
// display_name: the runes ValidDisplayName refuses are dropped, and it is
// cut at 200 characters, never mid-rune. "" = no usable name.
func CleanDisplayName(raw string) string {
	var b strings.Builder
	for _, c := range strings.ToValidUTF8(raw, "") {
		if nameRune(c) {
			b.WriteRune(c)
		}
	}
	name := []rune(strings.TrimSpace(b.String()))
	if len(name) > MaxDisplayNameLen {
		name = name[:MaxDisplayNameLen]
	}
	return strings.TrimSpace(string(name))
}

// nameRune is false for what a one-line, left-to-right-safe name must not
// hold: controls, U+2028/U+2029 and the bidi embedding, override, isolate
// and mark characters (U+061C, U+200E/F, U+202A..E, U+2066..9).
func nameRune(c rune) bool {
	switch {
	case unicode.IsControl(c), c == '\u2028', c == '\u2029':
		return false
	case c == '\u061c', c == '\u200e', c == '\u200f':
		return false
	case c >= '\u202a' && c <= '\u202e', c >= '\u2066' && c <= '\u2069':
		return false
	}
	return true
}

// MaxInterestsLen bounds humans.interests (rdb 0086's CHECK), counted in
// characters, not bytes.
const MaxInterestsLen = 1000

// ValidInterests admits the free-text interests a human types in Settings ->
// Profile (CLE-77794): the trimmed text, up to MaxInterestsLen characters. It
// is multi-line (newlines and tabs are kept, unlike a display name), but the
// other control and bidi-override runes ValidDisplayName refuses are refused
// here too. "" (nothing typed, or all whitespace) is valid and clears it.
func ValidInterests(raw string) (string, bool) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", true
	}
	if !utf8.ValidString(s) || utf8.RuneCountInString(s) > MaxInterestsLen {
		return "", false
	}
	for _, c := range s {
		if c == '\n' || c == '\t' {
			continue
		}
		if !nameRune(c) {
			return "", false
		}
	}
	return s, true
}

// avatar answers the signed-in human's own stored IdP picture:
// 200 + the image, 401 without a session, 404 when there is none. The type
// comes from the bytes (fetchAvatar admitted only png/jpeg/gif/webp), the
// ETag is the content address, and nothing is cached by a shared cache.
func (h *Handler) avatar(w http.ResponseWriter, r *http.Request) {
	s, ok := h.SessionFromRequest(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no valid session")
		return
	}
	if s.HumanID == "" || h.avatars == nil {
		writeErr(w, http.StatusNotFound, "not_found", "no stored picture")
		return
	}
	pic, err := h.avatars.OwnAvatar(r.Context(), s.HumanID)
	if errors.Is(err, ErrNoAvatar) {
		writeErr(w, http.StatusNotFound, "not_found", "no stored picture")
		return
	}
	if err != nil {
		h.log.Warn().Err(err).Str("human_id", s.HumanID).Msg("auth.avatar_read_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "picture store")
		return
	}
	ct := sniffImage(pic)
	if ct == "" {
		writeErr(w, http.StatusNotFound, "not_found", "no stored picture")
		return
	}
	sum := sha256.Sum256(pic)
	etag := `"` + hex.EncodeToString(sum[:]) + `"`
	w.Header().Set("Cache-Control", "private, no-cache")
	w.Header().Set("ETag", etag)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", ct)
	w.WriteHeader(http.StatusOK)
	w.Write(pic) //nolint:errcheck
}

// ThemeIDs are the WUI palette themes in picker order (csi-spl-wui
// src/utils/theme.mjs THEMES); 'light' is the light-blue one. The DB check
// humans_preferred_theme_check (rdb 0057, 0059) admits the same list.
var ThemeIDs = []string{"dark", "light", "light-violet", "light-green", "light-yellow", "light-orange", "light-red"}

// IsTheme reports whether theme is one of ThemeIDs, exactly.
func IsTheme(theme string) bool {
	for _, id := range ThemeIDs {
		if theme == id {
			return true
		}
	}
	return false
}

// SubmitKeys are the Behaviour "Text fields" choices (SPL-976, spec 023
// 3.7): 'enter' = Enter sends, Shift+Enter adds a line;
// 'ctrl-enter' = Enter adds a line, Ctrl/Cmd+Enter sends. The DB check
// humans_submit_key_check (rdb 0062) admits the same list.
var SubmitKeys = []string{"enter", "ctrl-enter"}

// DefaultSubmitKey is the mode of a human who never picked one (submit_key
// NULL, answered as null): Enter sends (owner, 2026-09-27). The WUI applies
// it (DEFAULT_SUBMIT_KEY in utils/submit-key.mjs, pinned equal by
// tests/unit/submit-key.test.mjs); the hub never writes it into a row, so
// "never picked" stays NULL and a later default flip reaches only them.
const DefaultSubmitKey = "enter"

// IsSubmitKey reports whether key is one of SubmitKeys, exactly.
func IsSubmitKey(key string) bool {
	for _, id := range SubmitKeys {
		if key == id {
			return true
		}
	}
	return false
}

// The layout choices of Settings -> Behaviour (topic c6994436), each a
// humans column of the same name (rdb 0070) whose CHECK admits the same
// values. The first value of each list is the default a human who never
// picked one sees (the column stays NULL; the WUI applies it).
const (
	// PrefMessageOrder: 'newest-first' = the newest message at the top (spec
	// 013); 'newest-last' = messages appended, the newest at the bottom.
	PrefMessageOrder = "message_order"
	// PrefComposerPosition: 'top' = the Omnibox in the top bar; 'bottom' =
	// docked under the middle pane on screens wider than 820 px.
	PrefComposerPosition = "composer_position"
	// PrefIssuesView (SPL-1028, rdb 0072): 'list' = the Issues sheet as one
	// flat list; 'status' = the same rows grouped by status (Linear's view).
	PrefIssuesView = "issues_view"
	// PrefCloseButtons (SPL-1133, rdb 0077): 'mac' = every close X in the
	// top left (the owner's default); 'windows' = in the top right.
	PrefCloseButtons = "close_buttons"
	// PrefLinkPreviews (topic e1f8f797, rdb 0120): 'on' = a link to a topic
	// or a message of the workspace shows a short preview card under the
	// message (the default); 'off' = it stays a plain link.
	PrefLinkPreviews = "link_previews"
)

// ViewPrefs maps each layout key to its values, default first.
var ViewPrefs = map[string][]string{
	PrefMessageOrder:     {"newest-first", "newest-last"},
	PrefComposerPosition: {"top", "bottom"},
	PrefIssuesView:       {"list", "status"},
	PrefCloseButtons:     {"mac", "windows"},
	PrefLinkPreviews:     {"on", "off"},
}

// viewPrefKeys is ViewPrefs' keys in a fixed order (the PUT answer and logs).
var viewPrefKeys = []string{PrefMessageOrder, PrefComposerPosition, PrefIssuesView, PrefCloseButtons, PrefLinkPreviews}

// IsViewPref reports whether value is one of key's ViewPrefs values, exactly.
func IsViewPref(key, value string) bool {
	for _, v := range ViewPrefs[key] {
		if value == v {
			return true
		}
	}
	return false
}

// RailTabs are the reorderable left-rail entries (SPL-979) in their default
// order: channels, direct messages, issues, topics, flow, archive (SPL-983),
// the event log (owner 2026-09-27, topic 116646c8), People and Agents
// (CLE-77794) and Boxes last (CLE-77799) (the admin-only Users tab stays last
// and is not one of them). The DB check humans_rail_order_check (rdb 0063,
// 0064, 0087, 0090) admits their permutations and the legacy ones of the first
// six, seven or nine.
var RailTabs = []string{"channels", "dm", "issues", "topics", "flow", "archive", "events", "people", "agents", "boxes"}

// legacyRailTabs6 is RailTabs before SPL-983 added archive: an order stored
// then (or sent by a WUI still cached from then) holds exactly these six.
var legacyRailTabs6 = []string{"channels", "dm", "issues", "topics", "flow", "events"}

// legacyRailTabs7 is RailTabs before CLE-77794 added People and Agents: the six
// plus archive. A WUI cached from then holds exactly these seven; the current
// WUI appends the tabs added since (parseRailOrder), so a save carries all ten.
var legacyRailTabs7 = []string{"channels", "dm", "issues", "topics", "flow", "archive", "events"}

// legacyRailTabs9 is RailTabs before CLE-77799 added Boxes: the seven plus
// People and Agents. A WUI cached from then holds exactly these nine; the
// current WUI appends Boxes (parseRailOrder), so a save carries all ten.
var legacyRailTabs9 = []string{"channels", "dm", "issues", "topics", "flow", "archive", "events", "people", "agents"}

// IsRailOrder reports whether order holds every RailTabs id exactly once, or
// every legacy set once (the WUI appends the tabs added since to it).
func IsRailOrder(order []string) bool {
	return isPermutation(order, RailTabs) || isPermutation(order, legacyRailTabs6) || isPermutation(order, legacyRailTabs7) || isPermutation(order, legacyRailTabs9)
}

func isPermutation(order, of []string) bool {
	if len(order) != len(of) {
		return false
	}
	seen := map[string]bool{}
	for _, id := range order {
		if seen[id] {
			return false
		}
		seen[id] = true
	}
	for _, id := range of {
		if !seen[id] {
			return false
		}
	}
	return true
}

// preferencesReq is PUT preferences' body. Each key is optional, but at
// least one must be present: preferred_locale is one of the 19
// i18n.Supported codes exactly, or null to clear it; diagnostics_enabled
// is a JSON boolean, nothing else; display_name is a
// JSON string ValidDisplayName admits, and cannot be cleared (null is refused);
// preferred_theme is one of ThemeIDs exactly, or null to clear it;
// submit_key (SPL-976) is one of SubmitKeys exactly, or null to clear it;
// rail_order (SPL-979) is an array holding every RailTabs id once (or the
// legacy six, SPL-983), or null; message_order and composer_position (topic
// c6994436), issues_view (SPL-1028), close_buttons (SPL-1133) and
// link_previews (topic e1f8f797) are one of
// their ViewPrefs values exactly, or null; issues_columns (SPL-1132) is an object of IssueColumns
// -> px (IsIssueColumns), or null / {} to clear it.
type preferencesReq struct {
	PreferredLocale    json.RawMessage `json:"preferred_locale"`
	PreferredTheme     json.RawMessage `json:"preferred_theme"`
	DiagnosticsEnabled json.RawMessage `json:"diagnostics_enabled"`
	DisplayName        json.RawMessage `json:"display_name"`
	Interests          json.RawMessage `json:"interests"`
	SubmitKey          json.RawMessage `json:"submit_key"`
	RailOrder          json.RawMessage `json:"rail_order"`
	MessageOrder       json.RawMessage `json:"message_order"`
	ComposerPosition   json.RawMessage `json:"composer_position"`
	IssuesView         json.RawMessage `json:"issues_view"`
	CloseButtons       json.RawMessage `json:"close_buttons"`
	LinkPreviews       json.RawMessage `json:"link_previews"`
	IssuesColumns      json.RawMessage `json:"issues_columns"`
	IssuesSort         json.RawMessage `json:"issues_sort"`
	PaneSizes          json.RawMessage `json:"pane_sizes"`
	TimeZone           json.RawMessage `json:"time_zone"`
	KeyboardShortcuts  json.RawMessage `json:"keyboard_shortcuts"`
}

// raw is the request's JSON for one ViewPrefs key.
func (q preferencesReq) raw(key string) json.RawMessage {
	switch key {
	case PrefMessageOrder:
		return q.MessageOrder
	case PrefIssuesView:
		return q.IssuesView
	case PrefCloseButtons:
		return q.CloseButtons
	case PrefLinkPreviews:
		return q.LinkPreviews
	}
	return q.ComposerPosition
}

// putPreferences stores the signed-in human's settings.
// Same door as the session read (the signed session cookie) and the same CSRF
// posture as the native POSTs: application/json only, so a browser always
// preflights it and authCORS's origin allow-list gates it. The whole body is
// validated before anything is written, and the answer echoes exactly the
// keys that were stored.
func (h *Handler) putPreferences(w http.ResponseWriter, r *http.Request) {
	s, ok := h.SessionFromRequest(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no valid session")
		return
	}
	var req preferencesReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	p, code, detail := parsePreferences(req)
	if code != "" {
		writeErr(w, http.StatusBadRequest, code, detail)
		return
	}
	if s.HumanID == "" {
		writeErr(w, http.StatusConflict, "no_human", "this session has no registered human to keep settings on")
		return
	}
	if h.prefs == nil {
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "preferences are not configured")
		return
	}
	if out, ok := h.storePreferences(w, r, s.HumanID, p); ok {
		writeJSON(w, http.StatusOK, out)
	}
}

// prefsIn is a validated PUT /preferences body. has* says which keys were
// present (a present null clears the setting: the value is then "").
type prefsIn struct {
	loc, name, theme, key                               string
	interests                                           string // humans.interests (rdb 0086), "" = null / clear
	diag                                                bool
	rail                                                []string
	view                                                map[string]string  // layout key -> value, "" = null
	cols                                                map[string]int     // issues_columns, nil = null
	sort                                                *IssuesSort        // issues_sort, nil = null (CLE-35099)
	panes                                               map[string]float64 // pane_sizes, nil = null (CLE-35099)
	tz                                                  string             // time_zone, "" = null (CLE-77908)
	kbd                                                 *bool              // keyboard_shortcuts, nil = null (HUM-10 ae2e5093)
	hasLoc, hasDiag, hasName, hasTheme, hasKey, hasRail bool
	hasInterests                                        bool
	hasCols, hasSort, hasPanes, hasTZ, hasKbd           bool
}

// parsePreferences validates the whole body before anything is written. A
// refusal is (code, detail) for a 400; the checks run in the order the
// answers were always given (layout keys, empty body, then key by key).
func parsePreferences(req preferencesReq) (p prefsIn, code, detail string) {
	p.hasLoc, p.hasDiag, p.hasName = present(req.PreferredLocale) != "", present(req.DiagnosticsEnabled) != "", present(req.DisplayName) != ""
	p.hasInterests = present(req.Interests) != ""
	p.hasTheme, p.hasKey, p.hasRail = present(req.PreferredTheme) != "", present(req.SubmitKey) != "", present(req.RailOrder) != ""
	if p.view, code, detail = parseViewPrefs(req); code != "" {
		return p, code, detail
	}
	if p.cols, p.hasCols, code, detail = parseIssueColumns(req.IssuesColumns); code != "" {
		return p, code, detail
	}
	if p.sort, p.hasSort, code, detail = parseIssuesSort(req.IssuesSort); code != "" {
		return p, code, detail
	}
	if p.panes, p.hasPanes, code, detail = parsePaneSizes(req.PaneSizes); code != "" {
		return p, code, detail
	}
	if p.tz, p.hasTZ, code, detail = parseTimeZone(req.TimeZone); code != "" {
		return p, code, detail
	}
	if p.kbd, p.hasKbd, code, detail = parseKeyboardShortcuts(req.KeyboardShortcuts); code != "" {
		return p, code, detail
	}
	if !p.hasLoc && !p.hasDiag && !p.hasName && !p.hasInterests && !p.hasTheme && !p.hasKey && !p.hasRail && len(p.view) == 0 && !p.hasCols && !p.hasSort && !p.hasPanes && !p.hasTZ && !p.hasKbd {
		return p, "bad_request", "preferred_locale (a locale code or null), diagnostics_enabled (true or false), display_name, interests (free text or null), preferred_theme (a theme id or null), submit_key (enter, ctrl-enter or null), rail_order (the rail ids or null), message_order (newest-first, newest-last or null), composer_position (top, bottom or null), issues_view (list, status or null), close_buttons (mac, windows or null), link_previews (on, off or null), issues_columns (column -> px or null), issues_sort ({col, dir} or null), pane_sizes (divider -> fraction or null), time_zone (an IANA zone or null) or keyboard_shortcuts (true, false or null) is required"
	}
	code, detail = p.parseScalars(req)
	return p, code, detail
}

// present is a body key's trimmed JSON: "" when the key is absent.
func present(b json.RawMessage) string { return strings.TrimSpace(string(b)) }

// setChoice decodes a present, non-null JSON string into dst and checks it;
// an absent key or a null passes and leaves dst "".
func setChoice(b json.RawMessage, dst *string, valid func(string) bool) bool {
	if raw := present(b); raw == "" || raw == "null" {
		return true
	}
	return json.Unmarshal(b, dst) == nil && valid(*dst)
}

// parseScalars checks the one-value keys in the order the answers were
// always given: locale, diagnostics, display name, interests, theme, submit
// key, rail order. A refusal is (code, detail).
func (p *prefsIn) parseScalars(req preferencesReq) (code, detail string) {
	if !setChoice(req.PreferredLocale, &p.loc, i18n.IsSupported) {
		return "unsupported_locale", "preferred_locale must be one of " + strings.Join(i18n.Supported, ",")
	}
	// Only the literal true/false: "true", 1 and null are refused rather than
	// coerced, the same strictness the WUI's gate applies to the claim.
	rawDiag := present(req.DiagnosticsEnabled)
	p.diag = rawDiag == "true"
	if rawDiag != "" && rawDiag != "true" && rawDiag != "false" {
		return "bad_request", "diagnostics_enabled must be true or false"
	}
	if code, detail = p.parseDisplayName(req.DisplayName); code != "" {
		return code, detail
	}
	if code, detail = p.parseInterests(req.Interests); code != "" {
		return code, detail
	}
	if !setChoice(req.PreferredTheme, &p.theme, IsTheme) {
		return "unsupported_theme", "preferred_theme must be one of " + strings.Join(ThemeIDs, ",")
	}
	if !setChoice(req.SubmitKey, &p.key, IsSubmitKey) {
		return "unsupported_submit_key", "submit_key must be one of " + strings.Join(SubmitKeys, ",")
	}
	if rawRail := present(req.RailOrder); rawRail != "" && rawRail != "null" {
		if json.Unmarshal(req.RailOrder, &p.rail) != nil || !IsRailOrder(p.rail) {
			return "unsupported_rail_order", "rail_order must hold each of " + strings.Join(RailTabs, ",") + " exactly once"
		}
	}
	return "", ""
}

// parseDisplayName: a present display_name must be ValidDisplayName; null is
// refused (a name cannot be cleared).
func (p *prefsIn) parseDisplayName(b json.RawMessage) (code, detail string) {
	rawName := present(b)
	if rawName == "" {
		return "", ""
	}
	var raw string
	ok := rawName != "null" && json.Unmarshal(b, &raw) == nil
	if ok {
		p.name, ok = ValidDisplayName(raw)
	}
	if !ok {
		return ErrCodeInvalidDisplayName, "display_name must be 1 to 200 characters on one line, without control characters"
	}
	return "", ""
}

// parseInterests: a present null clears it (p.interests stays ""); any other
// value must be ValidInterests. Unlike display_name, "" is a valid clear.
func (p *prefsIn) parseInterests(b json.RawMessage) (code, detail string) {
	if rawInterests := present(b); rawInterests == "" || rawInterests == "null" {
		return "", ""
	}
	var raw string
	if json.Unmarshal(b, &raw) != nil {
		return "invalid_interests", "interests must be text or null"
	}
	s, ok := ValidInterests(raw)
	if !ok {
		return "invalid_interests", "interests must be at most 1000 characters, without control characters"
	}
	p.interests = s
	return "", ""
}

// parseViewPrefs holds each present layout key's value ("" = null, clear it).
func parseViewPrefs(req preferencesReq) (map[string]string, string, string) {
	view := map[string]string{}
	for _, k := range viewPrefKeys {
		raw := strings.TrimSpace(string(req.raw(k)))
		if raw == "" {
			continue
		}
		v := ""
		if raw != "null" && (json.Unmarshal(req.raw(k), &v) != nil || !IsViewPref(k, v)) {
			return nil, "unsupported_" + k, k + " must be one of " + strings.Join(ViewPrefs[k], ",")
		}
		view[k] = v
	}
	return view, "", ""
}

// storePreferences writes each present key in a fixed order and returns the
// answer: exactly the keys that were stored. false = an error was answered.
func (h *Handler) storePreferences(w http.ResponseWriter, r *http.Request, hum string, p prefsIn) (map[string]any, bool) {
	ctx := r.Context()
	out := map[string]any{}
	set := func(err error, key string, val any, logged func(*zerolog.Event) *zerolog.Event) bool {
		if !h.storePref(w, err) {
			return false
		}
		logged(h.log.Info().Str("human_id", hum)).Msg("auth.preferences_set")
		out[key] = val
		return true
	}
	if p.hasLoc && !set(h.prefs.SetPreferredLocale(ctx, hum, p.loc), "preferred_locale", nullable(p.loc),
		func(e *zerolog.Event) *zerolog.Event { return e.Str("preferred_locale", p.loc) }) {
		return nil, false
	}
	if p.hasDiag && !set(h.prefs.SetDiagnosticsEnabled(ctx, hum, p.diag), "diagnostics_enabled", p.diag,
		func(e *zerolog.Event) *zerolog.Event { return e.Bool("diagnostics_enabled", p.diag) }) {
		return nil, false
	}
	if p.hasName && !set(h.prefs.SetDisplayName(ctx, hum, p.name), "display_name", p.name,
		func(e *zerolog.Event) *zerolog.Event {
			return e.Int("display_name_len", utf8.RuneCountInString(p.name))
		}) {
		return nil, false
	}
	// interests is global (humans.interests, rdb 0086), like display_name; it is
	// NOT a per-tenant membership override. "" clears it, so it is nullable.
	if p.hasInterests && !set(h.prefs.SetInterests(ctx, hum, p.interests), "interests", nullable(p.interests),
		func(e *zerolog.Event) *zerolog.Event {
			return e.Int("interests_len", utf8.RuneCountInString(p.interests))
		}) {
		return nil, false
	}
	if p.hasTheme && !set(h.prefs.SetPreferredTheme(ctx, hum, p.theme), "preferred_theme", nullable(p.theme),
		func(e *zerolog.Event) *zerolog.Event { return e.Str("preferred_theme", p.theme) }) {
		return nil, false
	}
	if p.hasKey && !set(h.prefs.SetSubmitKey(ctx, hum, p.key), "submit_key", nullable(p.key),
		func(e *zerolog.Event) *zerolog.Event { return e.Str("submit_key", p.key) }) {
		return nil, false
	}
	if p.hasRail && !set(h.prefs.SetRailOrder(ctx, hum, p.rail), "rail_order", p.rail,
		func(e *zerolog.Event) *zerolog.Event { return e.Strs("rail_order", p.rail) }) {
		return nil, false
	}
	for _, k := range viewPrefKeys {
		v, ok := p.view[k]
		if ok && !set(h.prefs.SetViewPref(ctx, hum, k, v), k, nullable(v),
			func(e *zerolog.Event) *zerolog.Event { return e.Str(k, v) }) {
			return nil, false
		}
	}
	if p.hasCols && !set(h.prefs.SetIssueColumns(ctx, hum, p.cols), "issues_columns", p.cols,
		func(e *zerolog.Event) *zerolog.Event { return e.Int("issues_columns", len(p.cols)) }) {
		return nil, false
	}
	// Per-tenant scoping (rdb 0078): write the same values to the active
	// tenant's membership override, so a change in one tenant never moves the
	// others (spec 023 addendum). The humans-row writes above stay the global
	// fallback for a tenant with no override yet and for the sign-in page.
	// issues_sort, pane_sizes, time_zone and keyboard_shortcuts have no humans column: they live ONLY here.
	if !h.storeMembershipPrefs(w, r, hum, p, out) {
		return nil, false
	}
	return out, true
}

// storeMembershipPrefs writes the per-tenant override for the request's active
// tenant (rdb 0078). It is a no-op when the store cannot keep one, or when no
// tenant is active (the sign-in page: only the global was written). A write
// failure fails the request, so issues_sort / pane_sizes (kept nowhere else)
// are never echoed as stored when they were not. It also adds those two to out.
func (h *Handler) storeMembershipPrefs(w http.ResponseWriter, r *http.Request, hum string, p prefsIn, out map[string]any) bool {
	mw, ok := h.prefs.(MembershipSettingsWriter)
	if !ok {
		return true
	}
	_, tenant, err := h.ActiveTenant(r, "")
	if err != nil || tenant == "" {
		// No active tenant: the per-tenant-only settings cannot be kept. The WUI
		// only sends them inside a tenant, so this is the sign-in edge.
		if p.hasSort || p.hasPanes || p.hasTZ || p.hasKbd {
			h.log.Warn().Str("human_id", hum).Msg("auth.preferences issues_sort/pane_sizes/time_zone/keyboard_shortcuts with no active tenant, not stored")
		}
		return true
	}
	patch := p.membershipPatch()
	if len(patch) == 0 {
		return true
	}
	if err := mw.SetMembershipSettings(r.Context(), hum, tenant, patch); err != nil {
		h.log.Error().Err(err).Str("human_id", hum).Str("tenant", tenant).Msg("auth.preferences membership write")
		writeErr(w, http.StatusInternalServerError, "internal", "settings not stored")
		return false
	}
	h.log.Info().Str("human_id", hum).Str("tenant", tenant).Int("keys", len(patch)).Msg("auth.preferences_set_tenant")
	if p.hasSort {
		out["issues_sort"] = p.sort
	}
	if p.hasPanes {
		out["pane_sizes"] = p.panes
	}
	if p.hasTZ {
		out["time_zone"] = nullable(p.tz)
	}
	if p.hasKbd {
		out["keyboard_shortcuts"] = nilBool(p.kbd)
	}
	return true
}

// membershipPatch is the per-tenant override to write (rdb 0078): the present
// keys of p, a nil value clearing that key (the read then falls back to the
// global). display_name is not here — it stays per human.
func (p prefsIn) membershipPatch() map[string]any {
	patch := map[string]any{}
	if p.hasLoc {
		patch["preferred_locale"] = nullable(p.loc)
	}
	if p.hasTheme {
		patch["preferred_theme"] = nullable(p.theme)
	}
	if p.hasKey {
		patch["submit_key"] = nullable(p.key)
	}
	if p.hasRail {
		patch["rail_order"] = nilSlice(p.rail)
	}
	if p.hasDiag {
		patch["diagnostics_enabled"] = p.diag
	}
	for k, v := range p.view {
		patch[k] = nullable(v)
	}
	if p.hasCols {
		patch["issues_columns"] = nilMap(p.cols)
	}
	if p.hasSort {
		patch["issues_sort"] = nilSort(p.sort)
	}
	if p.hasPanes {
		patch["pane_sizes"] = nilFloatMap(p.panes)
	}
	if p.hasTZ {
		patch["time_zone"] = nullable(p.tz)
	}
	if p.hasKbd {
		patch["keyboard_shortcuts"] = nilBool(p.kbd)
	}
	return patch
}

// nilSlice / nilMap / nilFloatMap / nilSort answer a cleared setting as JSON
// null (the SQL merge strips it), so the read falls back to the global.
func nilSlice(v []string) any {
	if v == nil {
		return nil
	}
	return v
}

func nilMap(v map[string]int) any {
	if v == nil {
		return nil
	}
	return v
}

func nilFloatMap(v map[string]float64) any {
	if v == nil {
		return nil
	}
	return v
}

func nilSort(v *IssuesSort) any {
	if v == nil {
		return nil
	}
	return v
}

// nullable answers a cleared setting ("") as JSON null.
func nullable(v string) any {
	if v == "" {
		return nil
	}
	return v
}

// storePref maps one Preferences write error onto the answer; true = stored.
func (h *Handler) storePref(w http.ResponseWriter, err error) bool {
	switch {
	case errors.Is(err, ErrNoHuman):
		writeErr(w, http.StatusConflict, "no_human", "the session's human no longer exists")
		return false
	case err != nil:
		h.log.Error().Err(err).Msg("auth.preferences store")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "store")
		return false
	}
	return true
}

// RequestLocale is the locale of r: X-Locale > Accept-Language > the default.
func (h *Handler) RequestLocale(r *http.Request) string { return i18n.FromRequest(r, h.defLocale) }

// DefaultLocale is SPOOL_HUB_DEFAULT_LOCALE as this handler resolved it.
func (h *Handler) DefaultLocale() string { return h.defLocale }

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	// CLE-77799: record the sign-out before the cookie is cleared, from the
	// session the request still carries (its human + workspace). Best-effort.
	if sess, ok := h.SessionFromRequest(r); ok {
		h.recordAuth(r, sess.Tenant, sess.HumanID, "sign_out", sess.Provider)
	}
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
	// nosemgrep: go.lang.security.audit.net.cookie-missing-secure.cookie-missing-secure -- Secure = cfg.CookieSecure (env SPOOL_HUB_AUTH_COOKIE_SECURE; "true" in dev+prd cnf, "false" only for local http dev/lde). SPL-1285.
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

func writeJSON(w http.ResponseWriter, status int, v any) { wire.WriteJSON(w, status, v) }

// writeErr uses the hub's shared error envelope (003 contracts/http-v1.md).
func writeErr(w http.ResponseWriter, status int, token, detail string) {
	wire.WriteError(w, status, token, detail)
}
