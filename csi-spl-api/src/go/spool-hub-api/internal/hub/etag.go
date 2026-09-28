package hub

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"mime"
	"net/http"
	"strings"
)

// etagPrefix is the part of the API that answers conditional reads: the
// view reads the WUI repeats on every page load and route change.
const etagPrefix = "/v1/view/"

// etagViews gives a view read a validator (CLE-35076). The WUI re-reads the
// same view URLs on every reload and route change (prd 24 h to 2026-09-28:
// /v1/view/topics p95 133 KB, /v1/view/issues p95 296 KB), and without an
// ETag every read came back in full even when nothing had changed.
//
// The ETag is the hash of the exact body, so a 304 is only ever sent for
// bytes identical to what the browser already holds, whoever's session
// asked: it can never serve another member's or another tenant's view.
// `private, no-cache` makes the browser ask every time (nothing is served
// from cache unasked, and no shared cache keeps it); the saving is the body.
// The handler still runs in full, so reads cost the hub the same; the
// saving is the wire and the phone. It sits inside compressJSON, so the
// hash is over the uncompressed JSON and the tag is weak (W/).
//
// Only GET under etagPrefix, only a 200 application/json the handler did not
// give its own Cache-Control or ETag. A Flush (a streamed answer) turns it
// off for that response.
func etagViews(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || !strings.HasPrefix(r.URL.Path, etagPrefix) || r.Header.Get("Upgrade") != "" {
			next.ServeHTTP(w, r)
			return
		}
		ew := &etagWriter{ResponseWriter: w, inm: r.Header.Get("If-None-Match")}
		defer ew.finish()
		next.ServeHTTP(ew, r)
	})
}

// etagWriter holds an eligible body until the handler returns.
type etagWriter struct {
	http.ResponseWriter
	inm     string
	status  int
	decided bool
	hold    bool
	buf     bytes.Buffer
}

func (e *etagWriter) WriteHeader(code int) {
	if e.decided {
		return
	}
	e.decided, e.status = true, code
	h := e.Header()
	mt, _, _ := mime.ParseMediaType(h.Get("Content-Type"))
	if code == http.StatusOK && mt == "application/json" && h.Get("Cache-Control") == "" && h.Get("ETag") == "" {
		e.hold = true
		return
	}
	e.ResponseWriter.WriteHeader(code)
}

func (e *etagWriter) Write(p []byte) (int, error) {
	if !e.decided {
		e.WriteHeader(http.StatusOK)
	}
	if !e.hold {
		return e.ResponseWriter.Write(p)
	}
	return e.buf.Write(p)
}

// Flush gives up on the tag: what is held goes out as it is.
func (e *etagWriter) Flush() {
	e.release()
	http.NewResponseController(e.ResponseWriter).Flush() //nolint:errcheck
}

func (e *etagWriter) release() {
	if !e.hold {
		return
	}
	e.hold = false
	e.ResponseWriter.WriteHeader(e.status)
	e.ResponseWriter.Write(e.buf.Bytes()) //nolint:errcheck
	e.buf.Reset()
}

func (e *etagWriter) finish() {
	if !e.hold {
		return
	}
	e.hold = false
	tag := bodyETag(e.buf.Bytes())
	h := e.Header()
	h.Set("ETag", tag)
	h.Set("Cache-Control", "private, no-cache")
	if etagMatch(e.inm, tag) {
		h.Del("Content-Type")
		h.Del("Content-Length")
		e.ResponseWriter.WriteHeader(http.StatusNotModified)
		return
	}
	e.ResponseWriter.WriteHeader(e.status)
	e.ResponseWriter.Write(e.buf.Bytes()) //nolint:errcheck
}

func (e *etagWriter) Unwrap() http.ResponseWriter { return e.ResponseWriter }

// bodyETag is a weak validator over the body: 128 bits of its SHA-256.
func bodyETag(b []byte) string {
	sum := sha256.Sum256(b)
	return `W/"` + base64.RawURLEncoding.EncodeToString(sum[:16]) + `"`
}

// etagMatch is If-None-Match's weak comparison (RFC 9110 13.1.2): "*" or any
// listed tag equal to tag once a W/ prefix is ignored on either side.
func etagMatch(header, tag string) bool {
	if header == "" {
		return false
	}
	want := strings.TrimPrefix(tag, "W/")
	for _, t := range strings.Split(header, ",") {
		t = strings.TrimSpace(t)
		if t == "*" || strings.TrimPrefix(t, "W/") == want {
			return true
		}
	}
	return false
}
