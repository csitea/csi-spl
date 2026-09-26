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
	ErrCodeCancelled   = "cancelled"
	ErrCodeState       = "invalid_state"
	ErrCodeExchange    = "exchange_failed"
	ErrCodeUnverified  = "email_unverified"
	ErrCodeNotAllowed  = "not_allowed"
	ErrCodeUnavailable = "unavailable"
	// ErrCodeInvalidDisplayName: PUT preferences display_name is not a name
	// ValidDisplayName admits (CLE-34968).
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
	// IdentityLocale is the picked locale of the human a (provider, subject)
	// sign-in belongs to; "" when there is no such human or nothing is picked.
	IdentityLocale(ctx context.Context, provider, subject string) (string, error)
	// DiagnosticsEnabled is the human's own "Debug pane" setting, false when
	// never set. An unknown human is ErrNoHuman.
	DiagnosticsEnabled(ctx context.Context, humanID string) (bool, error)
	// SetDiagnosticsEnabled stores it. Unknown human = ErrNoHuman.
	SetDiagnosticsEnabled(ctx context.Context, humanID string, on bool) error
	// DisplayName is the human's shown name (humans.display_name, CLE-34968),
	// "" when none. An unknown human is ErrNoHuman.
	DisplayName(ctx context.Context, humanID string) (string, error)
	// SetDisplayName stores name, already admitted by ValidDisplayName.
	// Unknown human = ErrNoHuman.
	SetDisplayName(ctx context.Context, humanID, name string) error
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
	defLocale  string  // SPOOL_HUB_DEFAULT_LOCALE (i18n)
	native     *native // spec 015; nil = native sign-in off
	now        func() time.Time
	pageTenant func(*http.Request) string // SPL-959; nil = off
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
	// mail (CLE-3451); nil = that route falls silent on such an address, as
	// it did before.
	Federated FederatedLookup
	// DefaultLocale is SPOOL_HUB_DEFAULT_LOCALE: the mail locale when the
	// request names none, and the locale WUI links carry no prefix for
	// (prefix_except_default). "" = i18n.DefaultLocale.
	DefaultLocale string
	// PageTenant names the tenant of the WUI page a request comes from (its
	// tenant host, SPL-959); nil or "" = the session's `t` decides, as before.
	PageTenant func(*http.Request) string
	HTTP       *http.Client // outbound to the IdPs; nil = 15s timeout client
	Now        func() time.Time
}

