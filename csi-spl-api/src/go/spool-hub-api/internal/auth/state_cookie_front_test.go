package auth_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// Spec 010 T056: /start runs on the API host, and the IdP returns to the WUI
// host, which Firebase Hosting rewrites to the hub. Hosting forwards ONLY the
// "__session" request cookie, so the state cookie must be named that or the
// callback cannot bind the state to the browser. The front below strips every
// other cookie, as Hosting does (csi-rel 089 tasks.md step 4).
// CONTROL: the default name through the same front fails with invalid_state.
func TestStateCookieSurvivesFirebaseFront(t *testing.T) {
	for _, tc := range []struct {
		name, stateCookie, want string
	}{
		{"__session passes the front", "__session", ""},
		{"CONTROL default name is stripped", "", auth.ErrCodeState},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var hub http.Handler
			front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var keep []string
				for _, c := range r.Cookies() {
					if c.Name == "__session" {
						keep = append(keep, c.String())
					}
				}
				r.Header.Del("Cookie")
				if len(keep) > 0 {
					r.Header.Set("Cookie", strings.Join(keep, "; "))
				}
				hub.ServeHTTP(w, r)
			}))
			t.Cleanup(front.Close)
			extra := map[string]string{}
			if tc.stateCookie != "" {
				extra["SPOOL_HUB_AUTH_STATE_COOKIE_NAME"] = tc.stateCookie
			}
			r := newRigFront(t, auth.Options{Registrar: registrar{}}, extra, front.URL)
			hub = r.h
			c := browser(t)
			resp, err := c.Get(r.hub + "/api/v1/auth/google/start?redirect=/t/t1")
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
			if tc.want == "" {
				if !strings.HasPrefix(resp.Request.URL.String(), r.wui+"/t/t1") {
					t.Fatalf("landed on %s, want the WUI /t/t1", resp.Request.URL)
				}
				return
			}
			if got := authError(resp.Request.URL); got != tc.want {
				t.Fatalf("auth_error = %q, want %q", got, tc.want)
			}
		})
	}
}

// T056: the state cookie carries the session cookie's Domain, so a /start on
// api.<base> is sent to the callback on <fqdn>; and it may not reuse the
// session cookie's name.
func TestStateCookieDomainAndName(t *testing.T) {
	r := newRigFront(t, auth.Options{Registrar: registrar{}}, map[string]string{
		"SPOOL_HUB_AUTH_STATE_COOKIE_NAME": "__session",
		"SPOOL_HUB_AUTH_COOKIE_DOMAIN":     "example.test",
	}, "")
	resp, err := noFollow(browser(t)).Get(r.hub + "/api/v1/auth/google/start")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	var set string
	for _, v := range resp.Header.Values("Set-Cookie") {
		if strings.HasPrefix(v, "__session=") {
			set = v
		}
	}
	for _, want := range []string{"Domain=example.test", "Path=/api/v1/auth/", "HttpOnly", "SameSite=Lax"} {
		if !strings.Contains(set, want) {
			t.Fatalf("state Set-Cookie %q lacks %s", set, want)
		}
	}
	if _, err := auth.LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":            "google",
		"SPOOL_HUB_AUTH_SESSION_KEY":          strings.Repeat("s", 32),
		"SPOOL_HUB_AUTH_APP_URL":              "http://localhost:3000",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID":     "gid",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET": "gsecret",
		"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI":  "http://localhost:3000/api/v1/auth/google/callback",
		"SPOOL_HUB_AUTH_STATE_COOKIE_NAME":    "spool_session",
	}); err == nil || !strings.Contains(err.Error(), "STATE_COOKIE_NAME") {
		t.Fatal("a state cookie named like the session cookie was accepted")
	}
}
