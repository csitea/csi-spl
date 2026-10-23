package gcal_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal/fakegcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
)

// Spec 149 row B4 (SPL-3125): the OAuth side of the Google client, against
// fakegcal only.

const (
	testRedirect = "https://app.example.com/v1/me/google-calendar/callback"
	testScopes   = "openid email https://calendar.scope.example/events"
)

func newClient(t *testing.T) (*gcal.Google, *fakegcal.Fake) {
	t.Helper()
	f := fakegcal.New(t)
	g, err := gcal.New(f.Config(testRedirect, testScopes))
	if err != nil {
		t.Fatal(err)
	}
	return g, f
}

// connect runs the code exchange as the callback would and answers the tokens.
func connect(t *testing.T, g *gcal.Google, f *fakegcal.Fake, email string, now time.Time) gcal.Token {
	t.Helper()
	tok, err := g.Exchange(context.Background(), f.IssueCode(email), now)
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func TestConfigValidate(t *testing.T) {
	f := fakegcal.New(t)
	full := f.Config(testRedirect, testScopes)
	if _, err := gcal.New(full); err != nil {
		t.Fatalf("full config: %v", err)
	}
	for name, hole := range map[string]func(*gcal.Config){
		"client id":     func(c *gcal.Config) { c.ClientID = "" },
		"client secret": func(c *gcal.Config) { c.ClientSecret = marketing.NewPlaintext("") },
		"redirect":      func(c *gcal.Config) { c.RedirectURI = "" },
		"scopes":        func(c *gcal.Config) { c.Scopes = " " },
		"auth url":      func(c *gcal.Config) { c.AuthURL = "" },
		"token url":     func(c *gcal.Config) { c.TokenURL = "" },
		"revoke url":    func(c *gcal.Config) { c.RevokeURL = "" },
		"userinfo url":  func(c *gcal.Config) { c.UserinfoURL = "" },
		"calendar base": func(c *gcal.Config) { c.CalendarBase = "" },
	} {
		c := full
		hole(&c)
		if _, err := gcal.New(c); !errors.Is(err, gcal.ErrNotConfigured) {
			t.Errorf("%s empty: %v, want ErrNotConfigured", name, err)
		}
	}
	if _, err := gcal.New(gcal.Config{}); !errors.Is(err, gcal.ErrNotConfigured) {
		t.Errorf("zero config: %v", err)
	}
}

func TestStateRoundTrip(t *testing.T) {
	g, f := newClient(t)
	now := time.Unix(1_800_000_000, 0)
	s, nonce := g.NewState(gcal.State{Tenant: "spool", Member: "HUM-1", Exp: now.Add(15 * time.Minute).Unix()})
	st, err := g.VerifyState(s, now)
	if err != nil || st.Tenant != "spool" || st.Member != "HUM-1" || st.Nonce != nonce || nonce == "" {
		t.Fatalf("round trip: %+v %q %v", st, nonce, err)
	}
	if s2, n2 := g.NewState(gcal.State{Tenant: "spool", Member: "HUM-1", Exp: st.Exp}); s2 == s || n2 == nonce {
		t.Fatal("two states share a nonce")
	}
	other := f.Config(testRedirect, testScopes)
	other.ClientSecret = marketing.NewPlaintext("another-test-value")
	g2, err := gcal.New(other)
	if err != nil {
		t.Fatal(err)
	}
	p, _, _ := strings.Cut(s, ".")
	cases := map[string]func() error{
		"expired":    func() error { _, err := g.VerifyState(s, now.Add(16*time.Minute)); return err },
		"other key":  func() error { _, err := g2.VerifyState(s, now); return err },
		"no dot":     func() error { _, err := g.VerifyState(p, now); return err },
		"bad mac":    func() error { _, err := g.VerifyState(p+".AAAA", now); return err },
		"bad base64": func() error { _, err := g.VerifyState(p+".***", now); return err },
		"empty":      func() error { _, err := g.VerifyState("", now); return err },
	}
	for name, run := range cases {
		if err := run(); !errors.Is(err, gcal.ErrState) {
			t.Errorf("%s: %v, want ErrState", name, err)
		}
	}
	// The label keeps a 090 LinkedIn state, signed with the same secret, out.
	li := &marketing.LinkedIn{ClientSecret: marketing.NewPlaintext(fakegcal.ClientKey)}
	ls := li.NewState(marketing.State{Tenant: "spool", Member: "HUM-1", Exp: st.Exp})
	if _, err := g.VerifyState(ls, now); !errors.Is(err, gcal.ErrState) {
		t.Errorf("a marketing state verified as a gcal state: %v", err)
	}
}

func TestAuthorizeURL(t *testing.T) {
	g, f := newClient(t)
	u, err := url.Parse(g.AuthorizeURL("st"))
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	want := map[string]string{
		"response_type": "code", "client_id": fakegcal.ClientID, "redirect_uri": testRedirect, "scope": testScopes,
		"access_type": "offline", "include_granted_scopes": "true", "prompt": "consent", "state": "st",
	}
	for k, v := range want {
		if q.Get(k) != v {
			t.Errorf("%s = %q, want %q", k, q.Get(k), v)
		}
	}
	if !strings.HasPrefix(u.String(), f.URL()+"/") {
		t.Errorf("authorize url %s is not the configured one", u)
	}
	// The fake consent page signs in and redirects back with a code and the state.
	cl := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := cl.Get(u.String())
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	back, _ := url.Parse(resp.Header.Get("Location"))
	if resp.StatusCode != http.StatusFound || back.Query().Get("state") != "st" || back.Query().Get("code") == "" ||
		!strings.HasPrefix(back.String(), testRedirect+"?") {
		t.Fatalf("consent redirect %d %s", resp.StatusCode, back)
	}
	if _, err := g.Exchange(context.Background(), back.Query().Get("code"), time.Now()); err != nil {
		t.Fatalf("exchange of the consent code: %v", err)
	}
	// A redirect URI not registered on the client is refused, as at Google.
	q.Set("redirect_uri", "https://elsewhere.example.net/cb")
	resp, err = cl.Get(f.URL() + "/o/oauth2/v2/auth?" + q.Encode())
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest || resp.Header.Get("Location") != "" {
		t.Fatalf("unregistered redirect: %d %q", resp.StatusCode, resp.Header.Get("Location"))
	}
}

func TestUserinfo(t *testing.T) {
	g, f := newClient(t)
	tok := connect(t, g, f, "m1@example.com", time.Now())
	email, err := g.Userinfo(context.Background(), tok.Access)
	if err != nil || email != "m1@example.com" {
		t.Fatalf("userinfo %q %v", email, err)
	}
	if _, err := g.Userinfo(context.Background(), marketing.NewPlaintext("nope")); !errors.Is(err, gcal.ErrUnauthorized) {
		t.Fatalf("unknown access: %v", err)
	}
}

func TestExchangeRefusals(t *testing.T) {
	g, f := newClient(t)
	ctx := context.Background()
	code := f.IssueCode("m1@example.com")
	if _, err := g.Exchange(ctx, code, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := g.Exchange(ctx, code, time.Now()); !errors.Is(err, gcal.ErrInvalidGrant) {
		t.Errorf("a used code: %v, want ErrInvalidGrant", err)
	}
	bad := f.Config(testRedirect, testScopes)
	bad.ClientSecret = marketing.NewPlaintext("wrong-test-value")
	gb, _ := gcal.New(bad)
	_, err := gb.Exchange(ctx, f.IssueCode("m1@example.com"), time.Now())
	var he *gcal.HTTPError
	if !errors.As(err, &he) || he.Status != http.StatusUnauthorized || he.Reason != "invalid_client" {
		t.Errorf("wrong client secret: %v", err)
	}
}

// No token reaches an error string or a formatted Token.
func TestTokensNeverPrint(t *testing.T) {
	g, f := newClient(t)
	tok := connect(t, g, f, "m1@example.com", time.Now())
	out := fmt.Sprintf("%v %+v %#v %s", tok, tok, tok, tok.Access)
	for _, s := range []string{tok.Access.Reveal(), tok.Refresh.Reveal()} {
		if strings.Contains(out, s) {
			t.Fatalf("a token printed: %s", out)
		}
	}
	f.RevokeGrant("m1@example.com")
	_, err := g.Refresh(context.Background(), tok.Refresh, time.Now())
	if err == nil || strings.Contains(err.Error(), tok.Refresh.Reveal()) {
		t.Fatalf("refresh error carries the token: %v", err)
	}
}
