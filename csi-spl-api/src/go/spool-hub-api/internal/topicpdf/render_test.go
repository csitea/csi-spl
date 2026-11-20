// SPDX-License-Identifier: AGPL-3.0-only

package topicpdf

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A render past its timeout fails with render_timeout (spec 183 row P2): the
// stub renderer holds the request until the client gives up.
func TestHTTPRendererTimeout(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body) // read, so the server sees the client leave
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer srv.Close()
	defer close(release) // runs first: Close waits for the handler
	r := HTTPRenderer{URL: srv.URL, Timeout: 100 * time.Millisecond, Client: srv.Client()}
	_, err := r.Render(context.Background(), []byte("<p>x</p>"))
	if !errors.Is(err, ErrTimeout) || !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "render_timeout") {
		t.Fatalf("err = %v, want render_timeout", err)
	}
	if code, tok := Status(err); code != http.StatusGatewayTimeout || tok != "render_timeout" {
		t.Fatalf("Status = %d %s, want 504 render_timeout", code, tok)
	}
}

func TestHTTPRendererPostsAndReads(t *testing.T) {
	var gotPath, gotType, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotPath, gotType, gotBody = r.Method+" "+r.URL.Path, r.Header.Get("Content-Type"), string(b)
		w.Header().Set("Content-Type", "application/pdf")
		_, _ = w.Write([]byte("%PDF-1.4 stub"))
	}))
	defer srv.Close()
	pdf, err := HTTPRenderer{URL: srv.URL + "/", Client: srv.Client()}.Render(context.Background(), []byte("<p>x</p>"))
	if err != nil || string(pdf) != "%PDF-1.4 stub" {
		t.Fatalf("Render = %q, %v", pdf, err)
	}
	if gotPath != "POST /render" || !strings.HasPrefix(gotType, "text/html") || gotBody != "<p>x</p>" {
		t.Fatalf("renderer saw %q %q %q", gotPath, gotType, gotBody)
	}
}

func TestHTTPRendererStatuses(t *testing.T) {
	cases := []struct {
		code   int
		status int
		token  string
		is     error
	}{
		{http.StatusTooManyRequests, 503, "render_unavailable", ErrBusy},
		{http.StatusServiceUnavailable, 503, "render_unavailable", ErrBusy},
		{http.StatusRequestEntityTooLarge, 413, "too_large", ErrTooLarge},
		{http.StatusGatewayTimeout, 504, "render_timeout", ErrTimeout},
		{http.StatusInternalServerError, 503, "render_unavailable", ErrUnavailable},
	}
	for _, c := range cases {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "chrome said no", c.code)
		}))
		_, err := HTTPRenderer{URL: srv.URL, Client: srv.Client()}.Render(context.Background(), nil)
		srv.Close()
		status, token := Status(err)
		if !errors.Is(err, c.is) || status != c.status || token != c.token {
			t.Errorf("renderer %d: err=%v Status=%d %s, want %d %s", c.code, err, status, token, c.status, c.token)
		}
	}
}

func TestHTTPRendererRefusesOversizePDFAndNoURL(t *testing.T) {
	_, err := HTTPRenderer{}.Render(context.Background(), nil)
	if code, tok := Status(err); code != 503 || tok != "render_unavailable" {
		t.Fatalf("no URL: %v -> %d %s", err, code, tok)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(make([]byte, PicturesMaxBytes+1))
	}))
	defer srv.Close()
	_, err = HTTPRenderer{URL: srv.URL, Client: srv.Client()}.Render(context.Background(), nil)
	if code, tok := Status(err); code != 413 || tok != "too_large" {
		t.Fatalf("oversize PDF: %v -> %d %s", err, code, tok)
	}
	srv.Close()
	_, err = HTTPRenderer{URL: srv.URL, Client: srv.Client()}.Render(context.Background(), nil)
	if code, _ := Status(err); code != 503 {
		t.Fatalf("renderer down: %v -> %d", err, code)
	}
	if code, tok := Status(nil); code != 200 || tok != "" {
		t.Fatalf("Status(nil) = %d %q", code, tok)
	}
}
