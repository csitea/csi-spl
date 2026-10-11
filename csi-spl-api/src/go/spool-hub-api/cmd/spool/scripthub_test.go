package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit/fakehub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// scriptHub is fakehub's handshake (challenge, welcome) with a scripted
// answer per frame: fakehub answers `send` only, and the client verbs under
// test (lane ops, tail, rsp count, hub-sync) wait on other replies. A
// role=box hello also gets queue_end, as the real hub sends after welcome.
// Every other path (/v1/pins, /v1/files/<id>) goes to rest.
type scriptHub struct {
	URL string

	answer func(wire.Frame) []wire.Frame
	rest   http.HandlerFunc

	mu     sync.Mutex
	frames []wire.Frame
	hellos []wire.Frame
}

func newScriptHub(t *testing.T, answer func(wire.Frame) []wire.Frame, rest http.HandlerFunc) *scriptHub {
	t.Helper()
	h := &scriptHub{answer: answer, rest: rest}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", h.ws)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if h.rest == nil {
			http.NotFound(w, r)
			return
		}
		h.rest(w, r)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	h.URL = srv.URL
	return h
}

func (h *scriptHub) ws(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer conn.CloseNow() //nolint:errcheck
	ctx := context.Background()
	if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}); err != nil {
		return
	}
	var hello wire.Frame
	if err := wsjson.Read(ctx, conn, &hello); err != nil {
		return
	}
	h.mu.Lock()
	h.hellos = append(h.hellos, hello)
	h.mu.Unlock()
	if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID,
		UploadToken: "tok", UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}); err != nil {
		return
	}
	if hello.Role == wire.RoleBox {
		if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TQueueEnd}); err != nil {
			return
		}
	}
	for {
		var f wire.Frame
		if err := wsjson.Read(ctx, conn, &f); err != nil {
			return
		}
		h.mu.Lock()
		h.frames = append(h.frames, f)
		h.mu.Unlock()
		if h.answer == nil {
			continue
		}
		for _, out := range h.answer(f) {
			if err := wsjson.Write(ctx, conn, out); err != nil {
				return
			}
		}
	}
}

// Frames are the frames the hub read after the hellos, oldest first.
func (h *scriptHub) Frames() []wire.Frame {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]wire.Frame(nil), h.frames...)
}

// Hellos are the hellos the hub read, oldest first.
func (h *scriptHub) Hellos() []wire.Frame {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]wire.Frame(nil), h.hellos...)
}

// hubCfg is a fresh box config pointed at url as box-a, with its keypair
// (fakehub's Wire, on any URL).
func hubCfg(t *testing.T, url string) *config.Config {
	t.Helper()
	cfg := testkit.NewConfig(t)
	(&fakehub.Hub{URL: url}).Wire(t, cfg, "box-a")
	return cfg
}

// laneAnswer answers a lane frame with lane = bodies[op]; an op it does not
// know gets a hub error.
func laneAnswer(bodies map[string]string) func(wire.Frame) []wire.Frame {
	return func(f wire.Frame) []wire.Frame {
		if f.Type != wire.TLane {
			return nil
		}
		b, ok := bodies[f.LaneOp]
		if !ok {
			return []wire.Frame{{Type: wire.TError, MsgID: f.MsgID, Error: "bad_lane_op", Status: 400}}
		}
		return []wire.Frame{{Type: wire.TLane, MsgID: f.MsgID, Lane: []byte(b)}}
	}
}

// capture runs fn with stdin fed from in and stdout, stderr captured.
func capture(t *testing.T, in string, fn func() int) (rc int, stdout, stderr string) {
	t.Helper()
	oldIn, oldOut, oldErr := os.Stdin, os.Stdout, os.Stderr
	defer func() { os.Stdin, os.Stdout, os.Stderr = oldIn, oldOut, oldErr }()
	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		io.Copy(inW, strings.NewReader(in)) //nolint:errcheck
		inW.Close()
	}()
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var ob, eb strings.Builder
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(&ob, outR) }() //nolint:errcheck
	go func() { defer wg.Done(); io.Copy(&eb, errR) }() //nolint:errcheck
	os.Stdin, os.Stdout, os.Stderr = inR, outW, errW
	rc = fn()
	outW.Close()
	errW.Close()
	wg.Wait()
	inR.Close()
	return rc, ob.String(), eb.String()
}