// New builds the handler from a validated Config.
func New(cfg *Config, log zerolog.Logger, o Options) *Handler {
	h := &Handler{
		cfg: cfg, idps: map[string]IdP{}, log: log.With().Str("component", "auth").Logger(),
		reg: o.Registrar, members: o.Membership, unlink: o.Unlinker, avatars: o.Avatars, prefs: o.Preferences,
		federated: o.Federated, now: o.Now,
		defLocale: o.DefaultLocale, pageTenant: o.PageTenant,
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
		Name: h.cfg.StateCookieName, Value: nonce, Path: RoutePrefix, Domain: h.cfg.CookieDomain,
		MaxAge: int(h.cfg.StateTTL.Seconds()), HttpOnly: true, Secure: h.cfg.CookieSecure, SameSite: http.SameSiteLaxMode,
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
		h.bindTenant(r.Context(), &sess)
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

// sessionResp is the session claims plus the signed-in human's settings,
// read from the store on every call (the cookie is stateless and would go
// stale). preferred_locale is null when unset, or with no registered human.
type sessionResp struct {
	Session
	PreferredLocale *string `json:"preferred_locale"`
	// PreferredTheme is the colour theme, null when unset. 'light' is the
	// light-blue palette. Read on every session call, like the locale.
	PreferredTheme *string `json:"preferred_theme"`
	// DiagnosticsEnabled is the human's own "Debug pane" setting (CLE-34963),
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
	out := sessionResp{Session: s, DiagnosticsEnabled: h.diagnosticsGrant(r.Context(), s)}
	out.Name = h.shownName(r.Context(), s)
	h.sessionTenants(r, &out)
	if s.HumanID != "" && h.prefs != nil {
		// A settings lookup never fails the session: the WUI then follows the browser.
		if loc, err := h.prefs.PreferredLocale(r.Context(), s.HumanID); err != nil {
			h.log.Warn().Err(err).Msg("auth.session preferred_locale lookup")
		} else if i18n.IsSupported(loc) {
			out.PreferredLocale = &loc
		}
		if theme, err := h.prefs.PreferredTheme(r.Context(), s.HumanID); err != nil {
			h.log.Warn().Err(err).Msg("auth.session preferred_theme lookup")
		} else if theme != "" {
			out.PreferredTheme = &theme
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// diagnosticsGrant answers the WUI's `diagnostics_enabled` claim (005 T035,
// 010 auth-v1 section 3): did THIS signed-in human tick "Debug pane" in their
// settings (rdb 0038 humans.diagnostics_enabled, CLE-34963)?
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
	on, err := h.prefs.DiagnosticsEnabled(ctx, s.HumanID)
	if err != nil {
		if !errors.Is(err, ErrNoHuman) {
			h.log.Warn().Err(err).Msg("auth.session diagnostics_enabled lookup")
		}
		return false
	}
	return on
}

// shownName is the `name` claim the WUI renders for the signed-in human
// (CLE-34968): the display name they set in Settings (humans.display_name),
// read from the store on every call, else the cookie's IdP name. The cookie
// carries the name as it was at sign-in, so a rename would otherwise show
// only at the next sign-in. A lookup error never fails the session.
func (h *Handler) shownName(ctx context.Context, s Session) string {
	if s.HumanID == "" || h.prefs == nil {
		return s.Name
	}
	name, err := h.prefs.DisplayName(ctx, s.HumanID)
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

// avatar answers the signed-in human's own stored IdP picture (CLE-3406):
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

// preferencesReq is PUT preferences' body. Each key is optional, but at
// least one must be present: preferred_locale is one of the 19
// i18n.Supported codes exactly, or null to clear it; diagnostics_enabled
// (CLE-34963) is a JSON boolean, nothing else; display_name (CLE-34968) is a
// JSON string ValidDisplayName admits, and cannot be cleared (null is refused);
// preferred_theme (CLE-34994) is one of ThemeIDs exactly, or null to clear it.
type preferencesReq struct {
	PreferredLocale    json.RawMessage `json:"preferred_locale"`
	PreferredTheme     json.RawMessage `json:"preferred_theme"`
	DiagnosticsEnabled json.RawMessage `json:"diagnostics_enabled"`
	DisplayName        json.RawMessage `json:"display_name"`
}

// putPreferences stores the signed-in human's settings (CLE-3403, CLE-34963).
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
	rawLoc := strings.TrimSpace(string(req.PreferredLocale))
	rawDiag := strings.TrimSpace(string(req.DiagnosticsEnabled))
	rawName := strings.TrimSpace(string(req.DisplayName))
	rawTheme := strings.TrimSpace(string(req.PreferredTheme))
	if rawLoc == "" && rawDiag == "" && rawName == "" && rawTheme == "" {
		writeErr(w, http.StatusBadRequest, "bad_request",
			"preferred_locale (a locale code or null), diagnostics_enabled (true or false), display_name or preferred_theme (a theme id or null) is required")
		return
	}
	loc := ""
	switch {
	case rawLoc == "" || rawLoc == "null":
	default:
		if json.Unmarshal(req.PreferredLocale, &loc) != nil || !i18n.IsSupported(loc) {
			writeErr(w, http.StatusBadRequest, "unsupported_locale",
				"preferred_locale must be one of "+strings.Join(i18n.Supported, ","))
			return
		}
	}
	// Only the literal true/false: "true", 1 and null are refused rather than
	// coerced, the same strictness the WUI's gate applies to the claim.
	diag := rawDiag == "true"
	if rawDiag != "" && rawDiag != "true" && rawDiag != "false" {
		writeErr(w, http.StatusBadRequest, "bad_request", "diagnostics_enabled must be true or false")
		return
	}
	name := ""
	if rawName != "" {
		var raw string
		ok := rawName != "null" && json.Unmarshal(req.DisplayName, &raw) == nil
		if ok {
			name, ok = ValidDisplayName(raw)
		}
		if !ok {
			writeErr(w, http.StatusBadRequest, ErrCodeInvalidDisplayName,
				"display_name must be 1 to 200 characters on one line, without control characters")
			return
		}
	}
	theme := ""
	if rawTheme != "" && rawTheme != "null" {
		if json.Unmarshal(req.PreferredTheme, &theme) != nil || !IsTheme(theme) {
			writeErr(w, http.StatusBadRequest, "unsupported_theme",
				"preferred_theme must be one of "+strings.Join(ThemeIDs, ","))
			return
		}
	}
	if s.HumanID == "" {
		writeErr(w, http.StatusConflict, "no_human", "this session has no registered human to keep settings on")
		return
	}
	if h.prefs == nil {
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "preferences are not configured")
		return
	}
	out := map[string]any{}
	if rawLoc != "" {
		if !h.storePref(w, h.prefs.SetPreferredLocale(r.Context(), s.HumanID, loc)) {
			return
		}
		h.log.Info().Str("human_id", s.HumanID).Str("preferred_locale", loc).Msg("auth.preferences_set")
		out["preferred_locale"] = nil
		if loc != "" {
			out["preferred_locale"] = loc
		}
	}
	if rawDiag != "" {
		if !h.storePref(w, h.prefs.SetDiagnosticsEnabled(r.Context(), s.HumanID, diag)) {
			return
		}
		h.log.Info().Str("human_id", s.HumanID).Bool("diagnostics_enabled", diag).Msg("auth.preferences_set")
		out["diagnostics_enabled"] = diag
	}
	if rawName != "" {
		if !h.storePref(w, h.prefs.SetDisplayName(r.Context(), s.HumanID, name)) {
			return
		}
		h.log.Info().Str("human_id", s.HumanID).Int("display_name_len", utf8.RuneCountInString(name)).
			Msg("auth.preferences_set")
		out["display_name"] = name
	}
	if rawTheme != "" {
		if !h.storePref(w, h.prefs.SetPreferredTheme(r.Context(), s.HumanID, theme)) {
			return
		}
		h.log.Info().Str("human_id", s.HumanID).Str("preferred_theme", theme).Msg("auth.preferences_set")
		out["preferred_theme"] = nil
		if theme != "" {
			out["preferred_theme"] = theme
		}
	}
	writeJSON(w, http.StatusOK, out)
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
