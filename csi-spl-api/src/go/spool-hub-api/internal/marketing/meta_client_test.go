package marketing

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// SPL-3875 (spec 090 T032): the Meta Graph API client against an httptest
// fake of graph.facebook.com. No network; the values below are fakes.

const (
	fakeMetaAppSec = "app-sec-fake"
	fakeUserAT     = "user-at-fake"
	fakePageAT     = "page-at-fake"
)

type metaFake struct {
	t     *testing.T
	calls atomic.Int32
	waits []time.Duration
}

// fakeMeta serves h under /v26.0 and returns a client with no real sleeps.
func fakeMeta(t *testing.T, h func(w http.ResponseWriter, r *http.Request)) (*Meta, *metaFake) {
	t.Helper()
	f := &metaFake{t: t}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.calls.Add(1)
		if !strings.HasPrefix(r.URL.Path, "/v26.0/") {
			t.Errorf("path %s has no version prefix", r.URL.Path)
		}
		if q := r.URL.RawQuery; r.URL.Query().Has("access_token") || strings.Contains(q, fakeMetaAppSec) ||
			strings.Contains(q, fakeUserAT) || strings.Contains(q, fakePageAT) {
			t.Errorf("a token or the secret is in the URL: %s", r.URL.RawQuery)
		}
		h(w, r)
	}))
	t.Cleanup(srv.Close)
	m := &Meta{
		AppID: "123", AppSecret: NewPlaintext(fakeMetaAppSec), RedirectURI: "https://app.example.com/v1/marketing/facebook/callback",
		Version: "v26.0", GraphBase: srv.URL, HTTP: srv.Client(),
		Sleep: func(_ context.Context, d time.Duration) error { f.waits = append(f.waits, d); return nil },
		Now:   func() time.Time { return time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC) },
	}
	return m, f
}

func metaJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}

func metaGraphErr(code, sub int, typ string) string {
	return fmt.Sprintf(`{"error":{"message":"m","type":%q,"code":%d,"error_subcode":%d,"fbtrace_id":"tr"}}`, typ, code, sub)
}

func wantBearer(t *testing.T, r *http.Request, tok string) {
	t.Helper()
	if r.Header.Get("Authorization") != "Bearer "+tok {
		t.Errorf("%s: Authorization %q", r.URL.Path, r.Header.Get("Authorization"))
	}
	m := &Meta{AppSecret: NewPlaintext(fakeMetaAppSec)}
	if r.URL.Query().Get("appsecret_proof") != m.appSecretProof(NewPlaintext(tok)) {
		t.Errorf("%s: appsecret_proof missing or wrong", r.URL.Path)
	}
}

func TestMetaOAuthExchange(t *testing.T) {
	var forms []url.Values
	m, f := fakeMeta(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v26.0/oauth/access_token" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		_ = r.ParseForm()
		forms = append(forms, r.PostForm)
		if r.PostForm.Get("code") != "" {
			metaJSON(w, 200, `{"access_token":"short-at","token_type":"bearer","expires_in":3600}`)
			return
		}
		metaJSON(w, 200, `{"access_token":"`+fakeUserAT+`","token_type":"bearer","expires_in":5184000}`)
	})
	tok, err := m.ExchangeLongLivedUserToken(context.Background(), "the-code")
	if err != nil {
		t.Fatal(err)
	}
	if tok.Access.Reveal() != fakeUserAT || !tok.ExpiresAt.Equal(m.Now().Add(60*24*time.Hour)) {
		t.Fatalf("token %v expires %v", tok.Access.Reveal(), tok.ExpiresAt)
	}
	if f.calls.Load() != 2 || len(forms) != 2 {
		t.Fatalf("calls %d", f.calls.Load())
	}
	c, l := forms[0], forms[1]
	if c.Get("code") != "the-code" || c.Get("client_id") != "123" || c.Get("client_secret") != fakeMetaAppSec || c.Get("redirect_uri") != m.RedirectURI {
		t.Errorf("code form %v", c)
	}
	if l.Get("grant_type") != "fb_exchange_token" || l.Get("fb_exchange_token") != "short-at" || l.Get("client_secret") != fakeMetaAppSec {
		t.Errorf("long-lived form %v", l)
	}
	if s := fmt.Sprintf("%v %+v", tok, tok); strings.Contains(s, fakeUserAT) {
		t.Errorf("token prints: %s", s)
	}
}

func TestMetaOAuthCodeNotRetriedAfterSend(t *testing.T) {
	m, f := fakeMeta(t, func(w http.ResponseWriter, _ *http.Request) {
		metaJSON(w, 500, metaGraphErr(2, 0, "OAuthException"))
	})
	_, err := m.ExchangeLongLivedUserToken(context.Background(), "the-code")
	if err == nil || MetaKind(err) != MetaErrTransient || f.calls.Load() != 1 {
		t.Fatalf("err %v kind %v calls %d: a one-time code is sent once", err, MetaKind(err), f.calls.Load())
	}
}

