package marketing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// SPL-5194: the X connect and post client against a fake X.

const (
	testXAccess  = "fake-x-access-not-a-secret"
	testXRefresh = "fake-x-refresh-not-a-secret"
)

func fakeX(t *testing.T, h http.HandlerFunc) *X {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &X{ClientID: "xcid", ClientSecret: NewPlaintext(testSecret), RedirectURI: "https://app.example.com/cb",
		AuthBase: srv.URL, APIBase: srv.URL}
}

func TestXAuthorizeURLIsPKCE(t *testing.T) {
	x := &X{ClientID: "xcid", ClientSecret: NewPlaintext(testSecret), RedirectURI: "https://app.example.com/cb"}
	st := x.NewState(State{Tenant: "spool", Member: "HUM-1", Exp: time.Now().Add(time.Minute).Unix()})
	u, err := url.Parse(x.AuthorizeURL(st))
	if err != nil || u.Host != "x.com" || u.Path != "/i/oauth2/authorize" {
		t.Fatalf("authorize url: %v %v", u, err)
	}
	q := u.Query()
	if q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") != Challenge(x.Verifier(st)) ||
		q.Get("scope") != XScopes || q.Get("state") != st || q.Get("client_id") != "xcid" {
		t.Fatalf("authorize query: %v", q)
	}
	if v := x.Verifier(st); len(v) != 43 || v == x.Verifier(st+"x") {
		t.Fatalf("verifier %q: want 43 chars, one per state", v)
	}
	other := &X{ClientSecret: NewPlaintext(testSecret + "x")}
	if other.Verifier(st) == x.Verifier(st) {
		t.Fatal("the verifier does not depend on the client secret")
	}
	if _, err := x.VerifyState(st, time.Now()); err != nil {
		t.Fatalf("state: %v", err)
	}
	li := &LinkedIn{ClientSecret: NewPlaintext(testSecret)}
	if _, err := li.VerifyState(st, time.Now()); !errors.Is(err, ErrState) {
		t.Fatal("an X connect state verifies for LinkedIn")
	}
}

func TestXExchangeAndRefresh(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var x *X
	st := ""
	rotate := true
	x = fakeX(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/2/oauth2/token" || r.Method != http.MethodPost {
			http.NotFound(w, r)
			return
		}
		id, secret, ok := r.BasicAuth()
		_ = r.ParseForm()
		switch {
		case !ok || id != "xcid" || secret != testSecret:
			w.WriteHeader(http.StatusUnauthorized)
		case r.Form.Get("grant_type") == "authorization_code" && r.Form.Get("code") == "c1" &&
			r.Form.Get("code_verifier") == x.Verifier(st) && r.Form.Get("redirect_uri") == "https://app.example.com/cb":
			fmt.Fprintf(w, `{"access_token":%q,"refresh_token":%q,"expires_in":7200}`, testXAccess, testXRefresh)
		case r.Form.Get("grant_type") == "refresh_token" && r.Form.Get("refresh_token") == testXRefresh && rotate:
			_, _ = io.WriteString(w, `{"access_token":"a2","refresh_token":"r2","expires_in":7200}`)
		case r.Form.Get("grant_type") == "refresh_token" && r.Form.Get("refresh_token") == testXRefresh:
			_, _ = io.WriteString(w, `{"access_token":"a3","expires_in":7200}`)
		default:
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"error":"invalid_request","error_description":"Value passed for the token was invalid."}`)
		}
	})
	st = x.NewState(State{Tenant: "spool", Member: "HUM-1", Exp: now.Add(time.Minute).Unix()})
	tok, err := x.Exchange(context.Background(), "c1", st, now)
	if err != nil || tok.Access.Reveal() != testXAccess || tok.Refresh.Reveal() != testXRefresh || !tok.ExpiresAt.Equal(now.Add(2*time.Hour)) {
		t.Fatalf("exchange: %+v %v", tok, err)
	}
	if _, err := x.Exchange(context.Background(), "c1", st+"x", now); !XTokenRefused(err) || strings.Contains(err.Error(), testXAccess) {
		t.Fatalf("a wrong verifier: %v, want a refused token", err)
	}
	if got, err := x.Refresh(context.Background(), tok.Refresh, now); err != nil || got.Access.Reveal() != "a2" || got.Refresh.Reveal() != "r2" {
		t.Fatalf("refresh (rotating): %+v %v", got, err)
	}
	rotate = false
	if got, err := x.Refresh(context.Background(), tok.Refresh, now); err != nil || got.Access.Reveal() != "a3" || got.Refresh.Reveal() != testXRefresh {
		t.Fatalf("refresh (no new refresh token keeps the old one): %+v %v", got, err)
	}
	if _, err := x.Refresh(context.Background(), NewPlaintext("revoked"), now); !XTokenRefused(err) {
		t.Fatalf("a revoked refresh token: %v, want refused", err)
	}
}

func TestXMeAndBundle(t *testing.T) {
	x := fakeX(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/2/users/me" || r.Header.Get("Authorization") != "Bearer "+testXAccess {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = io.WriteString(w, `{"data":{"id":"42","name":"Csitea","username":"csitea"}}`)
	})
	u, err := x.Me(context.Background(), NewPlaintext(testXAccess))
	if err != nil || u.ID != "42" || u.Username != "csitea" || u.Name != "Csitea" {
		t.Fatalf("me: %+v %v", u, err)
	}
	if _, err := x.Me(context.Background(), NewPlaintext("bad")); !XTokenRefused(err) {
		t.Fatalf("me with a bad token: %v", err)
	}
	tok := XToken{Access: NewPlaintext(testXAccess), Refresh: NewPlaintext(testXRefresh), ExpiresAt: time.Unix(1_800_007_200, 0)}
	back, err := ParseXToken(tok.Bundle())
	if err != nil || back.Access.Reveal() != testXAccess || back.Refresh.Reveal() != testXRefresh || !back.ExpiresAt.Equal(tok.ExpiresAt) {
		t.Fatalf("bundle round trip: %+v %v", back, err)
	}
	if s := fmt.Sprint(tok.Bundle()); strings.Contains(s, testXAccess) {
		t.Fatal("a printed bundle shows the token")
	}
	if _, err := ParseXToken(NewPlaintext("li-token")); err == nil {
		t.Fatal("a plain token parsed as a pair")
	}
}

func TestXPost(t *testing.T) {
	var got string
	status := http.StatusCreated
	x := fakeX(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/2/tweets" || r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer "+testXAccess {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"title":"Unauthorized","detail":"Unauthorized","status":401}`)
			return
		}
		var b struct {
			Text string `json:"text"`
		}
		_ = json.NewDecoder(r.Body).Decode(&b)
		got = b.Text
		switch status {
		case http.StatusCreated:
			w.WriteHeader(status)
			_, _ = io.WriteString(w, `{"data":{"id":"1850000000000000000","text":"x"}}`)
		case http.StatusTooManyRequests:
			w.Header().Set("x-rate-limit-reset", fmt.Sprint(time.Now().Add(10*time.Minute).Unix()))
			w.WriteHeader(status)
			_, _ = io.WriteString(w, `{"errors":[{"code":88,"message":"Rate limit exceeded"}]}`)
		default:
			w.WriteHeader(status)
			_, _ = io.WriteString(w, `{"title":"Forbidden","detail":"You are not permitted to perform this action.","status":403}`)
		}
	})
	ctx, tok := context.Background(), NewPlaintext(testXAccess)
	id, err := x.Post(ctx, tok, "Hello")
	if err != nil || id != "1850000000000000000" || got != "Hello" {
		t.Fatalf("post: %q %v (sent %q)", id, err, got)
	}
	status = http.StatusTooManyRequests
	_, err = x.Post(ctx, tok, "Hello")
	var xe *XError
	if !XRetryable(err) || !errors.As(err, &xe) || xe.RetryAfter <= 0 || xe.Message != "Rate limit exceeded" {
		t.Fatalf("429: %v, want retryable with a reset", err)
	}
	status = http.StatusForbidden
	if _, err = x.Post(ctx, tok, "Hello"); XRetryable(err) || XTokenRefused(err) || !strings.Contains(err.Error(), "not permitted") {
		t.Fatalf("403: %v, want a final failure with X's words", err)
	}
	if _, err = x.Post(ctx, NewPlaintext("bad"), "Hello"); !XTokenRefused(err) {
		t.Fatalf("401: %v, want refused", err)
	}
	got = ""
	if _, err = x.Post(ctx, tok, strings.Repeat("a", XPostMaxWeight+1)); !errors.Is(err, ErrXTooLong) || got != "" {
		t.Fatalf("too long: %v (sent %q), want refused before X", err, got)
	}
}

