package hub

import (
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// authCORS answers credentialed CORS on every /api/v1/auth/* route (spec 010
// FR-010, T050): the WUI origin calls the hub's API host cross-origin with
// credentials 'include', as csi-rel httpapp.CORSConfig. The allow-list is the
// view one (SPOOL_HUB_VIEW_CORS_ORIGINS). Credentials are always allowed here,
// whatever the view door: sign-in IS the cookie. Never "*"; a foreign origin
// gets no CORS header, and its preflight is refused by the browser. The
// native POSTs require application/json, so they are always preflighted and
// the allow-list is their CSRF gate; the session cookie is SameSite=Lax, so a
// cross-site page never sends it at all.
func (s *Server) authCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, auth.RoutePrefix) {
			next.ServeHTTP(w, r)
			return
		}
		ok := s.allowAuthOrigin(w, r)
		if r.Method != http.MethodOptions {
			next.ServeHTTP(w, r)
			return
		}
		if ok {
			h := w.Header()
			h.Set("Access-Control-Allow-Methods", "GET, POST, PUT")
			// X-Locale: the WUI's active locale (i18n; a browser fetch may
			// not set Accept-Language cross-origin).
			h.Set("Access-Control-Allow-Headers", "Content-Type, X-Locale")
			h.Set("Access-Control-Max-Age", corsMaxAge)
		}
		w.WriteHeader(http.StatusNoContent)
	})
}

// allowAuthOrigin: an allow-listed Origin (exact, or a tenant host of this
// env, SPL-959) -> ACAO + credentials.
func (s *Server) allowAuthOrigin(w http.ResponseWriter, r *http.Request) bool {
	h := w.Header()
	h.Add("Vary", "Origin")
	o := r.Header.Get("Origin")
	if !s.originAllowed(o) {
		return false
	}
	h.Set("Access-Control-Allow-Origin", o)
	h.Set("Access-Control-Allow-Credentials", "true")
	return true
}