func TestMetaListAccountsPaging(t *testing.T) {
	m, f := fakeMeta(t, func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r, fakeUserAT)
		if r.URL.Path != "/v26.0/me/accounts" || !strings.Contains(r.URL.Query().Get("fields"), "instagram_business_account{id,username,name}") {
			t.Errorf("unexpected %s ?%s", r.URL.Path, r.URL.RawQuery)
		}
		if r.URL.Query().Get("after") == "" {
			metaJSON(w, 200, `{"data":[{"id":"p1","name":"Page One","access_token":"`+fakePageAT+`","tasks":["CREATE_CONTENT"],
				"instagram_business_account":{"id":"ig1","username":"one"}}],
				"paging":{"cursors":{"after":"c1"},"next":"https://evil.example.com/next?access_token=x"}}`)
			return
		}
		metaJSON(w, 200, `{"data":[{"id":"p2","name":"Page Two","access_token":"pat2"}],"paging":{"cursors":{"after":"c2"}}}`)
	})
	got, err := m.ListAccounts(context.Background(), NewPlaintext(fakeUserAT))
	if err != nil || len(got) != 2 || f.calls.Load() != 2 {
		t.Fatalf("accounts %+v err %v calls %d", got, err, f.calls.Load())
	}
	if got[0].ID != "p1" || got[0].AccessToken.Reveal() != fakePageAT || got[0].Instagram == nil || got[0].Instagram.ID != "ig1" || got[0].Instagram.Username != "one" {
		t.Errorf("first %+v", got[0])
	}
	if got[1].Instagram != nil || got[1].AccessToken.Reveal() != "pat2" {
		t.Errorf("second %+v", got[1])
	}
}

func TestFacebookPagePostSuccess(t *testing.T) {
	m, f := fakeMeta(t, func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r, fakePageAT)
		_ = r.ParseForm()
		switch r.URL.Path {
		case "/v26.0/p1/feed":
			if r.PostForm.Get("message") != "Release 1.2" || r.PostForm.Get("link") != "https://app.example.com/blog/x" {
				t.Errorf("feed form %v", r.PostForm)
			}
			metaJSON(w, 200, `{"id":"p1_100"}`)
		case "/v26.0/p1/photos":
			if r.PostForm.Get("url") != "https://app.example.com/a.jpg" || r.PostForm.Get("caption") != "Pic" || r.PostForm.Get("published") != "true" {
				t.Errorf("photo form %v", r.PostForm)
			}
			metaJSON(w, 200, `{"id":"photo9","post_id":"p1_200"}`)
		default:
			t.Errorf("unexpected %s", r.URL.Path)
		}
	})
	ctx, tok := context.Background(), NewPlaintext(fakePageAT)
	id, err := m.PublishFacebookPagePost(ctx, tok, "p1", FacebookPost{Message: "Release 1.2", Link: "https://app.example.com/blog/x"})
	if err != nil || id != "p1_100" {
		t.Fatalf("feed %q %v", id, err)
	}
	id, err = m.PublishFacebookPagePost(ctx, tok, "p1", FacebookPost{Message: "Pic", PhotoURL: "https://app.example.com/a.jpg"})
	if err != nil || id != "p1_200" {
		t.Fatalf("photo %q %v", id, err)
	}
	for _, bad := range []FacebookPost{{}, {PhotoURL: "http://app.example.com/a.jpg"}, {Message: strings.Repeat("x", FacebookMessageMaxChars+1)}} {
		if _, err := m.PublishFacebookPagePost(ctx, tok, "p1", bad); MetaKind(err) != MetaErrMedia {
			t.Errorf("post %.20v: err %v, want a media error", bad, err)
		}
	}
	if _, err := m.PublishFacebookPagePost(ctx, tok, "../me", FacebookPost{Message: "x"}); err == nil {
		t.Error("a path in the page id was accepted")
	}
	if f.calls.Load() != 2 {
		t.Errorf("calls %d: the refused posts reached Meta", f.calls.Load())
	}
}

func TestFacebookPagePostNeverRetriedAfterSend(t *testing.T) {
	m, f := fakeMeta(t, func(w http.ResponseWriter, _ *http.Request) {
		metaJSON(w, 503, metaGraphErr(2, 0, "OAuthException"))
	})
	_, err := m.PublishFacebookPagePost(context.Background(), NewPlaintext(fakePageAT), "p1", FacebookPost{Message: "x"})
	if f.calls.Load() != 1 || !MetaRetryable(err) {
		t.Fatalf("calls %d err %v: a Page post is sent at most once per call", f.calls.Load(), err)
	}
	m.HTTP = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, &net.OpError{Op: "read", Err: errors.New("connection reset")}
	})}
	_, err = m.PublishFacebookPagePost(context.Background(), NewPlaintext(fakePageAT), "p1", FacebookPost{Message: "x"})
	if !errors.Is(err, ErrMetaUnknownOutcome) {
		t.Fatalf("err %v, want ErrMetaUnknownOutcome", err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestMetaTransportErrorCarriesNoSecret(t *testing.T) {
	m, f := fakeMeta(t, func(http.ResponseWriter, *http.Request) {})
	tries := 0
	m.HTTP = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		tries++
		return nil, &net.OpError{Op: "dial", Err: errors.New("refused")}
	})}
	_, err := m.ListAccounts(context.Background(), NewPlaintext(fakeUserAT))
	if err == nil || tries != 3 || len(f.waits) != 2 || f.waits[0] != time.Second || f.waits[1] != 2*time.Second {
		t.Fatalf("err %v tries %d waits %v: a dial failure is retried with backoff", err, tries, f.waits)
	}
	proof := m.appSecretProof(NewPlaintext(fakeUserAT))
	if s := err.Error(); strings.Contains(s, proof) || strings.Contains(s, fakeUserAT) || strings.Contains(s, fakeMetaAppSec) {
		t.Fatalf("error carries a secret: %s", s)
	}
}