func TestXPostUnknownOutcome(t *testing.T) {
	x := fakeX(t, func(w http.ResponseWriter, r *http.Request) {
		hj, _ := w.(http.Hijacker)
		c, _, _ := hj.Hijack()
		_ = c.Close() // the request arrived, no answer goes back
	})
	_, err := x.Post(context.Background(), NewPlaintext(testXAccess), "Hello")
	if !errors.Is(err, ErrXUnknownOutcome) || XRetryable(err) {
		t.Fatalf("dropped answer: %v, want unknown outcome, never retried", err)
	}
	dead := &X{APIBase: "http://127.0.0.1:1"}
	if _, err := dead.Post(context.Background(), NewPlaintext(testXAccess), "Hello"); !XRetryable(err) {
		t.Fatalf("dial failure: %v, want retryable", err)
	}
}

func TestXWeightedLength(t *testing.T) {
	for text, want := range map[string]int{
		"hello": 5,
		"https://example.com/blog/a-very-long-post-address-that-is-long": XURLWeight,
		"see https://example.com/x ok":                                   4 + XURLWeight + 3,
		"日本":                                                             4,
		"\U0001F4A1":                                                     2,
		"é—’":                                                            3,
	} {
		if got := XWeightedLength(text); got != want {
			t.Errorf("XWeightedLength(%q) = %d, want %d", text, got, want)
		}
	}
}

func TestXPostText(t *testing.T) {
	app := "https://app.example.com"
	short := XPostText(app, BlogPost{ID: "2026-11-10-x", Title: "Title", Summary: "Summary"})
	if short != "Title\n\nSummary\n\n"+app+"/blog/2026-11-10-x" {
		t.Fatalf("short post: %q", short)
	}
	for name, p := range map[string]BlogPost{
		"long summary": {ID: "2026-11-10-x", Title: "Title", Summary: strings.Repeat("word ", 200)},
		"long cjk":     {ID: "2026-11-10-x", Title: "標題", Summary: strings.Repeat("日本語", 100)},
		"long title":   {ID: "2026-11-10-x", Title: strings.Repeat("t", 400), Summary: "s"},
	} {
		text := XPostText(app, p)
		if n := XWeightedLength(text); n > XPostMaxWeight {
			t.Errorf("%s: %d weighted, over %d: %q", name, n, XPostMaxWeight, text)
		}
		if !strings.HasSuffix(text, "\n\n"+BlogPostURL(app, p.ID)) {
			t.Errorf("%s: the link is cut: %q", name, text)
		}
		if !strings.Contains(text, "…") {
			t.Errorf("%s: shortened with no ellipsis: %q", name, text)
		}
	}
}
