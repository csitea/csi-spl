// Native email + password sign-in (spec 015, contract native-auth-v1.md),
// ported from csi-rel internal/auth (register/login/change in handlers.go,
// password_reset.go, email_verification.go) onto this package's session and
// Registrar. What differs from the donor, and why, is spec 015 §1.
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"net/http"
	netmail "net/mail"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// Error tokens of native-auth-v1 §4.
const (
	ErrTokInvalidCredentials = "invalid_credentials"
	ErrTokEmailUnverified    = "email_unverified"
	ErrTokVerifyInvalid      = "verification_token_invalid"
	ErrTokVerifyExpired      = "verification_token_expired"
	ErrTokResetInvalid       = "reset_token_invalid"
	ErrTokMailUnavailable    = "email_delivery_unavailable"
	ErrTokRateLimited        = "rate_limited"
)

const maxNativeBody = 8 << 10

// native serves the spec 015 routes; it borrows the Handler's session key,
// cookie, APP_URL and Registrar so both sign-in kinds yield one session.
type native struct {
	h        *Handler
	cfg      *NativeConfig
	store    CredStore
	sender   mail.Sender
	delivers bool
	lim      *limiter
	dummy    string // hash burnt on the unknown-email login path (FR-005)
	log      zerolog.Logger
}

// NativeDeps are native sign-in's collaborators.
type NativeDeps struct {
	Store CredStore
	// Sender delivers the verification and reset mails; Delivers says whether
	// it reaches a real inbox (mail.Config.Delivers).
	Sender   mail.Sender
	Delivers bool
}

// EnableNative mounts spec 015 on this handler when cfg.Enabled. It needs the
// 010 session key and APP_URL even when no social provider is listed.
func (h *Handler) EnableNative(cfg *NativeConfig, d NativeDeps) error {
	if cfg == nil || !cfg.Enabled {
		return nil
	}
	if d.Store == nil {
		return errors.New("native sign-in needs a credential store")
	}
	if len(h.cfg.SessionKey) < minSessionKeyLen || isPlaceholder(h.cfg.SessionKey) {
		return fmt.Errorf("SPOOL_HUB_AUTH_SESSION_KEY must be set to at least %d bytes while SPOOL_HUB_AUTH_NATIVE_ENABLED=true", minSessionKeyLen)
	}
	if err := checkURL("SPOOL_HUB_AUTH_APP_URL", h.cfg.AppURL, h.cfg.requireHTTPS()); err != nil {
		return err
	}
	if h.cfg.CookieName == "" {
		return errors.New("SPOOL_HUB_AUTH_COOKIE_NAME must not be empty")
	}
	if h.sessionKey == nil {
		h.stateKey = subkey(h.cfg.SessionKey, labelState)
		h.sessionKey = subkey(h.cfg.SessionKey, labelSession)
	}
	dummy, err := HashPassword("spool-native-timing-equaliser", cfg.argon2())
	if err != nil {
		return err
	}
	sender := d.Sender
	if sender == nil {
		sender = mail.None{}
	}
	h.native = &native{h: h, cfg: cfg, store: d.Store, sender: sender, delivers: d.Delivers,
		lim: newLimiter(cfg.RateWindow, h.now), dummy: dummy,
		log: h.log.With().Str("provider", ProviderPassword).Logger()}
	return nil
}

func (n *native) register(mux *http.ServeMux) {
	mux.HandleFunc("POST "+RoutePrefix+"register", n.handleRegister)
	mux.HandleFunc("POST "+RoutePrefix+"email/verify", n.handleVerify)
	mux.HandleFunc("POST "+RoutePrefix+"login", n.handleLogin)
	mux.HandleFunc("POST "+RoutePrefix+"password/forgot", n.handleForgot)
	mux.HandleFunc("POST "+RoutePrefix+"password/reset", n.handleReset)
	mux.HandleFunc("POST "+RoutePrefix+"password/change", n.handleChange)
}

// --- request plumbing ------------------------------------------------------

// readNativeJSON enforces FR-009 (JSON only) and the body cap; false = answered.
func readNativeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	w.Header().Set("Cache-Control", "no-store")
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json")
		return false
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxNativeBody)).Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		return false
	}
	return true
}

