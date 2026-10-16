package auth

import (
	"strings"
	"testing"
)

// SPL-2152 (security action 6): SPOOL_HUB_AUTH_COOKIE_SECURE is true, false
// or auto (the default). auto is Secure everywhere except a loopback http
// origin, so a self-hosted stack on a real host gets a Secure session cookie
// without anyone setting it; an explicit value always wins.
func TestCookieSecureResolution(t *testing.T) {
	for _, tc := range []struct {
		setting, appURL string
		want            bool
		warn            bool
	}{
		// auto (unset): only a loopback http origin is not Secure
		{"", "http://localhost:8080", false, false},
		{"", "http://LOCALHOST:3000/", false, false},
		{"", "http://main.localhost:8080", false, false},
		{"", "http://127.0.0.1:8080", false, false},
		{"", "http://127.0.0.2", false, false},
		{"", "http://[::1]:8080", false, false},
		{"", "https://localhost:8443", true, false},
		{"", "https://chat.example.test", true, false},
		{"", "http://chat.example.test", true, false},
		{"", "http://203.0.113.7:8080", true, false},
		{"", "http://localhost.example.test", true, false},
		{"", "", true, false},
		{"auto", "http://localhost:8080", false, false},
		{" AUTO ", "https://chat.example.test", true, false},
		// explicit values win; false off localhost warns
		{"true", "http://localhost:8080", true, false},
		{"false", "http://localhost:8080", false, false},
		{"false", "http://203.0.113.7:8080", false, true},
		{"false", "https://chat.example.test", false, true},
		{"FALSE", "http://chat.example.test", false, true},
		{"true", "http://chat.example.test", true, false},
	} {
		vars := map[string]string{}
		if tc.setting != "" {
			vars["SPOOL_HUB_AUTH_COOKIE_SECURE"] = tc.setting
		}
		if tc.appURL != "" {
			vars["SPOOL_HUB_AUTH_APP_URL"] = tc.appURL
		}
		c, err := LoadFrom("lde", vars)
		if err != nil {
			t.Fatalf("%q on %q: %v", tc.setting, tc.appURL, err)
		}
		if c.CookieSecure != tc.want {
			t.Errorf("COOKIE_SECURE=%q APP_URL=%q: CookieSecure = %v, want %v", tc.setting, tc.appURL, c.CookieSecure, tc.want)
		}
		if w := c.CookieSecureWarning(); (w != "") != tc.warn {
			t.Errorf("COOKIE_SECURE=%q APP_URL=%q: warning %q, want warn=%v", tc.setting, tc.appURL, w, tc.warn)
		}
	}
}

// A value that is not a boolean or auto fails fast and names the variable.
func TestCookieSecureRefusesJunk(t *testing.T) {
	_, err := LoadFrom("lde", map[string]string{"SPOOL_HUB_AUTH_COOKIE_SECURE": "maybe"})
	if err == nil || !strings.Contains(err.Error(), "SPOOL_HUB_AUTH_COOKIE_SECURE") {
		t.Fatalf("junk value: err = %v, want one naming SPOOL_HUB_AUTH_COOKIE_SECURE", err)
	}
}
