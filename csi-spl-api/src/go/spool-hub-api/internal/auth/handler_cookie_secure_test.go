package auth

import (
	"net/http"
	"strings"
	"testing"

	"github.com/rs/zerolog"
)

// SPL-1285: the session cookie is HttpOnly + SameSite=Lax always, and Secure
// exactly when cfg.CookieSecure is on. This is what makes the nosemgrep on the
// cookie Secure flag safe: the flag is config-driven, not dropped. The
// companion cnf gate (cookie-secure-cnf.tst.sh) pins dev+prd to "true"; here we
// prove the code honours whatever the cnf says.
func TestSessionCookieSecureFollowsConfig(t *testing.T) {
	for _, tc := range []struct {
		name   string
		secure string
		want   bool
	}{
		{"deployed (dev/prd)", "true", true},
		{"local http dev (lde)", "false", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg, err := LoadFrom("lde", map[string]string{
				"SPOOL_HUB_AUTH_SESSION_KEY":   strings.Repeat("k", 32),
				"SPOOL_HUB_AUTH_APP_URL":       "https://app.example.test",
				"SPOOL_HUB_AUTH_COOKIE_SECURE": tc.secure,
			})
			if err != nil {
				t.Fatal(err)
			}
			h := New(cfg, zerolog.Nop(), Options{})
			c := h.sessionCookie("tok", 3600)
			if c.Secure != tc.want {
				t.Errorf("session cookie Secure = %v, want %v for CookieSecure=%q", c.Secure, tc.want, tc.secure)
			}
			if !c.HttpOnly {
				t.Error("session cookie must always be HttpOnly")
			}
			if c.SameSite != http.SameSiteLaxMode {
				t.Errorf("session cookie SameSite = %v, want Lax", c.SameSite)
			}
		})
	}
}
