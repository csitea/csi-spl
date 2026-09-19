package auth

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// linkedinStub answers the token and userinfo calls with the bodies LinkedIn's
// "Sign In with LinkedIn using OpenID Connect" returns (spec 019 §1: the
// claims_supported of https://www.linkedin.com/oauth/.well-known/openid-configuration,
// email_verified a JSON bool, an id_token next to the access token), checking
// what the hub sends: client_secret_post and the bearer.
func linkedinStub(t *testing.T, pic []byte, userinfo func(base string) string) *OIDC {
	t.Helper()
	var srv *httptest.Server
	mux := http.NewServeMux()
	mux.HandleFunc("/oauth/v2/accessToken", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm() //nolint:errcheck
		if r.Method != http.MethodPost || r.PostForm.Get("grant_type") != "authorization_code" ||
			r.PostForm.Get("client_id") != "li-id" || r.PostForm.Get("client_secret") != "li-secret" ||
			r.PostForm.Get("code") != "the-code" || r.PostForm.Get("redirect_uri") != "https://api.example.com/api/v1/auth/linkedin/callback" {
			w.WriteHeader(http.StatusBadRequest)
			w.Write([]byte(`{"error":"invalid_request"}`)) //nolint:errcheck
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"access_token":"AQX-token","expires_in":5183999,"scope":"email,openid,profile","token_type":"Bearer","id_token":"eyJ.eyJ.sig"}`)) //nolint:errcheck
	})
	mux.HandleFunc("/v2/userinfo", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer AQX-token" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(userinfo(srv.URL))) //nolint:errcheck
	})
	mux.HandleFunc("/dms/image/pic", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Write(pic) //nolint:errcheck
	})
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	c, err := LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":              "linkedin",
		"SPOOL_HUB_AUTH_SESSION_KEY":            strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":                "https://app.example.com",
		"SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID":     "li-id",
		"SPOOL_HUB_AUTH_LINKEDIN_CLIENT_SECRET": "li-secret",
		"SPOOL_HUB_AUTH_LINKEDIN_REDIRECT_URI":  "https://api.example.com/api/v1/auth/linkedin/callback",
	})
	if err != nil {
		t.Fatal(err)
	}
	o := newIdP(c, ProviderLinkedIn, srv.Client()).(*OIDC)
	// the real endpoints, re-pointed at the stub by path only
	for _, u := range []*string{&o.AuthURL, &o.TokenURL, &o.UserinfoURL} {
		p, _ := url.Parse(*u)
		*u = srv.URL + p.Path
	}
	o.AvatarHTTPBase = srv.URL
	return o
}

func linkedinUserinfo(picBase, verified string) string {
	v := ""
	if verified != "" {
		v = `,"email_verified":` + verified
	}
	return `{"sub":"782bbtaQ","name":"Alice Example","given_name":"Alice","family_name":"Example",` +
		`"picture":"` + picBase + `/dms/image/pic","locale":{"country":"US","language":"en"},` +
		`"email":"Alice@Example.com"` + v + `}`
}

// spec 019 FR-L1/FR-L3: the real LinkedIn endpoints and scopes, a
// LinkedIn-shaped userinfo admitted only with a truthy email_verified.
func TestLinkedInUserinfoContract(t *testing.T) {
	pic := tinyPNG(t)
	c, _ := LoadFrom("prd", map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":              "linkedin",
		"SPOOL_HUB_AUTH_SESSION_KEY":            strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":                "https://app.example.com",
		"SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID":     "li-id",
		"SPOOL_HUB_AUTH_LINKEDIN_CLIENT_SECRET": "li-secret",
		"SPOOL_HUB_AUTH_LINKEDIN_REDIRECT_URI":  "https://api.example.com/api/v1/auth/linkedin/callback",
	})
	li := newIdP(c, ProviderLinkedIn, nil).(*OIDC)
	if li.AuthURL != "https://www.linkedin.com/oauth/v2/authorization" ||
		li.TokenURL != "https://www.linkedin.com/oauth/v2/accessToken" ||
		li.UserinfoURL != "https://api.linkedin.com/v2/userinfo" || li.Scopes != "openid profile email" || li.EmailTrusted {
		t.Fatalf("linkedin client %+v", li)
	}
	au, _ := url.Parse(li.AuthCodeURL("st", "nn"))
	if q := au.Query(); q.Get("client_id") != "li-id" || q.Get("state") != "st" || q.Get("nonce") != "nn" ||
		q.Get("response_type") != "code" || q.Get("scope") != "openid profile email" {
		t.Fatalf("authorize URL %s", au)
	}

	for _, verified := range []string{"true", `"true"`} {
		t.Run("verified "+verified, func(t *testing.T) {
			o := linkedinStub(t, pic, func(b string) string { return linkedinUserinfo(b, verified) })
			id, err := o.Exchange(context.Background(), "the-code")
			if err != nil {
				t.Fatal(err)
			}
			if id.Provider != "linkedin" || id.Subject != "782bbtaQ" || id.Email != "alice@example.com" ||
				id.Name != "Alice Example" || id.AvatarType != "image/png" || !bytes.Equal(id.Avatar, pic) {
				t.Fatalf("identity %+v", id)
			}
		})
	}
	for name, verified := range map[string]string{"false": "false", "string false": `"false"`, "missing": ""} {
		t.Run("refused "+name, func(t *testing.T) {
			o := linkedinStub(t, pic, func(b string) string { return linkedinUserinfo(b, verified) })
			if _, err := o.Exchange(context.Background(), "the-code"); !errors.Is(err, errEmailUnverified) {
				t.Fatalf("want errEmailUnverified, got %v", err)
			}
		})
	}
	t.Run("refused no email", func(t *testing.T) {
		o := linkedinStub(t, pic, func(string) string { return `{"sub":"782bbtaQ","name":"A","email_verified":true}` })
		if _, err := o.Exchange(context.Background(), "the-code"); !errors.Is(err, errEmailUnverified) {
			t.Fatalf("want errEmailUnverified, got %v", err)
		}
	})
	t.Run("wrong secret is an exchange error", func(t *testing.T) {
		o := linkedinStub(t, pic, func(b string) string { return linkedinUserinfo(b, "true") })
		o.ClientSecret = "other"
		if _, err := o.Exchange(context.Background(), "the-code"); !errors.Is(err, errExchange) {
			t.Fatalf("want errExchange, got %v", err)
		}
	})
}