// limit applies one in-process ceiling (FR-006b); false = 429 answered.
func (n *native) limit(w http.ResponseWriter, key string, max int) bool {
	ok, retry := n.lim.Allow(key, max)
	if ok {
		return true
	}
	secs := int(retry.Seconds()) + 1
	w.Header().Set("Retry-After", strconv.Itoa(secs))
	writeErr(w, http.StatusTooManyRequests, ErrTokRateLimited, "too many attempts")
	n.log.Warn().Str("bucket", strings.SplitN(key, ":", 2)[0]).Msg("auth.native_rate_limited")
	return false
}

func (n *native) ip(r *http.Request) string { return clientIP(r, n.cfg.TrustedProxyHops) }

// normEmail lower-cases and validates a bare address (FR-003); "" = invalid.
func normEmail(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	if len(s) < 3 || len(s) > 320 {
		return ""
	}
	a, err := netmail.ParseAddress(s)
	if err != nil || a.Address != s || a.Name != "" {
		return ""
	}
	return s
}

// maxPasswordLen bounds every password the hub hashes or checks: argon2 on
// an unbounded input is a CPU lever.
const maxPasswordLen = 1024

func (n *native) passwordOK(w http.ResponseWriter, pw string) bool {
	if len(pw) < n.cfg.PasswordMinLen {
		writeErr(w, http.StatusBadRequest, "bad_request", "password_too_short: min "+strconv.Itoa(n.cfg.PasswordMinLen))
		return false
	}
	if len(pw) > maxPasswordLen {
		writeErr(w, http.StatusBadRequest, "bad_request", "password_too_long: max "+strconv.Itoa(maxPasswordLen))
		return false
	}
	return true
}

// newToken is 32 bytes of crypto/rand as hex; only its sha256 is stored (FR-002).
func newToken() (plain, hash string, err error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", "", err
	}
	plain = hex.EncodeToString(b)
	return plain, tokenHash(plain), nil
}

func tokenHash(plain string) string {
	sum := sha256.Sum256([]byte(plain))
	return hex.EncodeToString(sum[:])
}

// link is the WUI page the mail opens, in loc under prefix_except_default
// routing: no prefix for SPOOL_HUB_DEFAULT_LOCALE, "/<loc>" otherwise
// (csi-rel mail.VerifyEmailURL).
func (n *native) link(page, tok, loc string) string {
	return strings.TrimRight(n.h.cfg.AppURL, "/") + i18n.URLPrefix(loc, n.h.defLocale) + page + "?" +
		url.Values{"token": {tok}}.Encode()
}

// mailLocale picks a native mail's language: the human's picked locale when
// the credential already has one (csi-rel COALESCE(u.preferred_locale)),
// else the locale the credential was registered in, else this request's.
func (n *native) mailLocale(ctx context.Context, email, credLocale, reqLocale string) string {
	if p := n.h.prefs; p != nil {
		loc, err := p.IdentityLocale(ctx, ProviderPassword, email)
		if err != nil {
			n.log.Warn().Err(err).Msg("auth.native_mail_locale lookup (non-fatal)")
		} else if i18n.IsSupported(loc) {
			return loc
		}
	}
	if i18n.IsSupported(credLocale) {
		return credLocale
	}
	return reqLocale
}

func (n *native) ctx(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), 10*time.Second)
}

// answer adds 200 {"debug_token"} when debug tokens are on and a token
// was issued; otherwise the caller's enumeration-safe status.
func (n *native) answer(w http.ResponseWriter, status int, body map[string]any, tok string) {
	if n.cfg.DebugTokens && tok != "" {
		if body == nil {
			body = map[string]any{}
		}
		body["debug_token"] = tok
		if status == http.StatusNoContent {
			status = http.StatusOK
		}
	}
	if status == http.StatusNoContent {
		w.WriteHeader(status)
		return
	}
	writeJSON(w, status, body)
}

// --- routes ------------------------------------------------------------------

type registerReq struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	Name     string `json:"name"`
}

