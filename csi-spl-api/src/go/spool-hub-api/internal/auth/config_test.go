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
		"xai without its cnf endpoints": func(v map[string]string) string {
			v["SPOOL_HUB_AUTH_PROVIDERS"] = "google,xai"
			v["SPOOL_HUB_AUTH_XAI_CLIENT_ID"], v["SPOOL_HUB_AUTH_XAI_CLIENT_SECRET"] = "xid", "xsecret"
			v["SPOOL_HUB_AUTH_XAI_REDIRECT_URI"] = "https://app.example.com/api/v1/auth/xai/callback"
			return "dev"
		},
		"short key": func(v map[string]string) string { v["SPOOL_HUB_AUTH_SESSION_KEY"] = "short"; return "dev" },
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

func oidcVars() map[string]string {
	v := validVars()
	v["SPOOL_HUB_AUTH_PROVIDERS"] = "microsoft,linkedin,xai"
	for _, p := range []string{"MICROSOFT", "LINKEDIN", "XAI"} {
		v["SPOOL_HUB_AUTH_"+p+"_CLIENT_ID"] = strings.ToLower(p) + "-id"
		v["SPOOL_HUB_AUTH_"+p+"_CLIENT_SECRET"] = strings.ToLower(p) + "-secret"
		v["SPOOL_HUB_AUTH_"+p+"_REDIRECT_URI"] = "https://app.example.com/api/v1/auth/" + strings.ToLower(p) + "/callback"
	}
	v["SPOOL_HUB_AUTH_XAI_AUTH_URL"] = "https://idp.example.com/oauth2/authorize"
	v["SPOOL_HUB_AUTH_XAI_TOKEN_URL"] = "https://idp.example.com/oauth2/token"
	v["SPOOL_HUB_AUTH_XAI_USERINFO_URL"] = "https://idp.example.com/oauth2/userinfo"
	return v
}

// T040-T042: the OIDC providers load, default their scopes and the Microsoft
// tenant, and are no longer "planned".
func TestConfigOIDCProviders(t *testing.T) {
	if len(plannedProviders) != 0 {
		t.Fatalf("plannedProviders still lists %v", plannedProviders)
	}
	c, err := LoadFrom("prd", oidcVars())
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(c.Enabled(), ","); got != "microsoft,linkedin,xai" {
		t.Fatalf("enabled %s", got)
	}
	if c.MicrosoftTenant != "common" || c.MicrosoftTrustEmail || c.LinkedInScopes != "openid profile email" {
		t.Fatalf("defaults: %q %v %q", c.MicrosoftTenant, c.MicrosoftTrustEmail, c.LinkedInScopes)
	}
	ms := newIdP(c, ProviderMicrosoft, nil).(*Microsoft)
	if !strings.HasPrefix(ms.AuthCodeURL("s", "n"), "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?") || ms.TrustEmail {
		t.Fatalf("microsoft client %+v", ms)
	}
	if li := newIdP(c, ProviderLinkedIn, nil).(*OIDC); li.EmailTrusted {
		t.Fatal("linkedin must require email_verified")
	}
	if x := newIdP(c, ProviderXAI, nil).(*OIDC); x.TokenURL != "https://idp.example.com/oauth2/token" || x.EmailTrusted {
		t.Fatalf("xai client %+v", x)
	}
}

