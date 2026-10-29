package marketing

import (
	"errors"
	"net/url"
	"strings"
	"testing"
	"time"
)

// SPL-4254 (spec 090 T033): the Meta connect's dialog URL and signed state.

func TestMetaStateRoundTrip(t *testing.T) {
	m := &Meta{AppSecret: NewPlaintext(testSecret)}
	now := time.Unix(1_800_000_000, 0)
	s := m.NewState(State{Tenant: "spool", Member: "HUM-1", Exp: now.Add(time.Minute).Unix()})
	st, err := m.VerifyState(s, now)
	if err != nil || st.Tenant != "spool" || st.Member != "HUM-1" || st.Nonce == "" {
		t.Fatalf("VerifyState = %+v, %v", st, err)
	}
	for name, bad := range map[string]string{
		"empty":    "",
		"tampered": "x" + s,
		"no mac":   strings.SplitN(s, ".", 2)[0],
		// a LinkedIn state under the same secret: another label, another key
		"linkedin":  (&LinkedIn{ClientSecret: NewPlaintext(testSecret)}).NewState(State{Tenant: "spool", Member: "HUM-1", Exp: now.Add(time.Minute).Unix()}),
		"other app": (&Meta{AppSecret: NewPlaintext("another-secret")}).NewState(State{Tenant: "spool", Member: "HUM-1", Exp: now.Add(time.Minute).Unix()}),
	} {
		if _, err := m.VerifyState(bad, now); !errors.Is(err, ErrState) {
			t.Errorf("%s: %v, want ErrState", name, err)
		}
	}
	if _, err := m.VerifyState(s, now.Add(2*time.Minute)); !errors.Is(err, ErrState) {
		t.Fatalf("expired: %v, want ErrState", err)
	}
}

func TestMetaAuthorizeURL(t *testing.T) {
	m := &Meta{AppID: "app-id", RedirectURI: "https://app.example.com/api/v1/marketing/facebook/callback", Version: "v26.0"}
	au, err := m.AuthorizeURL("st")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(au)
	q := u.Query()
	if u.Scheme+"://"+u.Host != MetaDialogBase || u.Path != "/v26.0/dialog/oauth" || q.Get("client_id") != "app-id" ||
		q.Get("redirect_uri") != m.RedirectURI || q.Get("state") != "st" || q.Get("response_type") != "code" || q.Get("scope") != MetaScopes {
		t.Fatalf("AuthorizeURL = %q", au)
	}
	m.Scopes, m.DialogBase = " pages_show_list ", "https://dialog.example.com/"
	if au, _ := m.AuthorizeURL("st"); !strings.HasPrefix(au, "https://dialog.example.com/v26.0/dialog/oauth?") || !strings.Contains(au, "scope=pages_show_list&") {
		t.Fatalf("cnf scopes / dialog host: %q", au)
	}
	m.Version = "26"
	if _, err := m.AuthorizeURL("st"); err == nil {
		t.Fatal("a version that is not vNN.N built a URL")
	}
}