// handleRegister: the same 202 for every well-formed request (FR-005). A new
// address gets a credential; an unverified one gets a fresh link carrying the
// password of THIS call (FR-015); a verified one gets nothing.
func (n *native) handleRegister(w http.ResponseWriter, r *http.Request) {
	if !n.limit(w, "form:"+n.ip(r), n.cfg.FormPerIP) {
		return
	}
	var req registerReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	email := normEmail(req.Email)
	if email == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "email")
		return
	}
	if !n.passwordOK(w, req.Password) {
		return
	}
	if n.cfg.VerifyRequired && !n.delivers && !n.cfg.DebugTokens {
		n.log.Error().Str("event", "email_verification_undeliverable").
			Msg("auth.native_register refused: no mail transport while verification is required")
		writeErr(w, http.StatusServiceUnavailable, ErrTokMailUnavailable, "email delivery unavailable")
		return
	}
	name := CleanDisplayName(req.Name) // it was cut at 200 BYTES, mid-rune
	hash, err := HashPassword(req.Password, n.cfg.argon2())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "hash")
		return
	}
	ctx, cancel := n.ctx(r)
	defer cancel()
	now := n.h.now()
	status := "verification_required"
	reqLocale := n.h.RequestLocale(r)
	cred := Credential{Subject: email, PasswordHash: hash, DisplayName: name, Locale: reqLocale}
	if !n.cfg.VerifyRequired {
		// lde only: the credential may sign in, but stays unverified, so it
		// never reaches the Registrar (FR-004).
		status = "registered"
	}
	created, err := n.store.CreateCredential(ctx, cred, now)
	if err != nil {
		n.log.Error().Err(err).Msg("auth.native_register store")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "store")
		return
	}
	var tok string
	if n.cfg.VerifyRequired {
		existing := cred
		if !created {
			if existing, err = n.store.GetCredential(ctx, email); err != nil {
				n.log.Error().Err(err).Msg("auth.native_register lookup")
			}
		}
		if err == nil && !existing.Verified() {
			tok = n.issue(ctx, TokenVerify, email, hash, now, n.mailLocale(ctx, email, existing.Locale, reqLocale))
		}
	}
	n.log.Info().Str("email", digest(email)).Bool("created", created).Msg("auth.native_register")
	n.answer(w, http.StatusAccepted, map[string]any{"status": status}, tok)
}

// issue mints, stores and mails one token under the account floor. It
// returns the plaintext only for the debug body; "" = nothing issued.
func (n *native) issue(ctx context.Context, kind, email, pwHash string, now time.Time, loc string) string {
	plain, th, err := newToken()
	if err != nil {
		return ""
	}
	ttl, page := n.cfg.VerifyTTL, "/verify-email"
	if kind == TokenReset {
		ttl, page = n.cfg.ResetTTL, "/reset-password"
	}
	issued, err := n.store.IssueToken(ctx, kind, email, th, pwHash, now, now.Add(ttl),
		MailFloor{MinInterval: n.cfg.MailMinInterval, MaxPerDay: n.cfg.MailMaxPerDay})
	if err != nil {
		n.log.Error().Err(err).Str("kind", kind).Msg("auth.native_token_issue")
		return ""
	}
	if !issued {
		n.log.Warn().Str("kind", kind).Str("email", digest(email)).Msg("auth.native_mail_floor")
		return ""
	}
	link := n.link(page, plain, loc)
	render := mail.EmailVerification
	if kind == TokenReset {
		render = mail.PasswordReset
	}
	msg, err := render(email, loc, link, ttl)
	if err != nil {
		n.log.Error().Err(err).Str("kind", kind).Msg("auth.native_mail_render (non-fatal)")
		return plain
	}
	n.log.Info().Str("kind", kind).Str("locale", msg.Locale).Msg("auth.native_mail_locale")
	if err := n.sender.Send(ctx, msg); err != nil {
		// Best effort: the answer stays enumeration-safe; the person can retry.
		n.log.Error().Err(err).Str("kind", kind).Msg("auth.native_mail_send (non-fatal)")
	}
	return plain
}

type tokenReq struct {
	Token    string `json:"token"`
	Password string `json:"password"`
}

