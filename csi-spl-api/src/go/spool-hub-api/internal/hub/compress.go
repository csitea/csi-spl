package hub

import (
	"bytes"
	"compress/gzip"
	"io"
	"mime"
	"net/http"
	"strings"
	"sync"
)

// gzipMinBytes: a JSON body smaller than this goes out as it is. Below about
// one packet the gzip header and trailer buy nothing.
const gzipMinBytes = 1024

// gzipLevel trades a little ratio for CPU: BestSpeed compresses view JSON
// about 7x at a fraction of DefaultCompression's time.
const gzipLevel = gzip.BestSpeed

var gzipPool = sync.Pool{New: func() any {
	zw, _ := gzip.NewWriterLevel(io.Discard, gzipLevel)
	return zw
}}

// compressJSON gzips JSON responses for a client that accepts gzip
// The hub sent every view uncompressed: on prd (6 h, Cloud Run
// log, 2026-09-27) /v1/view/topics was 20 KB p50 and 295 KB p95,
// /v1/view/issues 1.06 MB p95, one open topic 713 KB, which a throttled
// phone link pays for in seconds. Only application/json without a
// Content-Encoding or Content-Length of its own is touched; a WebSocket
// upgrade, a file (application/octet-stream) and a HEAD pass through as they
// were.
func compressJSON(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead || r.Header.Get("Upgrade") != "" || !acceptsGzip(r.Header.Values("Accept-Encoding")) {
			next.ServeHTTP(w, r)
			return
		}
		gw := &gzipWriter{ResponseWriter: w}
		defer gw.finish()
		next.ServeHTTP(gw, r)
	})
}

// acceptsGzip reports whether an Accept-Encoding list takes gzip (q > 0). It
// runs on every non-HEAD, non-upgrade request, so it scans the header in place:
// strings.Split + ReplaceAll allocated a slice and a string per call for a
// check that never needs either.
func acceptsGzip(values []string) bool {
	for _, v := range values {
		for len(v) > 0 {
			part := v
			if i := strings.IndexByte(v, ','); i >= 0 {
				part, v = v[:i], v[i+1:]
			} else {
				v = ""
			}
			name, params, _ := strings.Cut(part, ";")
			if !strings.EqualFold(strings.TrimSpace(name), "gzip") {
				continue
			}
			return !qIsZero(params)
		}
	}
	return false
}

// qIsZero reports whether an Accept-Encoding parameter list quotes a zero
// quality (q=0 in any of its written forms), ignoring spaces — the old
// ReplaceAll compare without the allocation. `switch string(buf[:n])` is a
// compiler special case that does not heap-allocate the key.
func qIsZero(params string) bool {
	var buf [8]byte
	n := 0
	for i := 0; i < len(params); i++ {
		if params[i] == ' ' {
			continue
		}
		if n >= len(buf) {
			return false // longer than "q=0.000" — not a zero-quality form
		}
		buf[n] = params[i]
		n++
	}
	switch string(buf[:n]) {
	case "q=0", "q=0.0", "q=0.00", "q=0.000":
		return true
	}
	return false
}

// gzipWriter decides at WriteHeader whether the body is compressed. An
// eligible body is held until it reaches gzipMinBytes (then gzipped) or the
// handler returns (then written plain).
type gzipWriter struct {
	http.ResponseWriter
	status  int
	decided bool // WriteHeader seen
	hold    bool // eligible, still under gzipMinBytes
	buf     bytes.Buffer
	zw      *gzip.Writer
}

func (g *gzipWriter) WriteHeader(code int) {
	if g.decided {
		return
	}
	g.decided, g.status = true, code
	h := g.Header()
	h.Add("Vary", "Accept-Encoding")
	mt, _, _ := mime.ParseMediaType(h.Get("Content-Type"))
	if mt == "application/json" && h.Get("Content-Encoding") == "" && h.Get("Content-Length") == "" &&
		code >= http.StatusOK && code != http.StatusNoContent && code != http.StatusNotModified {
		g.hold = true
		return
	}
	g.ResponseWriter.WriteHeader(code)
}

func (g *gzipWriter) Write(p []byte) (int, error) {
	if !g.decided {
		g.WriteHeader(http.StatusOK)
	}
	switch {
	case g.zw != nil:
		return g.zw.Write(p)
	case !g.hold:
		return g.ResponseWriter.Write(p)
	}
	if g.buf.Len()+len(p) < gzipMinBytes {
		g.buf.Write(p)
		return len(p), nil
	}
	g.hold = false
	h := g.Header()
	h.Set("Content-Encoding", "gzip")
	h.Del("Content-Length")
	g.ResponseWriter.WriteHeader(g.status)
	g.zw = gzipPool.Get().(*gzip.Writer)
	g.zw.Reset(g.ResponseWriter)
	// SPL-1122: what is held goes first, then p straight into the stream. A
	// view answer arrives in ONE Write (wire.WriteJSON), and copying it into
	// buf first allocated and copied the whole body (1.2 MB per 1 MB answer).
	if g.buf.Len() > 0 {
		if _, err := g.zw.Write(g.buf.Bytes()); err != nil {
			return 0, err
		}
		g.buf.Reset()
	}
	if _, err := g.zw.Write(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

// plain writes a held body as it is.
func (g *gzipWriter) plain() {
	if !g.hold {
		return
	}
	g.hold = false
	g.ResponseWriter.WriteHeader(g.status)
	g.ResponseWriter.Write(g.buf.Bytes()) //nolint:errcheck
	g.buf.Reset()
}

// Flush sends what there is: a held body goes out plain, a gzip stream is
// flushed through.
func (g *gzipWriter) Flush() {
	if g.zw != nil {
		g.zw.Flush() //nolint:errcheck
	} else {
		g.plain()
	}
	http.NewResponseController(g.ResponseWriter).Flush() //nolint:errcheck
}

func (g *gzipWriter) finish() {
	if g.zw != nil {
		g.zw.Close() //nolint:errcheck
		g.zw.Reset(io.Discard)
		gzipPool.Put(g.zw)
		g.zw = nil
		return
	}
	g.plain()
}

func (g *gzipWriter) Unwrap() http.ResponseWriter { return g.ResponseWriter }