func TestConfigOIDCFailFast(t *testing.T) {
	var required []string
	for _, p := range []string{"MICROSOFT", "LINKEDIN", "XAI"} {
		for _, f := range []string{"CLIENT_ID", "CLIENT_SECRET", "REDIRECT_URI"} {
			required = append(required, "SPOOL_HUB_AUTH_"+p+"_"+f)
		}
	}
	required = append(required, "SPOOL_HUB_AUTH_XAI_AUTH_URL", "SPOOL_HUB_AUTH_XAI_TOKEN_URL", "SPOOL_HUB_AUTH_XAI_USERINFO_URL")
	for _, name := range required {
		for _, val := range []string{"", "PLACEHOLDER-x"} {
			v := oidcVars()
			if val == "" {
				delete(v, name)
			} else {
				v[name] = val
			}
			if _, err := LoadFrom("dev", v); err == nil || !strings.Contains(err.Error(), name) {
				t.Errorf("%s=%q: want fail-fast naming it, got %v", name, val, err)
			}
		}
	}
	v := oidcVars()
	v["SPOOL_HUB_AUTH_XAI_TOKEN_URL"] = "http://idp.example.com/oauth2/token"
	if _, err := LoadFrom("lde", v); err == nil {
		t.Error("plain-http xai endpoint accepted")
	}
}

// spec 019 FR-L2: LinkedIn scopes must carry openid and email. CONTROL: the
// cnf default and a reordered superset load (an empty value is the default).
func TestConfigLinkedInScopes(t *testing.T) {
	for _, scopes := range []string{"profile email", "openid profile", "openid,profile,email", "openidemail"} {
		v := oidcVars()
		v["SPOOL_HUB_AUTH_LINKEDIN_SCOPES"] = scopes
		if _, err := LoadFrom("dev", v); err == nil || !strings.Contains(err.Error(), "SPOOL_HUB_AUTH_LINKEDIN_SCOPES") {
			t.Errorf("scopes %q: want refusal, got %v", scopes, err)
		}
	}
	for _, scopes := range []string{"openid profile email", "email  openid"} {
		v := oidcVars()
		v["SPOOL_HUB_AUTH_LINKEDIN_SCOPES"] = scopes
		if _, err := LoadFrom("dev", v); err != nil {
			t.Errorf("scopes %q refused: %v", scopes, err)
		}
	}
}

// spec 018 OQ-M1/M2: the authority is a keyword or a tenant GUID; the
// email-trust override is refused in prd; scopes must ask for openid + email.
func TestConfigMicrosoftTenant(t *testing.T) {
	for _, tenant := range []string{"common", "consumers", "organizations", "9188040d-6c67-4c5b-b112-36a304b66dad"} {
		v := oidcVars()
		v["SPOOL_HUB_AUTH_MICROSOFT_TENANT"] = tenant
		c, err := LoadFrom("prd", v)
		if err != nil {
			t.Errorf("tenant %s: %v", tenant, err)
			continue
		}
		if u := newIdP(c, ProviderMicrosoft, nil).(*Microsoft).AuthCodeURL("s", "n"); !strings.Contains(u, "/"+tenant+"/oauth2/v2.0/authorize?") {
			t.Errorf("authority %s", u)
		}
	}
	for _, tenant := range []string{"consumers/../x", "contoso.onmicrosoft.com", "Common", "PLACEHOLDER-tenant", "0000-tenant-id"} {
		v := oidcVars()
		v["SPOOL_HUB_AUTH_MICROSOFT_TENANT"] = tenant
		if _, err := LoadFrom("dev", v); err == nil || !strings.Contains(err.Error(), "SPOOL_HUB_AUTH_MICROSOFT_TENANT") {
			t.Errorf("tenant %q accepted: %v", tenant, err)
		}
	}
	v := oidcVars()
	v["SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL"] = "true"
	if _, err := LoadFrom("dev", v); err != nil {
		t.Errorf("trust flag in dev: %v", err)
	}
	if _, err := LoadFrom("prd", v); err == nil || !strings.Contains(err.Error(), "TRUST_EMAIL") {
		t.Errorf("trust flag in prd accepted: %v", err)
	}
	for _, scopes := range []string{"openid profile", "email profile"} {
		v := oidcVars()
		v["SPOOL_HUB_AUTH_MICROSOFT_SCOPES"] = scopes
		if _, err := LoadFrom("dev", v); err == nil || !strings.Contains(err.Error(), "SCOPES") {
			t.Errorf("scopes %q accepted: %v", scopes, err)
		}
	}
}