func (n *native) handleVerify(w http.ResponseWriter, r *http.Request) {
	if !n.limit(w, "form:"+n.ip(r), n.cfg.FormPerIP) {
		return
	}
	var req tokenReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	t := strings.TrimSpace(req.Token)
	if t == "" {
		writeErr(w, http.StatusUnauthorized, ErrTokVerifyInvalid, "token")
		return
	}
	// The clicker confirms the password the link was issued for: the mail
	// proves the mailbox, not who chose the password.
	if req.Password == "" || len(req.Password) > maxPasswordLen {
		writeErr(w, http.StatusUnauthorized, ErrTokInvalidCredentials, "password required")
		return
	}
	ctx, cancel := n.ctx(r)
	defer cancel()
	accept := func(pwHash string) bool { return VerifyPassword(pwHash, req.Password) == nil }
	switch err := n.store.ConsumeVerification(ctx, tokenHash(t), n.h.now(), accept); {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrVerifyPasswordMismatch):
		n.log.Info().Msg("auth.native_verify password mismatch")
		writeErr(w, http.StatusUnauthorized, ErrTokInvalidCredentials, "password does not match")
	case errors.Is(err, ErrTokenExpired):
		writeErr(w, http.StatusGone, ErrTokVerifyExpired, "token expired")
	case errors.Is(err, ErrTokenInvalid):
		writeErr(w, http.StatusUnauthorized, ErrTokVerifyInvalid, "token")
	default:
		n.log.Error().Err(err).Msg("auth.native_verify store")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "store")
	}
}

type loginReq struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	Tenant   string `json:"tenant"`
	Redirect string `json:"redirect"`
}

type loginResp struct {
	Session
	Redirect string `json:"redirect"`
	// The same operator grant GET /session answers (005 T035), so the WUI can
	// adopt these claims without a second probe. Computed, never signed in.
	DiagnosticsEnabled bool `json:"diagnostics_enabled"`
	// PreferredTheme as GET /session answers it, null when unset.
	PreferredTheme *string `json:"preferred_theme"`
	// SubmitKey as GET /session answers it (SPL-976), null when unset.
	SubmitKey *string `json:"submit_key"`
	// RailOrder as GET /session answers it (SPL-979), null when unset.
	RailOrder []string `json:"rail_order"`
	// MessageOrder and ComposerPosition as GET /session answers them (topic
	// c6994436), null when unset.
	MessageOrder     *string `json:"message_order"`
	ComposerPosition *string `json:"composer_position"`
	// IssuesView as GET /session answers it (SPL-1028), null when unset.
	IssuesView *string `json:"issues_view"`
	// CloseButtons as GET /session answers it (SPL-1133), null when unset.
	CloseButtons *string `json:"close_buttons"`
	// LinkPreviews as GET /session answers it (topic e1f8f797), null when unset.
	LinkPreviews *string `json:"link_previews"`
	// IssuesColumns as GET /session answers it (SPL-1132), null when unset.
	IssuesColumns map[string]int `json:"issues_columns"`
	// IssuesSort as GET /session answers it (CLE-35099), null when unset.
	IssuesSort *IssuesSort `json:"issues_sort"`
	// PaneSizes as GET /session answers it (CLE-35099, SPL-1182), null when unset.
	PaneSizes json.RawMessage `json:"pane_sizes"`
	// TimeZone as GET /session answers it (CLE-77908), null when unset.
	TimeZone *string `json:"time_zone"`
	// KeyboardShortcuts as GET /session answers it (HUM-10 ae2e5093), null when unset.
	KeyboardShortcuts *bool `json:"keyboard_shortcuts"`
}

