package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"html"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Meta requires two app-level callbacks before it publishes a Facebook Login
// app (spec 010 FR-013, T043; donor csi-rel facebook_callbacks.go):
//
//	POST /api/v1/auth/facebook/deauthorize   — the person removed the app
//	POST /api/v1/auth/facebook/data-deletion — the person asked Facebook to
//	     have this app delete the data it got from Facebook
//
// The caller is Facebook, not a browser with our cookie: the ONLY thing that
// authorises either is the HMAC `signed_request`, so it is verified first and
// every defect refuses. Both sever the Facebook identity link through the
// hub's Unlinker (it never deletes the human; spool data is not Facebook's).
// The deletion confirmation code is self-verifying, so its status URL needs
// no table.

// IdentityUnlinker is the hub's hook to delete the stored (provider, subject)
// identity link (rdb 0006 human_identities). Idempotent: an unknown subject is
// not an error, Meta may resend.
type IdentityUnlinker interface {
	Unlink(ctx context.Context, provider, subject string) error
}

const labelFBDeletion = "spool-auth-fb-deletion-v1"

var errSignedRequest = errors.New("auth: invalid signed_request")

type fbSignedRequest struct {
	Algorithm string `json:"algorithm"`
	IssuedAt  int64  `json:"issued_at"`
	UserID    string `json:"user_id"`
}

// parseSignedRequest verifies Facebook's `<b64url sig>.<b64url payload>`:
// HMAC-SHA256 over the RAW payload segment with the app secret, algorithm
// HMAC-SHA256, a user_id present.
func parseSignedRequest(raw, appSecret string) (fbSignedRequest, error) {
	var out fbSignedRequest
	sigPart, payloadPart, ok := strings.Cut(raw, ".")
	if appSecret == "" || !ok || sigPart == "" || payloadPart == "" {
		return out, errSignedRequest
	}
	dec := func(s string) ([]byte, error) { // Facebook omits padding; tolerate it
		return base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
	}
	sig, err := dec(sigPart)
	if err != nil {
		return out, errSignedRequest
	}
	m := hmac.New(sha256.New, []byte(appSecret))
	m.Write([]byte(payloadPart))
	if !hmac.Equal(sig, m.Sum(nil)) {
		return out, errSignedRequest
	}
	payload, err := dec(payloadPart)
	if err != nil || json.Unmarshal(payload, &out) != nil ||
		!strings.EqualFold(out.Algorithm, "HMAC-SHA256") || out.UserID == "" {
		return fbSignedRequest{}, errSignedRequest
	}
	return out, nil
}

func (h *Handler) registerFacebookCallbacks(mux *http.ServeMux) {
	mux.HandleFunc("POST "+RoutePrefix+ProviderFacebook+"/deauthorize", h.facebookDeauthorize)
	mux.HandleFunc("POST "+RoutePrefix+ProviderFacebook+"/data-deletion", h.facebookDataDeletion)
	mux.HandleFunc("GET "+RoutePrefix+ProviderFacebook+"/data-deletion", h.facebookDeletionStatus)
}

// facebookUnlink verifies the signed request and severs the link; it writes
// the error answer itself and reports whether to go on.
func (h *Handler) facebookUnlink(w http.ResponseWriter, r *http.Request, event string) (fbSignedRequest, bool) {
	if _, on := h.idps[ProviderFacebook]; !on {
		writeErr(w, http.StatusNotFound, "not_found", "facebook is not enabled")
		return fbSignedRequest{}, false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	req, err := parseSignedRequest(r.PostFormValue("signed_request"), h.cfg.FacebookClientSecret)
	if err != nil {
		h.log.Warn().Str("event", event).Msg("auth.facebook_callback_refused")
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid signed_request")
		return req, false
	}
	if h.unlink != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		if err := h.unlink.Unlink(ctx, ProviderFacebook, req.UserID); err != nil {
			h.log.Error().Err(err).Str("event", event).Str("subject", digest(req.UserID)).Msg("auth.facebook_unlink_failed")
			writeErr(w, http.StatusInternalServerError, "internal", "unlink failed")
			return req, false
		}
	}
	h.log.Info().Str("event", event).Str("subject", digest(req.UserID)).Msg("auth.facebook_unlinked")
	return req, true
}

