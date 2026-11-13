package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// fanoutRig is n live browser sockets on a bare Server: the hub end of each
// is a wuiConn following the lobby, the browser end hands every frame it
// reads to got (or drops it when got is nil).
func fanoutRig(tb testing.TB, n int, got chan<- []byte) (*Server, func()) {
	tb.Helper()
	conns := make(chan *websocket.Conn, n)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		conns <- c
		<-r.Context().Done()
	}))
	s := &Server{wui: map[*wuiConn]struct{}{}}
	ctx, cancel := context.WithCancel(context.Background())
	var clients []*websocket.Conn
	for i := 0; i < n; i++ {
		cc, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
		if err != nil {
			tb.Fatal(err)
		}
		cc.SetReadLimit(-1)
		clients = append(clients, cc)
		go func() {
			for {
				_, p, err := cc.Read(ctx)
				if err != nil {
					return
				}
				if got != nil {
					got <- p
				}
			}
		}()
		s.wui[&wuiConn{conn: <-conns, tenant: "t1", from: "h1",
			chans: map[string]bool{LobbyChannel: true}, subs: map[string]bool{}}] = struct{}{}
	}
	return s, func() {
		cancel()
		for _, c := range clients {
			c.CloseNow() //nolint:errcheck
		}
		srv.Close()
	}
}

// benchRow is one lobby post as the store hands it to fanoutWUI.
func benchRow() store.Message {
	env := `{"v":1,"channel":"` + LobbyChannel + `","from_box":"box-wui","to_box":"box-wui","sig":"",` +
		`"msg":{"v":1,"msg_id":"m-1","task_id":"t-1","ts":"2026-10-03T00:00:00Z","from":"h1","to":"ALL-0",` +
		`"kind":"msg","body":"` + strings.Repeat("a fan-out line ", 20) + `","files":[]}}`
	return store.Message{TenantID: "t1", TaskID: "t-1", Channel: LobbyChannel, FromID: "h1",
		ToID: BroadcastID, MsgID: "m-1", ReceivedAt: time.Unix(1_790_000_000, 0), Env: []byte(env)}
}

// BenchmarkFanoutWUI / BenchmarkFanoutIssue: one frame to 10 sockets
// (perf round 4, G8: the frame is encoded once, not once per socket).
//
//	go test ./internal/hub -run '^$' -bench 'BenchmarkFanout(WUI|Issue)$' -benchmem -count 6
func BenchmarkFanoutWUI(b *testing.B) {
	s, done := fanoutRig(b, 10, nil)
	defer done()
	row, ctx := benchRow(), context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s.fanoutWUI(ctx, row)
	}
}

func BenchmarkFanoutIssue(b *testing.B) {
	s, done := fanoutRig(b, 10, nil)
	defer done()
	ctx := context.Background()
	frame := map[string]any{"type": "issue", "issue": map[string]any{"number": 42, "title": strings.Repeat("an issue title ", 8),
		"status": "open", "labels": []string{"bug", "perf"}, "assignee": "h1", "body": strings.Repeat("issue body ", 40)}}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s.fanoutIssue(ctx, "t1", frame)
	}
}

// benchChannelFrame is a sidebar `channel` frame as fanoutChannel builds it.
func benchChannelFrame() map[string]any {
	return map[string]any{"type": "channel", "channel": "c-0123456789", "name": "perf-round-7",
		"description": strings.Repeat("a channel description ", 8), "created_by": "h1",
		"created_at": "2026-11-13T00:00:00Z"}
}

// BenchmarkFanoutChannel: one channel frame to 10 sockets (perf round 7,
// p7-01: encoded once, as fanoutIssue).
//
//	go test ./internal/hub -run '^$' -bench 'BenchmarkFanoutChannel$' -benchmem -count 5
func BenchmarkFanoutChannel(b *testing.B) {
	s, done := fanoutRig(b, 10, nil)
	defer done()
	ctx, frame := context.Background(), benchChannelFrame()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s.fanoutChannelFrame(ctx, "t1", nil, frame)
	}
}

// The channel fan-out to 10 sockets allocates at most the encode-once arm
// (fanoutIssue, the same frame) plus 10 %; a marshal per socket is far above.
// AllocsPerRun counts the whole process, so goroutines other tests left
// running add to it: the arms alternate and each keeps its lowest of 5 rounds.
func TestFanoutChannelEncodesOnce(t *testing.T) {
	s, done := fanoutRig(t, 10, nil)
	defer done()
	ctx, frame := context.Background(), benchChannelFrame()
	once, got := math.Inf(1), math.Inf(1)
	for i := 0; i < 5; i++ {
		once = math.Min(once, testing.AllocsPerRun(50, func() { s.fanoutIssue(ctx, "t1", frame) }))
		got = math.Min(got, testing.AllocsPerRun(50, func() { s.fanoutChannelFrame(ctx, "t1", nil, frame) }))
	}
	if got > once*1.1 {
		t.Fatalf("fanoutChannelFrame: %.0f allocs/run, encode-once arm %.0f (+10 %% = %.0f)", got, once, once*1.1)
	}
	t.Logf("fanoutChannelFrame %.0f allocs/run, encode-once arm %.0f", got, once)
}

// Every socket receives the same bytes, and they are what wsjson.Write sent
// before G8: the JSON encoding plus the Encoder's trailing newline.
// The channel frame (fanoutChannelFrame, p7-01) is pinned the same way.
func TestFanoutSendsOneEncodingToEverySocket(t *testing.T) {
	frame := map[string]any{"type": "issue", "n": 7, "html": "<b>&</b>"}
	t.Run("issue", func(t *testing.T) {
		assertOneEncoding(t, frame, func(s *Server) { s.fanoutIssue(context.Background(), "t1", frame) })
	})
	ch := benchChannelFrame()
	ch["html"] = "<b>&</b>"
	t.Run("channel", func(t *testing.T) {
		assertOneEncoding(t, ch, func(s *Server) { s.fanoutChannelFrame(context.Background(), "t1", nil, ch) })
	})
}

// assertOneEncoding runs fanout over 3 sockets and checks that each one got
// frame as json.Encoder writes it, trailing newline included.
func assertOneEncoding(t *testing.T, frame map[string]any, fanout func(*Server)) {
	t.Helper()
	got := make(chan []byte, 3)
	s, done := fanoutRig(t, 3, got)
	defer done()
	fanout(s)
	var want bytes.Buffer
	json.NewEncoder(&want).Encode(frame) //nolint:errcheck
	for i := 0; i < 3; i++ {
		select {
		case p := <-got:
			if !bytes.Equal(p, want.Bytes()) {
				t.Fatalf("socket %d got %q, want %q", i, p, want.Bytes())
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("socket %d: no frame", i)
		}
	}
}
