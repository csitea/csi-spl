package hubclient

import (
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

// SPL-6514 R7 W1 (a-678): a rotation dial that reaches the hub process
// holding the old session supersedes it (4409) as soon as the hub registers
// the new socket, before the welcome. When that dial then failed - at its
// welcome, or at a 5xx pin sync - rotate kept the dead old session, and Run
// read its own rotation's 4409 as another hub-run taking the box: a 10 s
// supersede yield (sends to pending/) and a re-hello that a second 4409
// within a minute turns into a hub-run exit.

// rollHub registers each hello as the real hub does (hub/ws.go register):
// the box's previous socket is closed with 4409 before the new one is
// welcomed. Hellos in noWelcome are then dropped unwelcomed; GET /v1/pins
// answers 500 from hello pins500From on (0 = never).
type rollHub struct {
	hellos     atomic.Int32
	noWelcome  map[int32]bool
	pins500    int32
	mu         sync.Mutex
	live       *websocket.Conn
	helloTimes []time.Time
}

func (h *rollHub) start(t *testing.T) string {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/pins", func(w http.ResponseWriter, r *http.Request) {
		if h.pins500 > 0 && h.hellos.Load() >= h.pins500 && r.URL.Query().Get("probe") == "" {
			http.Error(w, `{"error":"unavailable"}`, http.StatusInternalServerError)
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
		h.mu.Lock()
		h.helloTimes = append(h.helloTimes, time.Now())
		old := h.live
		h.live = conn
		h.mu.Unlock()
		if old != nil {
			old.Close(wire.CloseSuperseded, "superseded") //nolint:errcheck
		}
		if h.noWelcome[n] {
			return
		}
		if wsjson.Write(ctx, conn, welcome) != nil {
			return
		}
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL
}

// times returns the hello times so far.
func (h *rollHub) times() []time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]time.Time(nil), h.helloTimes...)
}

func TestFailedRotationDialIsNotASupersede(t *testing.T) {
	for _, tc := range []struct {
		name string
		hub  *rollHub
	}{
		{"welcome refused after register", &rollHub{noWelcome: map[int32]bool{2: true}}},
		{"pin sync 500 on the rotation dial", &rollHub{pins500: 2}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var logs syncBuf
			c := supersedeClient(t, tc.hub.start(t), &logs)
			c.SupersedeYield = 10 * time.Second // the default: a yield shows as a 10 s gap
			c.SupersedeFight = time.Minute
			c.RotateAfter = 300 * time.Millisecond
			c.Log = zerolog.New(&logs)
			ctx, cancel := context.WithCancel(context.Background())
			ran := make(chan error, 1)
			go func() { ran <- c.Run(ctx) }()
			const want = 5
			deadline := time.Now().Add(4 * time.Second)
			for tc.hub.hellos.Load() < want && time.Now().Before(deadline) {
				select {
				case err := <-ran:
					t.Fatalf("Run returned %v; log:\n%s", err, logs.String())
				default:
				}
				time.Sleep(10 * time.Millisecond)
			}
			cancel()
			if err := <-ran; err != nil {
				t.Fatalf("Run after cancel: %v; log:\n%s", err, logs.String())
			}
			ts := tc.hub.times()
			if len(ts) < want {
				t.Fatalf("hellos %d in 4 s, want >= %d (a 10 s supersede yield stalls the link); log:\n%s", len(ts), want, logs.String())
			}
			var gap time.Duration
			for i := 1; i < len(ts); i++ {
				gap = max(gap, ts[i].Sub(ts[i-1]))
			}
			t.Logf("hellos=%d max gap between hellos=%v", len(ts), gap.Round(time.Millisecond))
			// under the 10 s yield; a redial after a session up under 1 s
			// (plannedMinUp) still pays Run's 0.5..1 s backoff
			if gap >= 2*time.Second {
				t.Errorf("max gap between hellos %v, want under 2 s", gap)
			}
			if l := logs.String(); strings.Contains(l, "saying hello again") || strings.Contains(l, "another hub-run holds this box") {
				t.Errorf("the rotation's own 4409 was read as another hub-run; log:\n%s", l)
			}
		})
	}
}
