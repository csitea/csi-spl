package hub_test

import (
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// SPL-5589: the WUI's channel Properties > Settings > Boxes reads GET /v1/pins
// cross-origin with the upload token in Authorization (SPL-5560). That needs a
// CORS preflight; prd answered OPTIONS /v1/pins 405 with no CORS header, so the
// browser refused the GET and the dialog showed "The boxes could not be
// loaded." An allow-listed origin now gets a 204 preflight and a readable GET
// (the 401 door too, so the WUI can redial for a fresh token). CONTROL: a
// foreign origin and a box (no Origin) get no CORS header.
func TestListPinsCORSForTheWUIOrigin(t *testing.T) {
	const wui, evil = "https://wui.example.com", "https://evil.example.com"
	e := newEnv(t, func(o *hub.Options) { o.ViewCORSOrigins = []string{wui} })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	tok := e.uploadToken(tid, a)
	do := func(method, origin, bearer string, hdr ...string) (int, http.Header, string) {
		t.Helper()
		req, _ := http.NewRequest(method, e.url(tid)+"/v1/pins", nil)
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		for i := 0; i+1 < len(hdr); i += 2 {
			req.Header.Set(hdr[i], hdr[i+1])
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatalf("%s /v1/pins: %v", method, err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header, string(b)
	}

	code, h, _ := do(http.MethodOptions, wui, "",
		"Access-Control-Request-Method", "GET", "Access-Control-Request-Headers", "authorization")
	if code != http.StatusNoContent || h.Get("Access-Control-Allow-Origin") != wui ||
		!strings.Contains(h.Get("Access-Control-Allow-Methods"), "GET") ||
		!strings.Contains(h.Get("Access-Control-Allow-Headers"), "Authorization") {
		t.Fatalf("OPTIONS /v1/pins from the WUI origin: %d %v, want 204 with CORS for GET + Authorization", code, h)
	}
	code, h, body := do(http.MethodGet, wui, tok)
	if code != http.StatusOK || !strings.Contains(body, `"box-a"`) || h.Get("Access-Control-Allow-Origin") != wui {
		t.Fatalf("GET /v1/pins from the WUI origin: %d ACAO=%q body=%s", code, h.Get("Access-Control-Allow-Origin"), body)
	}
	code, h, _ = do(http.MethodGet, wui, "stale-token")
	if code != http.StatusUnauthorized || h.Get("Access-Control-Allow-Origin") != wui {
		t.Fatalf("GET /v1/pins 401 door must carry CORS so the WUI can redial: %d %v", code, h)
	}

	// CONTROL: a foreign origin gets nothing, preflight included.
	for _, m := range []string{http.MethodOptions, http.MethodGet} {
		_, h, _ = do(m, evil, tok, "Access-Control-Request-Method", "GET")
		if h.Get("Access-Control-Allow-Origin") != "" || h.Get("Access-Control-Allow-Methods") != "" {
			t.Fatalf("%s /v1/pins from a foreign origin got CORS: %v", m, h)
		}
	}
	// CONTROL: a box's poll (no Origin) is unchanged and gets no CORS.
	code, h, body = do(http.MethodGet, "", tok)
	if code != http.StatusOK || !strings.Contains(body, `"box-a"`) || h.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("box GET /v1/pins: %d ACAO=%q body=%s", code, h.Get("Access-Control-Allow-Origin"), body)
	}
}
