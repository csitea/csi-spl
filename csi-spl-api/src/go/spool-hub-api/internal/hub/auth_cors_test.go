package hub_test

import (
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// Spec 010 T050 (FR-010): the WUI origin calls /api/v1/auth/* on the API host
// cross-origin with credentials. Allow-listed origin: ACAO = that origin +
// ACAC true (also with the token view door) and a 204 preflight for the
// native JSON POSTs. CONTROL: a foreign origin gets no CORS header at all,
// and a non-auth route is not touched by this policy.
func TestAuthCORSCredentialedForAllowListOnly(t *testing.T) {
	const wui, evil = "https://wui.example.com", "https://evil.example.com"
	ac, err := auth.LoadFrom("lde", map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	e := newEnv(t, func(o *hub.Options) {
		o.Auth = auth.New(ac, zerolog.Nop(), auth.Options{})
		o.ViewCORSOrigins = []string{wui}
	})
	do := func(method, path, origin string, hdr ...string) (int, http.Header, string) {
		t.Helper()
		req, _ := http.NewRequest(method, e.url("api")+path, nil)
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		for i := 0; i+1 < len(hdr); i += 2 {
			req.Header.Set(hdr[i], hdr[i+1])
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatalf("%s %s: %v", method, path, err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header, string(b)
	}

	code, h, body := do(http.MethodGet, "/api/v1/auth/providers", wui)
	if code != http.StatusOK || !strings.Contains(body, `"providers"`) {
		t.Fatalf("providers: %d %s", code, body)
	}
	if h.Get("Access-Control-Allow-Origin") != wui || h.Get("Access-Control-Allow-Credentials") != "true" {
		t.Fatalf("providers CORS: %v", h)
	}
	if !strings.Contains(strings.Join(h.Values("Vary"), ","), "Origin") {
		t.Fatalf("providers: no Vary: Origin: %v", h)
	}
	code, h, _ = do(http.MethodGet, "/api/v1/auth/session", wui)
	if code != http.StatusUnauthorized || h.Get("Access-Control-Allow-Origin") != wui || h.Get("Access-Control-Allow-Credentials") != "true" {
		t.Fatalf("session 401 must carry CORS so the WUI can read it: %d %v", code, h)
	}
	code, h, _ = do(http.MethodOptions, "/api/v1/auth/login", wui,
		"Access-Control-Request-Method", "POST", "Access-Control-Request-Headers", "content-type")
	if code != http.StatusNoContent || h.Get("Access-Control-Allow-Origin") != wui ||
		h.Get("Access-Control-Allow-Credentials") != "true" ||
		!strings.Contains(h.Get("Access-Control-Allow-Methods"), "POST") ||
		!strings.Contains(h.Get("Access-Control-Allow-Headers"), "Content-Type") {
		t.Fatalf("preflight: %d %v", code, h)
	}
	// the settings page PUTs preferences and every WUI call carries X-Locale.
	code, h, _ = do(http.MethodOptions, "/api/v1/auth/preferences", wui,
		"Access-Control-Request-Method", "PUT", "Access-Control-Request-Headers", "content-type,x-locale")
	if code != http.StatusNoContent || h.Get("Access-Control-Allow-Origin") != wui ||
		!strings.Contains(h.Get("Access-Control-Allow-Methods"), "PUT") ||
		!strings.Contains(h.Get("Access-Control-Allow-Headers"), "X-Locale") {
		t.Fatalf("preferences preflight: %d %v", code, h)
	}

	// CONTROL: a foreign origin gets nothing, preflight included.
	for _, m := range []string{http.MethodGet, http.MethodOptions} {
		_, h, _ = do(m, "/api/v1/auth/providers", evil, "Access-Control-Request-Method", "POST")
		if h.Get("Access-Control-Allow-Origin") != "" || h.Get("Access-Control-Allow-Credentials") != "" || h.Get("Access-Control-Allow-Methods") != "" {
			t.Fatalf("%s foreign origin got CORS: %v", m, h)
		}
	}
	// CONTROL: no Origin (the OAuth navigations) gets no CORS either.
	_, h, _ = do(http.MethodGet, "/api/v1/auth/providers", "")
	if h.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("no Origin got CORS: %v", h)
	}
	// CONTROL: outside /api/v1/auth/ the policy does not apply (token door:
	// the view routes keep their own, credential-less CORS).
	_, h, _ = do(http.MethodGet, "/version", wui)
	if h.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("/version got auth CORS: %v", h)
	}
}
