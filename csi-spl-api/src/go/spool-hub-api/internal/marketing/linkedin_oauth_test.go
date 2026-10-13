package marketing

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// SPL-1634: the LinkedIn connect client against a fake LinkedIn.

const testOAuthToken = "fake-linkedin-access-not-a-secret"

func fakeLinkedIn(t *testing.T, h http.HandlerFunc) *LinkedIn {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &LinkedIn{ClientID: "cid", ClientSecret: NewPlaintext(testSecret), RedirectURI: "https://app.example.com/cb",
		Version: "202606", AuthBase: srv.URL, APIBase: srv.URL}
}

func TestLinkedInStateRoundTrip(t *testing.T) {
	l := &LinkedIn{ClientSecret: NewPlaintext(testSecret)}
	now := time.Unix(1_800_000_000, 0)
	s := l.NewState(State{Tenant: "spool", Member: "HUM-1", Exp: now.Add(time.Minute).Unix()})
	st, err := l.VerifyState(s, now)
	if err != nil || st.Tenant != "spool" || st.Member != "HUM-1" || st.Nonce == "" {
		t.Fatalf("round trip: %+v %v", st, err)
	}
	if s2 := l.NewState(State{Tenant: "spool", Member: "HUM-1", Exp: st.Exp}); s2 == s {
		t.Fatal("two states share a nonce")
	}
	other := &LinkedIn{ClientSecret: NewPlaintext(testSecret + "x")}
	p, _, _ := strings.Cut(s, ".")
	for name, bad := range map[string]string{
		"expired":    "",
		"no dot":     p,
		"bad mac":    p + ".AAAA",
		"bad base64": p + ".***",
		"other key":  "",
	} {
		var err error
		switch name {
		case "expired":
			_, err = l.VerifyState(s, now.Add(2*time.Minute))
		case "other key":
			_, err = other.VerifyState(s, now)
		default:
			_, err = l.VerifyState(bad, now)
		}
		if !errors.Is(err, ErrState) {
			t.Errorf("%s: %v, want ErrState", name, err)
		}
	}
}

func TestLinkedInAuthorizeURL(t *testing.T) {
	l := &LinkedIn{ClientID: "cid", RedirectURI: "https://app.example.com/cb"}
	u, err := url.Parse(l.AuthorizeURL("st"))
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	if u.Host != "www.linkedin.com" || u.Path != "/oauth/v2/authorization" || q.Get("client_id") != "cid" ||
		q.Get("state") != "st" || q.Get("scope") != LinkedInScopes || q.Get("redirect_uri") != "https://app.example.com/cb" ||
		q.Get("response_type") != "code" {
		t.Fatalf("authorize url %s", u)
	}
}

func TestLinkedInExchangeAndUserinfo(t *testing.T) {
	l := fakeLinkedIn(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/oauth/v2/accessToken":
			_ = r.ParseForm()
			if r.Form.Get("code") != "good" || r.Form.Get("client_secret") != testSecret || r.Form.Get("grant_type") != "authorization_code" {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = io.WriteString(w, `{"error":"invalid_request","error_description":"bad code"}`)
				return
			}
			_, _ = io.WriteString(w, `{"access_token":"`+testOAuthToken+`","expires_in":5184000}`)
		case "/v2/userinfo":
			if r.Header.Get("Authorization") != "Bearer "+testOAuthToken {
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = io.WriteString(w, `{"message":"Invalid access token"}`)
				return
			}
			_, _ = io.WriteString(w, `{"sub":"abc123","name":"FirstName LastName"}`)
		}
	})
	ctx := context.Background()
	now := time.Unix(1_800_000_000, 0)
	tok, err := l.Exchange(ctx, "good", now)
	if err != nil || tok.Access.Reveal() != testOAuthToken || !tok.ExpiresAt.Equal(now.Add(60*24*time.Hour)) {
		t.Fatalf("exchange: %v %v", tok.ExpiresAt, err)
	}
	var he *HTTPError
	if _, err := l.Exchange(ctx, "bad", now); !errors.As(err, &he) || he.Status != 400 || he.Message != "bad code" {
		t.Fatalf("bad code: %v", err)
	}
	m, err := l.Userinfo(ctx, tok.Access)
	if err != nil || m.Sub != "abc123" {
		t.Fatalf("userinfo: %+v %v", m, err)
	}
	_, err = l.Userinfo(ctx, NewPlaintext("wrong"))
	if !errors.As(err, &he) || he.Status != 401 || he.Message != "Invalid access token" {
		t.Fatalf("wrong token: %v", err)
	}
	if strings.Contains(err.Error(), testOAuthToken) {
		t.Fatal("a token reached an error")
	}
}

func TestLinkedInEmptyAnswersAreErrors(t *testing.T) {
	l := fakeLinkedIn(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/oauth/v2/accessToken" {
			_, _ = io.WriteString(w, `{}`)
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, `{"error":"`+strings.Repeat("x", 300)+`"}`)
	})
	if _, err := l.Exchange(context.Background(), "c", time.Now()); err == nil {
		t.Fatal("an answer with no token was accepted")
	}
	var he *HTTPError
	_, err := l.Userinfo(context.Background(), NewPlaintext("t"))
	if !errors.As(err, &he) || len(he.Message) != 200 {
		t.Fatalf("long message not cut to 200: %v", err)
	}
}
