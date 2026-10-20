package hubclient

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// supersedeHub welcomes every hello and closes the sessions whose hello
// number is in evict with 4409, as the hub does when a newer hello for the
// box arrives; the others it holds until the test ends.
type supersedeHub struct {
	hellos atomic.Int32
	evict  map[int32]bool
}

func (h *supersedeHub) start(t *testing.T) string {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/pins", func(w http.ResponseWriter, _ *http.Request) {
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
		if h.evict[n] {
			time.Sleep(50 * time.Millisecond)              // let the client's dial settle
			conn.Close(wire.CloseSuperseded, "superseded") //nolint:errcheck
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

func supersedeClient(t *testing.T, url string, logs *syncBuf) *Client {
	c := testClient(t)
	c.Cfg.HubURL = url
	c.Cfg.Tenant = "t1"
	c.Cfg.SubmitSocket = "off"
	c.ReadyTimeout = 2 * time.Second
	c.SessionProbe = -1
	c.SupersedeYield = 100 * time.Millisecond
	c.SupersedeFight = 5 * time.Second
	c.Log = zerolog.New(logs)
	return c
}

// One newer hello (a one-shot hub-sync): Run yields, says hello again and
// holds the box. Before SPL-2712 it returned ErrSuperseded after hello 1.
func TestRunRehellosAfterOneSupersede(t *testing.T) {
	h := &supersedeHub{evict: map[int32]bool{1: true}}
	var logs syncBuf
	c := supersedeClient(t, h.start(t), &logs)
	ctx, cancel := context.WithCancel(context.Background())
	ran := make(chan error, 1)
	go func() { ran <- c.Run(ctx) }()
	deadline := time.Now().Add(3 * time.Second)
	for h.hellos.Load() < 2 {
		select {
		case err := <-ran:
			t.Fatalf("Run returned %v after one supersede; log:\n%s", err, logs.String())
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("no re-hello within 3 s (hellos %d); log:\n%s", h.hellos.Load(), logs.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	select {
	case err := <-ran:
		t.Fatalf("Run returned %v after its re-hello", err)
	case <-time.After(300 * time.Millisecond):
	}
	cancel()
	if err := <-ran; err != nil {
		t.Fatalf("Run after cancel: %v", err)
	}
	if !strings.Contains(logs.String(), "saying hello again") {
		t.Errorf("no yield line in the log:\n%s", logs.String())
	}
}

// Superseded again right after the re-hello: another hub-run holds the box,
// and Run leaves it with ErrSuperseded instead of fighting.
func TestRunLeavesWhenSupersededAfterRehello(t *testing.T) {
	h := &supersedeHub{evict: map[int32]bool{1: true, 2: true, 3: true}}
	var logs syncBuf
	c := supersedeClient(t, h.start(t), &logs)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := c.Run(ctx)
	if !errors.Is(err, ErrSuperseded) {
		t.Fatalf("Run = %v, want ErrSuperseded; log:\n%s", err, logs.String())
	}
	if n := h.hellos.Load(); n != 2 {
		t.Fatalf("hellos %d, want 2 (one re-hello, then leave)", n)
	}
	if !strings.Contains(logs.String(), "another hub-run holds this box") {
		t.Errorf("no leave line in the log:\n%s", logs.String())
	}
}

// A re-hello session that outlived the fight window, then a second newer
// hello: still a one-shot sync, so Run yields again rather than leaving.
func TestRunRehelloStateClearsAfterFightWindow(t *testing.T) {
	c := &Client{SupersedeFight: time.Second, SupersedeYield: time.Millisecond, Cfg: testClient(t).Cfg, Log: zerolog.Nop()}
	rehello := true
	if c.yield(context.Background(), &rehello, 2*time.Second) {
		t.Fatal("left after a re-hello that held past the fight window")
	}
	if c.yield(context.Background(), &rehello, 10*time.Millisecond) != true {
		t.Fatal("stayed after a supersede inside the fight window of a re-hello")
	}
	d := &Client{}
	if d.supersedeYield() != defaultSupersedeYield || d.supersedeFight() != defaultSupersedeFight {
		t.Fatal("zero fields do not give the defaults")
	}
	if d.supersedeFight() <= d.supersedeYield() {
		t.Fatal("the fight window must outlast the yield, or two daemons never meet inside it")
	}
}
