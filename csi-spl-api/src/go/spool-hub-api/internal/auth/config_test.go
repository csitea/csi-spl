package auth

import (
	"strings"
	"testing"
)

func validVars() map[string]string {
	return map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":              "google,facebook",
		"SPOOL_HUB_AUTH_SESSION_KEY":            strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":                "https://app.example.com",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID":       "gid",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET":   "gsecret",
		"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI":    "https://app.example.com/api/v1/auth/google/callback",
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID":     "fid",
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET": "fsecret",
		"SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI":  "https://app.example.com/api/v1/auth/facebook/callback",
	}
}

func TestConfigOffWhenNoProviders(t *testing.T) {
	c, err := LoadFrom("prd", map[string]string{})
	if err != nil {
		t.Fatalf("auth off must load: %v", err)
	}
	if len(c.Enabled()) != 0 {
		t.Fatalf("enabled = %v", c.Enabled())
	}
}

func TestConfigValidLoads(t *testing.T) {
	c, err := LoadFrom("dev", validVars())
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(c.Enabled(), ","); got != "google,facebook" {
		t.Fatalf("enabled = %s", got)
	}
	if c.GoogleScopes != "openid email profile" || c.FacebookScopes != "email,public_profile" {
		t.Fatalf("default scopes: %q %q", c.GoogleScopes, c.FacebookScopes)
	}
	if !c.CookieSecure || c.CookieName != "spool_session" {
		t.Fatalf("cookie defaults: %v %q", c.CookieSecure, c.CookieName)
	}
}

// Every required var, unset or left at its cnf placeholder, fails fast and the
// error names that var.
func TestConfigFailFast(t *testing.T) {
	required := []string{
		"SPOOL_HUB_AUTH_SESSION_KEY", "SPOOL_HUB_AUTH_APP_URL",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID", "SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET", "SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI",
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID", "SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET", "SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI",
	}
	for _, name := range required {
		for _, val := range []string{"", "PLACEHOLDER-set-after-registration"} {
			v := validVars()
			if val == "" {
				delete(v, name)
			} else {
				v[name] = val
			}
			_, err := LoadFrom("dev", v)
			if err == nil || !strings.Contains(err.Error(), name) {
				t.Errorf("%s=%q: want fail-fast naming it, got %v", name, val, err)
			}
		}
	}
}

func TestConfigRejects(t *testing.T) {
	cases := map[string]func(map[string]string) string{
		"unknown provider": func(v map[string]string) string { v["SPOOL_HUB_AUTH_PROVIDERS"] = "myspace"; return "dev" },
		"planned provider": func(v map[string]string) string { v["SPOOL_HUB_AUTH_PROVIDERS"] = "google,xai"; return "dev" },
		"short key":        func(v map[string]string) string { v["SPOOL_HUB_AUTH_SESSION_KEY"] = "short"; return "dev" },
		"http in prd": func(v map[string]string) string {
			v["SPOOL_HUB_AUTH_APP_URL"] = "http://app.example.com"
			return "prd"
		},
		"redirect path": func(v map[string]string) string {
			v["SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI"] = "https://app.example.com/callback"
			return "dev"
		},
		"redirect other provider": func(v map[string]string) string {
			v["SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI"] = "https://app.example.com/api/v1/auth/facebook/callback"
			return "dev"
		},
		"fake idp in prd": func(v map[string]string) string {
			v["SPOOL_HUB_AUTH_IDP_BASE_URL"] = "http://127.0.0.1:1"
			return "prd"
		},
		"bad duration": func(v map[string]string) string { v["SPOOL_HUB_AUTH_SESSION_TTL"] = "soon"; return "dev" },
	}
	for name, mut := range cases {
		v := validVars()
		env := mut(v)
		if _, err := LoadFrom(env, v); err == nil {
			t.Errorf("%s: want error", name)
		}
	}
}

func TestConfigLdeAllowsHTTPAndFakeIdP(t *testing.T) {
	v := validVars()
	v["SPOOL_HUB_AUTH_APP_URL"] = "http://t1.localhost:3000"
	v["SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI"] = "http://t1.localhost:58080/api/v1/auth/google/callback"
	v["SPOOL_HUB_AUTH_IDP_BASE_URL"] = "http://127.0.0.1:9999"
	if _, err := LoadFrom("lde", v); err != nil {
		t.Fatal(err)
	}
}
