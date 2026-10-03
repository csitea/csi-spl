package hubclient

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// silentHub welcomes the box, answers the pin sync of the dial, and then -
// on its FIRST session only - stops answering anything: it never reads the
// socket again (so no pong) and every later REST call hangs. That is the prd
// t1 desk on 2026-10-03 11:36Z: the sidecar logged "did not answer a ping"
// and then nothing for 16 min, process up, session gone, no redial.
type silentHub struct {
	hellos  atomic.Int32
	pinsReq atomic.Int32
	release chan struct{}
}

func (h *silentHub) start(t *testing.T) string {
	t.Helper()
	h.release = make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/pins", func(w http.ResponseWriter, r *http.Request) {
		if h.pinsReq.Add(1) > 1 && h.hellos.Load() == 1 { // a refresh on the dead session
			select {
			case <-r.Context().Done():
			case <-h.release:
			}
			return
		}
		json.NewEncoder(w).Encode(wire.PinList{Pins: []wire.PinEntry{}}) //nolint:errcheck
	})
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := r.Context()
		var hello wire.Frame
		if wsjson.Write(ctx, conn, challenge) != nil || wsjson.Read(ctx, conn, &hello) != nil {
			return
		}
		n := h.hellos.Add(1)
		if wsjson.Write(ctx, conn, welcome) != nil {
			return
		}
		if n == 1 { // go silent: no read, so no pong, until the test ends
			select {
			case <-ctx.Done():
			case <-h.release:
			}
			return
		}
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(func() { close(h.release); srv.Close() })
	return srv.URL
}

// syncBuf is a log sink the daemon goroutine writes while the test reads.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// TestRunReconnectsWhenHubGoesSilent: the hub stops answering both the socket
// and REST while hold sits in a pin refresh. The keepalive deadline must end
// the session AND free hold, so Run redials - a second hello - within the
// deadline plus one backoff step. RESTTimeout is set far beyond the test so
// only the session's own liveness can unblock the parked refresh.
func TestRunReconnectsWhenHubGoesSilent(t *testing.T) {
	h := &silentHub{}
	c := testClient(t)
	c.Cfg.HubURL = h.start(t)
	c.Cfg.Tenant = "t1"
	c.Cfg.SubmitSocket = "off"
	c.ReadyTimeout = 2 * time.Second
	c.PinRefresh = 20 * time.Millisecond
	c.SessionProbe = -1
	c.KeepAlive = 100 * time.Millisecond
	c.KeepAliveTimeout = 200 * time.Millisecond
	c.RESTTimeout = time.Hour
	var logs syncBuf
	c.Log = zerolog.New(&logs)

	ctx, cancel := context.WithCancel(context.Background())
	ran := make(chan error, 1)
	go func() { ran <- c.Run(ctx) }()
	defer func() {
		cancel()
		select {
		case <-ran:
		case <-time.After(5 * time.Second):
			t.Error("Run did not return after its ctx ended")
		}
	}()

	// keepalive deadline (0.3 s) + one full-jitter backoff step (<= 1 s)
	deadline := time.Now().Add(3 * time.Second)
	for h.hellos.Load() < 2 {
		if time.Now().After(deadline) {
			t.Fatalf("no redial within 3 s of the hub going silent (hellos=%d, pin calls=%d); log:\n%s",
				h.hellos.Load(), h.pinsReq.Load(), logs.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
	if h.pinsReq.Load() < 2 {
		t.Fatalf("hold never reached a pin refresh (pin calls=%d): the test did not park it", h.pinsReq.Load())
	}
	if got := strings.Count(logs.String(), "did not answer a ping"); got != 1 {
		t.Errorf("want one lost-session line, got %d; log:\n%s", got, logs.String())
	}
}
