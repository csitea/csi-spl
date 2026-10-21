package cicdlogs

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// randTok is a fresh random value per run, never a literal that looks like a
// credential.
func randTok(t *testing.T) string {
	t.Helper()
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return "t" + hex.EncodeToString(b)
}

func TestScrub(t *testing.T) {
	tok := randTok(t)
	cases := []struct {
		name, in, token, want string
	}{
		{"empty token keeps text", "dial " + tok, "", "dial " + tok},
		{"token absent", "connection refused", tok, "connection refused"},
		{"token once", "GET /" + tok + "/logs", tok, "GET /[redacted]/logs"},
		{"token several times", tok + " and " + tok + tok, tok, "[redacted] and [redacted][redacted]"},
		{"empty text", "", tok, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := scrub(c.in, c.token)
			if got != c.want {
				t.Fatalf("scrub(%q) = %q, want %q", c.in, got, c.want)
			}
			if c.token != "" && strings.Contains(got, c.token) {
				t.Fatalf("token left in %q", got)
			}
		})
	}
}

type rtFunc func(*http.Request) (*http.Response, error)

func (f rtFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type failBody struct{ err error }

func (b failBody) Read([]byte) (int, error) { return 0, b.err }
func (failBody) Close() error               { return nil }

func assertRedacted(t *testing.T, err error, tok string) {
	t.Helper()
	if err == nil {
		t.Fatal("want an error")
	}
	if strings.Contains(err.Error(), tok) {
		t.Fatalf("token in error: %v", err)
	}
	if !strings.Contains(err.Error(), "[redacted]") {
		t.Fatalf("no [redacted] in error: %v", err)
	}
}

func TestFetchLogsErrorsNeverCarryToken(t *testing.T) {
	tok := randTok(t)
	ctx := context.Background()

	t.Run("missing token", func(t *testing.T) {
		_, err := (HTTPFetcher{}).FetchLogs(ctx, "", "http://127.0.0.1", "acme", "app", "1", "")
		if err == nil || !strings.Contains(err.Error(), "missing token") {
			t.Fatalf("%v", err)
		}
	})

	t.Run("bad request url", func(t *testing.T) {
		_, err := (HTTPFetcher{}).FetchLogs(ctx, tok, "http://h\x7f/"+tok, "acme", "app", "1", "")
		assertRedacted(t, err, tok)
	})

	t.Run("request fails, default client", func(t *testing.T) {
		ts := httptest.NewServer(http.NotFoundHandler())
		base := ts.URL + "/" + tok
		ts.Close()
		_, err := (HTTPFetcher{}).FetchLogs(ctx, tok, base, "acme", "app", "1", "")
		assertRedacted(t, err, tok)
	})

	t.Run("body read fails", func(t *testing.T) {
		c := &http.Client{Transport: rtFunc(func(r *http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: failBody{errors.New("reset by " + tok)}, Request: r}, nil
		})}
		_, err := (HTTPFetcher{Client: c}).FetchLogs(ctx, tok, "http://logs.example.test", "acme", "app", "1", "")
		assertRedacted(t, err, tok)
	})

	t.Run("http status, job path", func(t *testing.T) {
		var path string
		c := &http.Client{Transport: rtFunc(func(r *http.Request) (*http.Response, error) {
			path = r.URL.Path
			return &http.Response{StatusCode: 403, Body: io.NopCloser(strings.NewReader(tok)), Request: r}, nil
		})}
		_, err := (HTTPFetcher{Client: c}).FetchLogs(ctx, tok, "http://logs.example.test/", "acme", "app", "1", "77")
		if err == nil || err.Error() != "github logs: HTTP 403" {
			t.Fatalf("%v", err)
		}
		if path != "/repos/acme/app/actions/jobs/77/logs" {
			t.Fatalf("path %q", path)
		}
	})
}

func TestClientDefault(t *testing.T) {
	c := (HTTPFetcher{}).client()
	if c.Timeout != logFetchTimeout || c.CheckRedirect == nil {
		t.Fatalf("default client %+v", c)
	}
	own := &http.Client{}
	if (HTTPFetcher{Client: own}).client() != own {
		t.Fatal("configured client not used")
	}
}

func TestStripAuthRedirectLimit(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "http://logs.example.test", nil)
	req.Header.Set("Authorization", "Bearer x")
	if err := stripAuthRedirect(req, make([]*http.Request, 10)); err == nil {
		t.Fatal("want too many redirects")
	}
	if req.Header.Get("Authorization") != "" {
		t.Fatal("Authorization kept")
	}
}

func TestHasRealToken(t *testing.T) {
	tok := randTok(t)
	cases := []struct {
		name string
		s    Settings
		want bool
	}{
		{"none", Settings{}, false},
		{"default real", Settings{DefaultToken: tok}, true},
		{"placeholders only", Settings{DefaultToken: "CHANGE_ME", TenantTokens: map[string]string{"t1": "<token>"}}, false},
		{"tenant real", Settings{DefaultToken: "", TenantTokens: map[string]string{"t1": "TODO", "t2": tok}}, true},
	}
	for _, c := range cases {
		if got := c.s.hasRealToken(); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestRunIDOK(t *testing.T) {
	for in, want := range map[string]bool{"123": true, "0": true, "": false, "12a": false, "-1": false, "１": false} {
		if got := runIDOK(in); got != want {
			t.Errorf("runIDOK(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestWriteVersionAndNowFallbacks(t *testing.T) {
	var nilSvc *Service
	if nilSvc.writeVersion() != msg.Version || (&Service{}).writeVersion() != msg.Version {
		t.Fatal("writeVersion fallback is not msg.Version")
	}
	if (&Service{MsgVersion: 7}).writeVersion() != 7 {
		t.Fatal("MsgVersion not used")
	}
	before := time.Now()
	if got := nilSvc.now(); got.Before(before) {
		t.Fatalf("nil now %v before %v", got, before)
	}
	if got := (&Service{}).now(); got.Before(before) {
		t.Fatalf("zero now %v before %v", got, before)
	}
	fixed := time.Date(2026, 1, 2, 3, 0, 0, 0, time.UTC)
	if !(&Service{Now: func() time.Time { return fixed }}).now().Equal(fixed) {
		t.Fatal("Now not used")
	}
}
