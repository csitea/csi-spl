package hub_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/payments"
)

// orderStub stands in for the checkout surface: the order submit answers 401,
// as the real one does without a session, so the test reads the CORS headers
// a refused submit carries (the WUI must read that 401 too).
type orderStub struct{}

func (orderStub) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST "+payments.RouteOrder, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
	})
	mux.HandleFunc("GET "+payments.RoutePrefix+"/plan", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
}

// Spec 181 B3 (SPL-6339): the private-workspace order submit needs the
// session cookie, so the WUI posts it to the API host cross-origin with
// credentials. It gets authCORS's policy: an allow-listed origin or a tenant
// host of this env -> the origin echoed + credentials, and a 204 preflight
// for the JSON POST. RED CONTROLS: a foreign origin gets no CORS header,
// preflight included; never "*"; the rest of /api/v1/checkout is untouched.
func TestOrderSubmitCredentialedCORS(t *testing.T) {
	const wui, evil = "https://wui.example.com", "https://evil.example.com"
	tenantOrigin := "https://acme" + domain
	ac, err := auth.LoadFrom("lde", map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	e := newEnv(t, func(o *hub.Options) {
		o.Auth = auth.New(ac, zerolog.Nop(), auth.Options{})
		o.ViewCORSOrigins = []string{wui}
		o.OriginTenant = hub.NewOriginTenant("{tenant}"+domain, "")
		o.Payments = orderStub{}
	})
	do := func(method, path, origin string, hdr ...string) (int, http.Header) {
		t.Helper()
		req, _ := http.NewRequest(method, e.url("api")+path, strings.NewReader(`{}`))
		req.Header.Set("Origin", origin)
		for i := 0; i+1 < len(hdr); i += 2 {
			req.Header.Set(hdr[i], hdr[i+1])
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatalf("%s %s: %v", method, path, err)
		}
		resp.Body.Close()
		return resp.StatusCode, resp.Header
	}
	for _, origin := range []string{wui, tenantOrigin} {
		code, h := do(http.MethodOptions, payments.RouteOrder, origin,
			"Access-Control-Request-Method", "POST", "Access-Control-Request-Headers", "content-type,x-locale")
		if code != http.StatusNoContent || h.Get("Access-Control-Allow-Origin") != origin ||
			h.Get("Access-Control-Allow-Credentials") != "true" ||
			!strings.Contains(h.Get("Access-Control-Allow-Methods"), "POST") ||
			!strings.Contains(h.Get("Access-Control-Allow-Headers"), "Content-Type") {
			t.Fatalf("%s preflight: %d %v", origin, code, h)
		}
		code, h = do(http.MethodPost, payments.RouteOrder, origin, "Content-Type", "application/json")
		if code != http.StatusUnauthorized || h.Get("Access-Control-Allow-Origin") != origin ||
			h.Get("Access-Control-Allow-Credentials") != "true" ||
			!strings.Contains(strings.Join(h.Values("Vary"), ","), "Origin") {
			t.Fatalf("%s POST: %d %v", origin, code, h)
		}
	}
	// RED CONTROL: a foreign origin (and a tenant-looking http origin) gets nothing.
	for _, origin := range []string{evil, "http://acme" + domain, "null"} {
		for _, m := range []string{http.MethodOptions, http.MethodPost} {
			_, h := do(m, payments.RouteOrder, origin, "Access-Control-Request-Method", "POST")
			if h.Get("Access-Control-Allow-Origin") != "" || h.Get("Access-Control-Allow-Credentials") != "" ||
				h.Get("Access-Control-Allow-Methods") != "" {
				t.Fatalf("%s %s got CORS: %v", m, origin, h)
			}
		}
	}
	// CONTROL: only the order submit joins the credentialed policy, not the
	// rest of the checkout surface.
	if _, h := do(http.MethodGet, payments.RoutePrefix+"/plan", wui); h.Get("Access-Control-Allow-Credentials") != "" {
		t.Fatalf("/checkout/plan got credentialed CORS: %v", h)
	}
	if _, h := do(http.MethodPost, payments.RouteOrder+"/x", wui); h.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("a path under the order route got CORS: %v", h)
	}
}