func (h *Handler) facebookDeauthorize(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.facebookUnlink(w, r, "deauthorize"); ok {
		w.WriteHeader(http.StatusOK)
	}
}

// facebookDataDeletion answers Meta's fixed shape {"url","confirmation_code"}.
func (h *Handler) facebookDataDeletion(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.facebookUnlink(w, r, "data_deletion"); !ok {
		return
	}
	code, err := h.newDeletionCode()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "code")
		return
	}
	h.log.Info().Str("confirmation_code", code).Msg("auth.facebook_data_deletion")
	status := strings.TrimRight(h.cfg.AppURL, "/") + RoutePrefix + ProviderFacebook + "/data-deletion?" +
		url.Values{"code": {code}}.Encode()
	writeJSON(w, http.StatusOK, map[string]string{"url": status, "confirmation_code": code})
}

// facebookDeletionStatus is the page Meta links the person to: 200 for a code
// this hub issued, 404 otherwise. A browser (Accept: text/html) gets a small
// self-contained page (spec 049 FR-F6); anything else the JSON.
func (h *Handler) facebookDeletionStatus(w http.ResponseWriter, r *http.Request) {
	code := r.URL.Query().Get("code")
	_, on := h.idps[ProviderFacebook]
	ok := on && h.validDeletionCode(code)
	if strings.Contains(r.Header.Get("Accept"), "text/html") {
		writeDeletionPage(w, ok, code)
		return
	}
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "unknown confirmation code")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"confirmation_code": code, "status": "completed"})
}

const deletionPageHead = `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
	`<meta name="viewport" content="width=device-width, initial-scale=1">` +
	`<title>Facebook data deletion - spool-hub</title><style>` +
	`:root{color-scheme:light dark}body{margin:0;font:16px/1.6 system-ui,sans-serif}` +
	`main{max-width:40rem;margin:0 auto;padding:2rem 1rem}code{overflow-wrap:anywhere}` +
	`</style></head><body><main><h1>Facebook data deletion</h1>`

func writeDeletionPage(w http.ResponseWriter, ok bool, code string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
	w.Header().Set("Cache-Control", "no-store")
	body := `<p>This confirmation code is unknown to spool-hub.</p>`
	status := http.StatusNotFound
	if ok {
		status = http.StatusOK
		body = `<p><strong>Status: completed.</strong> The link between your Facebook account and ` +
			`spool-hub has been deleted. spool-hub no longer signs you in with Facebook.</p>` +
			`<p>Confirmation code: <code>` + html.EscapeString(code) + `</code></p>` +
			`<p>To delete the rest of your spool-hub account, see the <a href="/privacy">privacy policy</a>.</p>`
	}
	w.WriteHeader(status)
	w.Write([]byte(deletionPageHead + body + `</main></body></html>`)) //nolint:errcheck
}

// A deletion code is <32 hex random>-<20 hex MAC of it>.
func (h *Handler) deletionMAC(id string) string {
	m := hmac.New(sha256.New, subkey(h.cfg.SessionKey, labelFBDeletion))
	m.Write([]byte(id))
	return hex.EncodeToString(m.Sum(nil)[:10])
}

func (h *Handler) newDeletionCode() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	id := hex.EncodeToString(b)
	return id + "-" + h.deletionMAC(id), nil
}

func (h *Handler) validDeletionCode(code string) bool {
	id, mac, ok := strings.Cut(code, "-")
	return ok && len(id) == 32 && hmac.Equal([]byte(mac), []byte(h.deletionMAC(id)))
}
