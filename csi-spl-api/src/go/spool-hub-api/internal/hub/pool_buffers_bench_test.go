package hub

import (
	"context"
	"crypto/ed25519"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// BenchmarkETagView is one eligible view read through etagViews into a writer
// that keeps nothing: what holding the body to hash it costs per request
// (perf round 4, G10).
//
//	go test ./internal/hub -run '^$' -bench 'BenchmarkETagView|BenchmarkSessionWrite' -benchmem -count 6
func BenchmarkETagView(b *testing.B) {
	for _, size := range []struct {
		name string
		n    int
	}{{"20KB", 20 << 10}, {"133KB", 133 << 10}} {
		body := []byte(jsonOf(size.n))
		h := etagViews(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.Write(body) //nolint:errcheck
		}))
		req := httptest.NewRequest(http.MethodGet, "/v1/view/topics", nil)
		rw := &discardRW{h: http.Header{}}
		b.Run(size.name, func(b *testing.B) {
			b.SetBytes(int64(len(body)))
			b.ReportAllocs()
			for b.Loop() {
				clear(rw.h)
				h.ServeHTTP(rw, req)
			}
		})
	}
}

// BenchmarkSessionWrite is one recv frame through session.write onto a real
// socket whose peer discards it: the per-frame cost of encoding a box frame
// (perf round 4, G10).
func BenchmarkSessionWrite(b *testing.B) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		c.SetReadLimit(-1)
		for {
			_, rd, err := c.Reader(context.Background())
			if err != nil {
				return
			}
			io.Copy(io.Discard, rd) //nolint:errcheck
		}
	}))
	defer srv.Close()
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		b.Fatal(err)
	}
	defer c.CloseNow() //nolint:errcheck
	x := &session{conn: c, welcomed: make(chan struct{})}
	x.markWelcomed()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		b.Fatal(err)
	}
	for _, size := range []struct {
		name string
		n    int
	}{{"1KB", 1 << 10}, {"64KB", 64 << 10}} {
		env, err := wire.NewEnvelope(priv, "box-a", "box-b", &msg.Message{
			V: msg.V1, MsgID: "11111111-2222-4333-8444-555555555555",
			TaskID: "66666666-7777-4888-8999-aaaaaaaaaaaa", TS: "2026-09-21T12:00:00Z",
			From: "HUM-1", To: "CLE-00", Kind: "note", Body: strings.Repeat("x", size.n), Files: []msg.Attachment{},
		})
		if err != nil {
			b.Fatal(err)
		}
		raw, err := env.Marshal()
		if err != nil {
			b.Fatal(err)
		}
		f := wire.Frame{Type: wire.TRecv, Env: raw, Agents: []string{"CLE-00"}}
		b.Run(size.name, func(b *testing.B) {
			b.SetBytes(int64(len(raw)))
			b.ReportAllocs()
			for b.Loop() {
				if err := x.write(ctx, f); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
