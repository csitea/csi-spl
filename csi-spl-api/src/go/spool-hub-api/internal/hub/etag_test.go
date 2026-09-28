package hub

import (
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func viewJSON(body string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "https://wui.example.com")
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, body) //nolint:errcheck
	}
}

func serveETag(h http.Handler, method, path string, hdr map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// TestETagViews (CLE-35076): a view read carries a validator over its exact
// body; the same body asked again with that tag is a 304 with no body, and
// any other body (another member, a change) is a 200 in full.
func TestETagViews(t *testing.T) {
	body := `{"topics":[` + strings.Repeat(`{"task_id":"t"},`, 200) + `{}]}`
	h := compressJSON(etagViews(viewJSON(body)))

	first := serveETag(h, http.MethodGet, "/v1/view/topics", map[string]string{"Accept-Encoding": "gzip"})
	tag := first.Header().Get("ETag")
	if first.Code != http.StatusOK || !strings.HasPrefix(tag, `W/"`) {
		t.Fatalf("first read: %d ETag %q", first.Code, tag)
	}
	if cc := first.Header().Get("Cache-Control"); cc != "private, no-cache" {
		t.Errorf("Cache-Control %q, want private, no-cache", cc)
	}
	if first.Header().Get("Content-Encoding") != "gzip" {
		t.Errorf("the tagged body is still gzipped: %v", first.Header())
	}
	zr, err := gzip.NewReader(first.Body)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := io.ReadAll(zr); string(got) != body {
		t.Fatalf("body changed: %d bytes, want %d", len(got), len(body))
	}

	again := serveETag(h, http.MethodGet, "/v1/view/topics", map[string]string{"Accept-Encoding": "gzip", "If-None-Match": tag})
	if again.Code != http.StatusNotModified || again.Body.Len() != 0 {
		t.Fatalf("same body + If-None-Match: %d with %d body bytes, want 304 and none", again.Code, again.Body.Len())
	}
	if again.Header().Get("ETag") != tag || again.Header().Get("Access-Control-Allow-Origin") == "" {
		t.Errorf("304 lost its ETag or CORS header: %v", again.Header())
	}
	if again.Header().Get("Content-Encoding") != "" {
		t.Errorf("304 claims an encoding: %v", again.Header())
	}

	// a strong-form and a list form of the same tag match too (weak comparison)
	strong := strings.TrimPrefix(tag, "W/")
	if rec := serveETag(h, http.MethodGet, "/v1/view/topics", map[string]string{"If-None-Match": `"x", ` + strong}); rec.Code != http.StatusNotModified {
		t.Errorf("list with the strong form: %d, want 304", rec.Code)
	}

	// a different body under the same URL is never a 304
	other := compressJSON(etagViews(viewJSON(strings.Replace(body, `"t"`, `"u"`, 1))))
	if rec := serveETag(other, http.MethodGet, "/v1/view/topics", map[string]string{"If-None-Match": tag}); rec.Code != http.StatusOK || rec.Body.Len() == 0 {
		t.Fatalf("changed body with the old tag: %d (%d bytes), want 200 in full", rec.Code, rec.Body.Len())
	}
}

// TestETagViewsLeavesOthersAlone: not a view GET, not a 200, not JSON, or a
// handler with its own caching - passed through exactly as before.
func TestETagViewsLeavesOthersAlone(t *testing.T) {
	js := viewJSON(`{"ok":true}`)
	cases := []struct {
		name, method, path string
		h                  http.HandlerFunc
	}{
		{"POST", http.MethodPost, "/v1/view/topics", js},
		{"HEAD", http.MethodHead, "/v1/view/topics", js},
		{"not a view", http.MethodGet, "/v1/pins", js},
		{"404", http.MethodGet, "/v1/view/topics/x", func(w http.ResponseWriter, _ *http.Request) {
			writeErr(w, http.StatusNotFound, "not_found", "no")
		}},
		{"own Cache-Control", http.MethodGet, "/v1/view/events", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			js(w, r)
		}},
		{"octet-stream", http.MethodGet, "/v1/view/file", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/octet-stream")
			w.Write([]byte("bytes")) //nolint:errcheck
		}},
	}
	for _, c := range cases {
		rec := serveETag(etagViews(c.h), c.method, c.path, map[string]string{"If-None-Match": "*"})
		if rec.Header().Get("ETag") != "" || rec.Code == http.StatusNotModified {
			t.Errorf("%s: tagged (%d, %v)", c.name, rec.Code, rec.Header())
		}
	}
}

// TestETagViewsFlushStreams: a handler that flushes gets its bytes out at once.
func TestETagViewsFlushStreams(t *testing.T) {
	h := etagViews(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"a":1}`)          //nolint:errcheck
		http.NewResponseController(w).Flush() //nolint:errcheck
		io.WriteString(w, `{"b":2}`)          //nolint:errcheck
	}))
	rec := serveETag(h, http.MethodGet, "/v1/view/stream", nil)
	if rec.Body.String() != `{"a":1}{"b":2}` || rec.Header().Get("ETag") != "" || !rec.Flushed {
		t.Fatalf("streamed: %q ETag %q flushed %v", rec.Body.String(), rec.Header().Get("ETag"), rec.Flushed)
	}
}

func TestETagMatch(t *testing.T) {
	for _, c := range []struct {
		h    string
		want bool
	}{{"", false}, {"*", true}, {`W/"abc"`, true}, {`"abc"`, true}, {`"x", W/"abc"`, true}, {`"abcd"`, false}} {
		if got := etagMatch(c.h, `W/"abc"`); got != c.want {
			t.Errorf("etagMatch(%q) = %v, want %v", c.h, got, c.want)
		}
	}
}
