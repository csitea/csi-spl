package hub

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func serveCompressed(t *testing.T, h http.HandlerFunc, header http.Header) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/v1/view/topics", nil)
	for k, v := range header {
		req.Header[k] = v
	}
	rec := httptest.NewRecorder()
	compressJSON(h).ServeHTTP(rec, req)
	return rec
}

func jsonOf(n int) string { return `{"x":"` + strings.Repeat("topic ", n/6) + `"}` }

// TestCompressJSON: a JSON body a client can take gzipped goes
// out gzipped, byte-identical once decoded; everything else is untouched.
func TestCompressJSON(t *testing.T) {
	big := jsonOf(20000)
	gz := http.Header{"Accept-Encoding": {"gzip, deflate, br"}}
	js := func(body string, status int) http.HandlerFunc {
		return func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			io.WriteString(w, body) //nolint:errcheck
		}
	}

	rec := serveCompressed(t, js(big, http.StatusOK), gz)
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Encoding") != "gzip" {
		t.Fatalf("big JSON: status %d, Content-Encoding %q", rec.Code, rec.Header().Get("Content-Encoding"))
	}
	if !strings.Contains(rec.Header().Get("Vary"), "Accept-Encoding") {
		t.Errorf("big JSON: Vary %q lacks Accept-Encoding", rec.Header().Get("Vary"))
	}
	t.Logf("%d bytes -> %d on the wire", len(big), rec.Body.Len())
	zr, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(zr)
	if err != nil || string(got) != big {
		t.Fatalf("big JSON decodes to %d bytes (%v), want the %d sent", len(got), err, len(big))
	}

	// An error status is compressed too (a 4xx JSON body is still JSON).
	if rec := serveCompressed(t, js(big, http.StatusNotFound), gz); rec.Code != http.StatusNotFound || rec.Header().Get("Content-Encoding") != "gzip" {
		t.Errorf("big 404: status %d, Content-Encoding %q", rec.Code, rec.Header().Get("Content-Encoding"))
	}

	for _, c := range []struct {
		name   string
		h      http.HandlerFunc
		header http.Header
	}{
		{"small JSON", js(`{"ok":true}`, http.StatusOK), gz},
		{"no Accept-Encoding", js(big, http.StatusOK), nil},
		{"gzip refused (q=0)", js(big, http.StatusOK), http.Header{"Accept-Encoding": {"br, gzip;q=0"}}},
		{"a file", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/octet-stream")
			io.WriteString(w, big) //nolint:errcheck
		}, gz},
		{"a body with its own Content-Length", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Length", "20000")
			io.WriteString(w, big) //nolint:errcheck
		}, gz},
		{"JSON without WriteHeader, written in pieces", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			io.WriteString(w, `{"a":`) //nolint:errcheck
			io.WriteString(w, `1}`)    //nolint:errcheck
		}, gz},
	} {
		rec := serveCompressed(t, c.h, c.header)
		if ce := rec.Header().Get("Content-Encoding"); ce != "" {
			t.Errorf("%s: Content-Encoding %q, want none", c.name, ce)
		}
		if b := rec.Body.String(); b != big && b != `{"ok":true}` && b != `{"a":1}` {
			t.Errorf("%s: body changed: %.40q", c.name, b)
		}
	}

	// Pieces that together pass the threshold are gzipped as one stream.
	rec = serveCompressed(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		for i := 0; i < 50; i++ {
			io.WriteString(w, `{"piece":"0123456789012345678901234567890123456789"}`) //nolint:errcheck
		}
	}, gz)
	zr, err = gzip.NewReader(bytes.NewReader(rec.Body.Bytes()))
	if err != nil || rec.Header().Get("Content-Encoding") != "gzip" {
		t.Fatalf("pieces: Content-Encoding %q, %v", rec.Header().Get("Content-Encoding"), err)
	}
	if got, _ := io.ReadAll(zr); strings.Count(string(got), `"piece"`) != 50 {
		t.Errorf("pieces: decoded %d bytes, want all 50 pieces", len(got))
	}
}

// A WebSocket upgrade reaches the handler with the server's own writer (it is
// hijacked), never the gzip wrapper.
func TestCompressJSONLeavesUpgradesAlone(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/wui/ws", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	rec := httptest.NewRecorder()
	compressJSON(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if _, wrapped := w.(*gzipWriter); wrapped {
			t.Error("an upgrade request got the gzip writer")
		}
	})).ServeHTTP(rec, req)
}

func TestAcceptsGzip(t *testing.T) {
	for in, want := range map[string]bool{
		"gzip": true, "gzip, deflate, br": true, "br;q=1.0, GZIP;q=0.5": true,
		"": false, "br": false, "gzip;q=0": false, "gzip; q=0.000": false, "x-gzip": false,
	} {
		if got := acceptsGzip([]string{in}); got != want {
			t.Errorf("acceptsGzip(%q) = %v, want %v", in, got, want)
		}
	}
}