func (n *native) handleLogin(w http.ResponseWriter, r *http.Request) {
	if !n.limit(w, "login-ip:"+n.ip(r), n.cfg.LoginPerIP) {
		return
	}
	var req loginReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	email := normEmail(req.Email)
	if !n.loginEmailAllowed(w, r, email) {
		return
	}
	ctx, cancel := n.ctx(r)
	defer cancel()
	cred, ok := n.checkPassword(ctx, w, email, req.Password)
	if !ok {
		return
	}
	now := n.h.now()
	sess := Session{V: 1, Provider: ProviderPassword, Subject: email, Email: email, Name: cred.DisplayName,
		IssuedAt: now.Unix(), Exp: now.Add(n.h.cfg.SessionTTL).Unix()}
	if validTenant(req.Tenant) {
		sess.Tenant = req.Tenant
	}
	if !n.registerLogin(ctx, w, cred, &sess) {
		return
	}
	tok, err := signToken(n.h.sessionKey, sess)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "sign session")
		return
	}
	if err := n.store.TouchLogin(ctx, email, now); err != nil {
		n.log.Warn().Err(err).Msg("auth.native_login touch (non-fatal)")
	}
	http.SetCookie(w, n.h.sessionCookie(tok, int(n.h.cfg.SessionTTL.Seconds())))
	n.log.Info().Str("email", digest(email)).Str("tenant", sess.Tenant).Msg("auth.login_ok")
	// CLE-77799: the durable sign-in event for the Activity log (method password).
	n.h.recordAuth(r, sess.Tenant, sess.HumanID, "sign_in", ProviderPassword)
	writeJSON(w, http.StatusOK, n.loginAnswer(ctx, sess, req.Redirect))
}

// loginEmailAllowed spends the per-email ceilings. The ceiling is per
// (email, client IP), so a stranger's wrong guesses from their address no
// longer lock the owner out from theirs (it was spent before the password
// check, keyed on the email alone: ten posts locked any known address for 15
// minutes). A tenfold per-email ceiling across ALL addresses still bounds a
// guess spread over many IPs.
func (n *native) loginEmailAllowed(w http.ResponseWriter, r *http.Request, email string) bool {
	return email == "" || (n.limit(w, "login-email:"+email+"|"+n.ip(r), n.cfg.LoginPerEmail) &&
		n.limit(w, "login-email-all:"+email, 10*n.cfg.LoginPerEmail))
}

// checkPassword answers the credential of email when password matches it
// and it may sign in; otherwise it has written the refusal. An unknown email
// costs the same hash as a wrong password and answers the same 401 (FR-005).
func (n *native) checkPassword(ctx context.Context, w http.ResponseWriter, email, password string) (Credential, bool) {
	var cred Credential
	err := ErrCredNotFound
	if email != "" {
		cred, err = n.store.GetCredential(ctx, email)
	}
	if err != nil && !errors.Is(err, ErrCredNotFound) {
		n.log.Error().Err(err).Msg("auth.native_login store")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "store")
		return cred, false
	}
	if errors.Is(err, ErrCredNotFound) {
		_ = VerifyPassword(n.dummy, password) // equal timing (FR-005)
		writeErr(w, http.StatusUnauthorized, ErrTokInvalidCredentials, "email or password")
		return cred, false
	}
	if VerifyPassword(cred.PasswordHash, password) != nil {
		n.log.Warn().Str("email", digest(email)).Msg("auth.native_login_fail")
		writeErr(w, http.StatusUnauthorized, ErrTokInvalidCredentials, "email or password")
		return cred, false
	}
	// Past the password on purpose: this branch enumerates nothing.
	if !cred.Verified() && n.cfg.VerifyRequired {
		writeErr(w, http.StatusForbidden, ErrTokEmailUnverified, "confirm your email first")
		return cred, false
	}
	return cred, true
}

// registerLogin names the human of a verified credential through the
// Registrar and binds the session's tenant. The Registrar treats
// Identity.Email as verified and matches invites on it, so an unverified
// credential never reaches it (FR-004). false has written the refusal.
func (n *native) registerLogin(ctx context.Context, w http.ResponseWriter, cred Credential, sess *Session) bool {
	if n.h.reg == nil || !cred.Verified() {
		return true
	}
	hum, landed, err := n.h.registerLanding(ctx, Identity{Provider: ProviderPassword, Subject: sess.Email, Email: sess.Email,
		Name: cred.DisplayName}, sess.Tenant)
	if errors.Is(err, ErrInviteExpired) {
		n.log.Warn().Str("email", digest(sess.Email)).Str("tenant", sess.Tenant).Msg("auth.native_login_invite_expired")
		writeErr(w, http.StatusForbidden, ErrCodeInviteExpired, "invite expired")
		return false
	}
	if errors.Is(err, ErrNotAllowed) {
		n.log.Warn().Str("email", digest(sess.Email)).Str("tenant", sess.Tenant).Msg("auth.native_login_not_allowed")
		writeErr(w, http.StatusForbidden, ErrCodeNotAllowed, "registrar refused")
		return false
	}
	if err != nil {
		n.log.Error().Err(err).Msg("auth.native_login registrar")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "registrar")
		return false
	}
	sess.HumanID, sess.Tenant = hum, landed
	n.h.bindTenant(ctx, sess)
	return true
}

