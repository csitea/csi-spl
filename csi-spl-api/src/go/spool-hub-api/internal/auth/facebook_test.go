package auth

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// graphStub answers the token and /me calls the way Graph v25.0 does for a
// Facebook Login web app (spec 049 §1): the token is a GET carrying the client
// secret, /me needs the access token AND its appsecret_proof, errors are
// Graph's {"error":{"type":"OAuthException",...}} with a 400. me renders the
// /me body; it gets the stub's origin for the picture URL.
func graphStub(t *testing.T, pic []byte, me func(base string) string) *Facebook {
	t.Helper()
	var srv *httptest.Server
	graphErr := func(w http.ResponseWriter, code, msg string) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":{"message":"` + msg + `","type":"OAuthException","code":` + code + `,"fbtrace_id":"AbCdEf"}}`)) //nolint:errcheck
	}
	mux := http.NewServeMux()
	mux.HandleFunc(FacebookTokenPath, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if r.Method != http.MethodGet || q.Get("client_id") != "fb-id" || q.Get("client_secret") != "fb-secret" ||
			q.Get("code") != "the-code" || q.Get("redirect_uri") != "https://app.example.com/api/v1/auth/facebook/callback" {
			graphErr(w, "100", "Error validating verification code.")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"access_token":"EAAB-token","token_type":"bearer","expires_in":5183944}`)) //nolint:errcheck
	})
	mux.HandleFunc(FacebookMePath, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		m := hmac.New(sha256.New, []byte("fb-secret"))
		m.Write([]byte("EAAB-token"))
		if q.Get("access_token") != "EAAB-token" || q.Get("appsecret_proof") != hex.EncodeToString(m.Sum(nil)) {
			graphErr(w, "190", "Invalid appsecret_proof provided in the API argument")
			return
		}
		if q.Get("fields") != "id,email,name,picture.width(256).height(256)" {
			graphErr(w, "100", "unexpected fields")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(me(srv.URL))) //nolint:errcheck
	})
	mux.HandleFunc("/platform/profilepic/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Write(pic) //nolint:errcheck
	})
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &Facebook{ClientID: "fb-id", ClientSecret: "fb-secret", Scopes: "email,public_profile",
		RedirectURI: "https://app.example.com/api/v1/auth/facebook/callback", HTTP: srv.Client(),
		DialogBase: srv.URL, GraphBase: srv.URL, AvatarHTTPBase: srv.URL}
}

// graphMe is a /me body: email "" = Graph omitted the field (declined, none,
// or never confirmed).
func graphMe(picBase, email string, silhouette bool) string {
	e := ""
	if email != "" {
		e = `"email":"` + email + `",`
	}
	sil := "false"
	if silhouette {
		sil = "true"
	}
	return `{"id":"10229876543210987",` + e + `"name":"Alice Example","picture":{"data":{"height":256,` +
		`"is_silhouette":` + sil + `,"url":"` + picBase + `/platform/profilepic/?asid=10229876543210987","width":256}}}`
}

// spec 049 FR-F1: the real dialog, Graph version and scopes.
func TestFacebookClientContract(t *testing.T) {
	c, err := LoadFrom("prd", map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":              "facebook",
		"SPOOL_HUB_AUTH_SESSION_KEY":            strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":                "https://app.example.com",
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID":     "fb-id",
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET": "fb-secret",
		"SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI":  "https://app.example.com/api/v1/auth/facebook/callback",
	})
	if err != nil {
		t.Fatal(err)
	}
	fb := newIdP(c, ProviderFacebook, nil).(*Facebook)
	if fb.DialogBase != "https://www.facebook.com" || fb.GraphBase != "https://graph.facebook.com" || fb.Scopes != "email,public_profile" {
		t.Fatalf("facebook client %+v", fb)
	}
	au, _ := url.Parse(fb.AuthCodeURL("st", "nn"))
	q := au.Query()
	if au.Host != "www.facebook.com" || au.Path != "/v25.0/dialog/oauth" || q.Get("client_id") != "fb-id" ||
		q.Get("redirect_uri") != "https://app.example.com/api/v1/auth/facebook/callback" || q.Get("state") != "st" ||
		q.Get("response_type") != "code" || q.Get("scope") != "email,public_profile" || q.Get("auth_type") != "rerequest" {
		t.Fatalf("dialog URL %s", au)
	}
	// Facebook Login has no id_token: the nonce lives only in the signed state
	if q.Has("nonce") || strings.Contains(au.RawQuery, "fb-secret") {
		t.Fatalf("dialog URL leaks the nonce or the secret: %s", au)
	}
}

// spec 049 FR-F2/FR-F4: Graph-shaped exchange. Every refusal runs on the same
// stub as the "success" control, so a refusal cannot pass on a broken stub.
func TestFacebookGraphExchange(t *testing.T) {
	pic := tinyPNG(t)
	ctx := context.Background()

	t.Run("success (control)", func(t *testing.T) {
		fb := graphStub(t, pic, func(b string) string { return graphMe(b, "Alice@Example.COM", false) })
		id, err := fb.Exchange(ctx, "the-code")
		if err != nil {
			t.Fatal(err)
		}
		if id.Provider != ProviderFacebook || id.Subject != "10229876543210987" || id.Email != "alice@example.com" ||
			id.Name != "Alice Example" || id.AvatarType != "image/png" || !bytes.Equal(id.Avatar, pic) {
			t.Fatalf("identity %+v", id)
		}
	})
	t.Run("no email: refused, nothing to link on", func(t *testing.T) {
		fb := graphStub(t, pic, func(b string) string { return graphMe(b, "", false) })
		id, err := fb.Exchange(ctx, "the-code")
		if !errors.Is(err, errEmailUnverified) || id.Subject != "" {
			t.Fatalf("want errEmailUnverified and no identity, got %+v %v", id, err)
		}
	})
	t.Run("blank email is no email", func(t *testing.T) {
		fb := graphStub(t, pic, func(b string) string { return graphMe(b, "  ", false) })
		if _, err := fb.Exchange(ctx, "the-code"); !errors.Is(err, errEmailUnverified) {
			t.Fatalf("want errEmailUnverified, got %v", err)
		}
	})
	t.Run("silhouette is not stored as a picture", func(t *testing.T) {
		fb := graphStub(t, pic, func(b string) string { return graphMe(b, "alice@example.com", true) })
		id, err := fb.Exchange(ctx, "the-code")
		if err != nil || id.Avatar != nil || id.Email != "alice@example.com" {
			t.Fatalf("identity %+v %v", id, err)
		}
	})
	t.Run("wrong app secret: token refused", func(t *testing.T) {
		fb := graphStub(t, pic, func(b string) string { return graphMe(b, "alice@example.com", false) })
		fb.ClientSecret = "other"
		if _, err := fb.Exchange(ctx, "the-code"); !errors.Is(err, errExchange) {
			t.Fatalf("want errExchange, got %v", err)
		}
	})
	t.Run("used or unknown code: Graph OAuthException", func(t *testing.T) {
		fb := graphStub(t, pic, func(b string) string { return graphMe(b, "alice@example.com", false) })
		if _, err := fb.Exchange(ctx, "stale-code"); !errors.Is(err, errExchange) {
			t.Fatalf("want errExchange, got %v", err)
		}
	})
	t.Run("me without an id is an exchange error", func(t *testing.T) {
		fb := graphStub(t, pic, func(string) string { return `{"email":"alice@example.com","name":"A"}` })
		if _, err := fb.Exchange(ctx, "the-code"); !errors.Is(err, errExchange) {
			t.Fatalf("want errExchange, got %v", err)
		}
	})
}
