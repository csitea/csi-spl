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

// discardRW is a ResponseWriter that keeps nothing, so a benchmark measures
// the middleware and not a recorder's buffer.
type discardRW struct{ h http.Header }

func (d *discardRW) Header() http.Header         { return d.h }
func (d *discardRW) WriteHeader(int)             {}
func (d *discardRW) Write(p []byte) (int, error) { return len(p), nil }

// BenchmarkCompressJSON gzips one view answer as wire.WriteJSON hands it
// over: the whole body in one Write (SPL-1122 measures B/op and allocs/op).
//
//	go test ./internal/hub -run '^$' -bench BenchmarkCompressJSON -benchmem -count 5
func BenchmarkCompressJSON(b *testing.B) {
	for _, size := range []struct {
		name string
		n    int
	}{{"8KB", 8 << 10}, {"128KB", 128 << 10}, {"1MB", 1 << 20}} {
		body := []byte(jsonOf(size.n))
		h := compressJSON(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			w.Write(body) //nolint:errcheck
		}))
		req := httptest.NewRequest(http.MethodGet, "/v1/view/issues", nil)
		req.Header.Set("Accept-Encoding", "gzip")
		b.Run(size.name, func(b *testing.B) {
			b.SetBytes(int64(len(body)))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				h.ServeHTTP(&discardRW{h: http.Header{}}, req)
			}
		})
	}
}

// SPL-1122: a body handed over in one Write, in several, or under and then
// over gzipMinBytes decompresses to exactly the bytes the handler wrote.
func TestCompressJSONChunkingKeepsTheBody(t *testing.T) {
	big := []byte(jsonOf(64 << 10))
	for _, chunks := range [][]int{{len(big)}, {10, 500, len(big) - 510}, {1023, 1, len(big) - 1024}, {2000, len(big) - 2000}} {
		rec := serveCompressed(t, func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			off := 0
			for _, n := range chunks {
				w.Write(big[off : off+n]) //nolint:errcheck
				off += n
			}
		}, http.Header{"Accept-Encoding": {"gzip"}})
		if rec.Header().Get("Content-Encoding") != "gzip" {
			t.Fatalf("chunks %v: not gzipped", chunks)
		}
		zr, err := gzip.NewReader(bytes.NewReader(rec.Body.Bytes()))
		if err != nil {
			t.Fatal(err)
		}
		got, _ := io.ReadAll(zr)
		if !bytes.Equal(got, big) {
			t.Fatalf("chunks %v: %d bytes back, want %d identical", chunks, len(got), len(big))
		}
	}
}

// acceptsGzipOld is the pre-perf parser (strings.Split + ReplaceAll), kept only
// so BenchmarkAcceptsGzip shows the allocations this change removes.
func acceptsGzipOld(values []string) bool {
	for _, v := range values {
		for _, part := range strings.Split(v, ",") {
			name, params, _ := strings.Cut(strings.TrimSpace(part), ";")
			if !strings.EqualFold(strings.TrimSpace(name), "gzip") {
				continue
			}
			q := strings.ReplaceAll(strings.TrimSpace(params), " ", "")
			return q != "q=0" && q != "q=0.0" && q != "q=0.00" && q != "q=0.000"
		}
	}
	return false
}

// benchAcceptEncoding is a realistic browser Accept-Encoding with gzip last.
var benchAcceptEncoding = []string{"br;q=1.0, deflate;q=0.8, gzip;q=0.5"}

func BenchmarkAcceptsGzipOld(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = acceptsGzipOld(benchAcceptEncoding)
	}
}

func BenchmarkAcceptsGzipNew(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = acceptsGzip(benchAcceptEncoding)
	}
}