// loginAnswer names the human as the session read does (the cookie keeps
// the credential's name, as every other claim of it) and carries the
// person's preferences.
func (n *native) loginAnswer(ctx context.Context, sess Session, redirect string) loginResp {
	// The login binds sess.Tenant (the ?tenant= of the flow, else the sole
	// membership), so the answer carries THAT tenant's per-tenant settings
	// (rdb 0078) with no second probe. Cold path: read the override directly.
	override := n.h.membershipOverride(ctx, sess.HumanID, sess.Tenant)
	ctx = n.h.withSettings(ctx, sess, override) // one settings read for the whole answer (SPL-1100)
	claims := sess
	claims.Name = n.h.shownName(ctx, sess)
	return loginResp{Session: claims, Redirect: safeRedirect(redirect),
		DiagnosticsEnabled: n.h.diagnosticsGrant(ctx, sess), PreferredTheme: n.h.preferredTheme(ctx, sess),
		SubmitKey: n.h.submitKey(ctx, sess), RailOrder: n.h.railOrder(ctx, sess),
		MessageOrder: n.h.viewPref(ctx, sess, PrefMessageOrder), ComposerPosition: n.h.viewPref(ctx, sess, PrefComposerPosition),
		IssuesView: n.h.viewPref(ctx, sess, PrefIssuesView), CloseButtons: n.h.viewPref(ctx, sess, PrefCloseButtons),
		LinkPreviews:  n.h.viewPref(ctx, sess, PrefLinkPreviews),
		IssuesColumns: n.h.issueColumns(ctx, sess), IssuesSort: n.h.issuesSort(ctx, sess), PaneSizes: n.h.paneSizes(ctx, sess),
		TimeZone: n.h.timeZone(ctx, sess), KeyboardShortcuts: n.h.keyboardShortcuts(ctx, sess)}
}

type emailReq struct {
	Email string `json:"email"`
}

// handleForgot always answers 204 (FR-005); the floor refusal is the same 204.
func (n *native) handleForgot(w http.ResponseWriter, r *http.Request) {
	if !n.limit(w, "form:"+n.ip(r), n.cfg.FormPerIP) {
		return
	}
	var req emailReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	email := normEmail(req.Email)
	var tok string
	if email != "" {
		ctx, cancel := n.ctx(r)
		defer cancel()
		switch cred, err := n.store.GetCredential(ctx, email); {
		case err == nil:
			tok = n.issue(ctx, TokenReset, email, "", n.h.now(),
				n.mailLocale(ctx, email, cred.Locale, n.h.RequestLocale(r)))
		case errors.Is(err, ErrCredNotFound):
			// No password to reset - but the address may still be a real
			// account that signs in with an IdP. Before CLE-3451 this branch
			// did nothing at all, so a Google-only address got a 204 and no
			// mail: indistinguishable from a broken site, with no recovery
			// path. Mail THAT person which button to use; an address nobody
			// has still gets nothing (FR-005 is unweakened, see
			// forgotFederated).
			n.forgotFederated(ctx, r, email)
		default:
			n.log.Error().Err(err).Msg("auth.native_forgot store")
		}
	}
	n.answer(w, http.StatusNoContent, nil, tok)
}

