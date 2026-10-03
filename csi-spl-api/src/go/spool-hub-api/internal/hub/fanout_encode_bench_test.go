package hub

import (
	"bytes"
	"context"
	"encoding/json"
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

// Every socket receives the same bytes, and they are what wsjson.Write sent
// before G8: the JSON encoding plus the Encoder's trailing newline.
func TestFanoutSendsOneEncodingToEverySocket(t *testing.T) {
	got := make(chan []byte, 3)
	s, done := fanoutRig(t, 3, got)
	defer done()
	frame := map[string]any{"type": "issue", "n": 7, "html": "<b>&</b>"}
	s.fanoutIssue(context.Background(), "t1", frame)
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
