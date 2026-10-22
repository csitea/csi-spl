// One-click "Dev login" (spec 148 §2.3.2, row B3): POST
// /api/v1/auth/dev-login signs the browser in as the owner of the local
// workspace, with no IdP and no password. It exists for local dev mode only:
// the switch defaults off, and every request on a hub whose SPOOL_HUB_ENV is
// not lde answers 404, whatever the switch says. The startup refusal of the
// switch on a dev or prd hub is internal/config's (row B4, spec §3.2).
package auth

import (
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// DevLoginEnv is the dev switch (spec 148 §2.3.2). Default off.
const DevLoginEnv = "SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED"

// The identity a dev login signs in as, and the workspace it lands in: the
// seeded default workspace of the local stack (spec 148 §2.3.2).
const (
	ProviderDev    = "dev"
	DevOwnerEmail  = "dev-owner@spool.local"
	DevOwnerName   = "Dev owner"
	DevWorkspace   = "main"
	devLoginHubEnv = "lde" // the only SPOOL_HUB_ENV a dev login answers on
)

// ErrCodeDevLoginNotOwner: the dev identity got a seat in the workspace but
// not the owner's (the workspace had members before its first dev login, so
// the bootstrap-owner seat went to someone else).
const ErrCodeDevLoginNotOwner = "dev_login_not_owner"

// devLoginEnabled reads the switch on every request, so it is never cached
// on in a process that was not started with it.
func devLoginEnabled() bool {
	on, err := strconv.ParseBool(strings.TrimSpace(os.Getenv(DevLoginEnv)))
	return err == nil && on
}

func (h *Handler) registerDevLogin(mux *http.ServeMux) {
	mux.HandleFunc("POST "+RoutePrefix+"dev-login", h.devLogin)
}

type devLoginReq struct {
	Redirect string `json:"redirect"`
}

type devLoginResp struct {
	Session
	Redirect string `json:"redirect"`
}

func (h *Handler) devLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if h.cfg.Env != devLoginHubEnv {
		if devLoginEnabled() {
			h.log.Warn().Str("event", "auth.dev_login_refused_production").Str("env", h.cfg.Env).
				Msg(DevLoginEnv + " is refused outside local dev mode")
		}
		http.NotFound(w, r)
		return
	}
	if !devLoginEnabled() {
		http.NotFound(w, r)
		return
	}
	// JSON only: a cross-site form cannot post it without a CORS preflight,
	// so no other page can sign a local browser in (login CSRF).
	var req devLoginReq
	if !readNativeJSON(w, r, &req) {
		return
	}
	if h.sessionKey == nil || h.reg == nil {
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable,
			"dev login needs the session key and the hub's registrar (native sign-in on)")
		return
	}
	id := Identity{Provider: ProviderDev, Subject: DevOwnerEmail, Email: DevOwnerEmail, Name: DevOwnerName,
		ClientIP: clientIP(r, h.hops)}
	hum, err := h.reg.Register(r.Context(), id, DevWorkspace)
	if err != nil {
		code, why := registrarRefusal(err)
		h.log.Warn().Err(err).Str("reason", code).Msg("auth.dev_login_fail")
		status := http.StatusForbidden
		if code == ErrCodeUnavailable {
			status = http.StatusServiceUnavailable
		}
		writeErr(w, status, code, why)
		return
	}
	if !h.devOwnerSeated(w, r, hum) {
		return
	}
	now := h.now()
	sess := Session{V: 1, Provider: ProviderDev, Subject: DevOwnerEmail, Email: DevOwnerEmail, Name: DevOwnerName,
		HumanID: hum, Tenant: DevWorkspace, IssuedAt: now.Unix(), Exp: now.Add(h.cfg.SessionTTL).Unix()}
	tok, err := signToken(h.sessionKey, sess)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "sign session")
		return
	}
	http.SetCookie(w, h.sessionCookie(tok, int(h.cfg.SessionTTL.Seconds())))
	h.log.Warn().Str("event", "auth.dev_login_ok").Str("tenant", DevWorkspace).Str("human_id", hum).
		Msg("dev login: signed in as the workspace owner (local dev mode)")
	h.recordAuth(r, DevWorkspace, hum, "sign_in", ProviderDev)
	writeJSON(w, http.StatusOK, devLoginResp{Session: sess, Redirect: safeRedirect(req.Redirect)})
}

// devOwnerSeated answers whether hum holds the owner seat of DevWorkspace,
// as the Membership's TenantLister lists it; false = the refusal is written.
// The seat itself is the registrar's to give (the bootstrap-owner policy on a
// fresh workspace): this package never writes the store.
func (h *Handler) devOwnerSeated(w http.ResponseWriter, r *http.Request, hum string) bool {
	tl, ok := h.members.(TenantLister)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "dev login needs the membership list")
		return false
	}
	roles, err := tl.Tenants(r.Context(), hum)
	if err != nil {
		h.log.Error().Err(err).Msg("auth.dev_login memberships")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "memberships")
		return false
	}
	for _, m := range roles {
		if m.TenantID == DevWorkspace && rbac.Legacy(m.Role) == rbac.BizOwner {
			return true
		}
	}
	h.log.Warn().Str("tenant", DevWorkspace).Str("human_id", hum).Msg("auth.dev_login_not_owner")
	writeErr(w, http.StatusConflict, ErrCodeDevLoginNotOwner,
		"the dev identity is not the owner of workspace "+DevWorkspace+": start from a fresh local stack")
	return false
}