// forgotFederated mails the "this address signs in with <provider>" note when
// email is a known IdP-only account. It never touches the response: the route
// answers the same 204 either way, so the wire still enumerates nothing.
//
// FR-005 for an address that does not exist AT ALL is unchanged on purpose:
// no lookup result, no mail, and no log line that tells it apart from any
// other miss. Only a KNOWN account produces a mail or a log event.
func (n *native) forgotFederated(ctx context.Context, r *http.Request, email string) {
	if n.h.federated == nil {
		return
	}
	provs, locale, err := n.h.federated.FederatedAccount(ctx, email)
	if err != nil {
		n.log.Error().Err(err).Msg("auth.native_forgot federated lookup (non-fatal)")
		return
	}
	if len(provs) == 0 {
		return // not an account: exactly what this branch did before CLE-3451
	}
	// One note per address per rate window, so an always-204 route cannot be
	// turned into a mail amplifier. The refusal is silent on the wire, like
	// the credential floor above it.
	if ok, _ := n.lim.Allow("forgot-federated:"+email, 1); !ok {
		n.log.Warn().Str("email", digest(email)).Msg("auth.native_federated_mail_floor")
		return
	}
	if !i18n.IsSupported(locale) {
		locale = n.h.RequestLocale(r)
	}
	msg, err := mail.FederatedSignIn(email, locale, provs, n.signInURL(locale))
	if err != nil {
		n.log.Error().Err(err).Msg("auth.native_federated_mail_render (non-fatal)")
		return
	}
	n.log.Info().Str("email", digest(email)).Strs("providers", provs).
		Str("locale", msg.Locale).Msg("auth.native_forgot_federated")
	if err := n.sender.Send(ctx, msg); err != nil {
		n.log.Error().Err(err).Msg("auth.native_federated_mail_send (non-fatal)")
	}
}

// signInURL is the WUI login page in loc, carrying no token and no tenant
// (the same prefix_except_default routing as link).
func (n *native) signInURL(loc string) string {
	return strings.TrimRight(n.h.cfg.AppURL, "/") + i18n.URLPrefix(loc, n.h.defLocale) + "/login"
}

func (n *native) handleReset(w http.ResponseWriter, r *http.Request) {
	if !n.limit(w, "form:"+n.ip(r), n.cfg.FormPerIP) {
		return
	}
	var req tokenReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	t := strings.TrimSpace(req.Token)
	if t == "" {
		writeErr(w, http.StatusUnauthorized, ErrTokResetInvalid, "token")
		return
	}
	if !n.passwordOK(w, req.Password) {
		return
	}
	hash, err := HashPassword(req.Password, n.cfg.argon2())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "hash")
		return
	}
	ctx, cancel := n.ctx(r)
	defer cancel()
	subject, err := n.store.ConsumeReset(ctx, tokenHash(t), hash, n.h.now())
	if errors.Is(err, ErrTokenInvalid) {
		writeErr(w, http.StatusUnauthorized, ErrTokResetInvalid, "token")
		return
	}
	if err != nil {
		n.log.Error().Err(err).Msg("auth.native_reset store")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "store")
		return
	}
	n.log.Info().Str("email", digest(subject)).Msg("auth.native_password_reset")
	w.WriteHeader(http.StatusNoContent)
}

type changeReq struct {
	Current string `json:"current_password"`
	New     string `json:"new_password"`
}

func (n *native) handleChange(w http.ResponseWriter, r *http.Request) {
	s, ok := n.h.SessionFromRequest(r)
	if !ok || s.Provider != ProviderPassword {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no password session")
		return
	}
	if !n.limit(w, "login-email:"+s.Subject, n.cfg.LoginPerEmail) {
		return
	}
	var req changeReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	if !n.passwordOK(w, req.New) {
		return
	}
	ctx, cancel := n.ctx(r)
	defer cancel()
	cred, err := n.store.GetCredential(ctx, s.Subject)
	if err != nil && !errors.Is(err, ErrCredNotFound) {
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "store")
		return
	}
	if err != nil || VerifyPassword(cred.PasswordHash, req.Current) != nil {
		writeErr(w, http.StatusUnauthorized, ErrTokInvalidCredentials, "current password")
		return
	}
	hash, err := HashPassword(req.New, n.cfg.argon2())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "hash")
		return
	}
	if err := n.store.SetPassword(ctx, s.Subject, hash, n.h.now()); err != nil {
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "store")
		return
	}
	// Stateless sessions: this browser signs in again; others expire (OQ-N2).
	http.SetCookie(w, n.h.sessionCookie("", -1))
	n.log.Info().Str("email", digest(s.Subject)).Msg("auth.native_password_changed")
	w.WriteHeader(http.StatusNoContent)
}
