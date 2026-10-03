package hub

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// G10: the held-body buffer is pooled. A reused buffer must carry nothing
// of the request before it, whether that one was sent, flushed or answered
// 304, and a body over etagBufMax still goes out whole.
func TestETagPooledBufferCarriesNothingOver(t *testing.T) {
	big := jsonOf(etagBufMax + 4096)
	bodies := []string{jsonOf(64 << 10), `{"a":1}`, big, `{"b":2}`, jsonOf(300), `{"c":3}`}
	var tagOfB string
	for round := 0; round < 3; round++ {
		for i, body := range bodies {
			flush := i == 4
			h := etagViews(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.Write([]byte(body[:len(body)/2])) //nolint:errcheck
				if flush {
					w.(http.Flusher).Flush()
				}
				w.Write([]byte(body[len(body)/2:])) //nolint:errcheck
			}))
			req := httptest.NewRequest(http.MethodGet, "/v1/view/topics", nil)
			if body == `{"b":2}` && tagOfB != "" {
				req.Header.Set("If-None-Match", tagOfB)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if body == `{"b":2}` && tagOfB != "" {
				if rec.Code != http.StatusNotModified || rec.Body.Len() != 0 {
					t.Fatalf("round %d: want an empty 304, got %d with %d bytes", round, rec.Code, rec.Body.Len())
				}
				continue
			}
			if rec.Code != http.StatusOK || rec.Body.String() != body {
				t.Fatalf("round %d body %d: got %d, %d bytes (want %d): %.40q", round, i, rec.Code, rec.Body.Len(), len(body), strings.TrimSpace(rec.Body.String()))
			}
			if body == `{"b":2}` {
				tagOfB = rec.Header().Get("ETag")
			}
		}
	}
}
