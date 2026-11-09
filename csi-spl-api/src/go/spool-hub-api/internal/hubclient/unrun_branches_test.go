package hubclient

// Refactor round 29 row 06: the branches the coverage profile showed unrun.
// WaitQueueEnd's closed socket, cancelled context and timeout, sendFrame's
// announce and resend of a new agent's first line, and bootID on a host with
// no kernel boot id. Non-test code unchanged.

import (
	"context"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ubAgent is the sender compose stamps on every message.
const ubAgent = "GRK-03"

// ubHub refuses the first send as an unannounced sender and accepts the rest.
// It records every frame in arrival order, the announces fakeHub drops.
type ubHub struct {
	srv *httptest.Server
	// gone closes once the hub has read the socket to its end.
	gone chan struct{}

	mu     sync.Mutex
	frames []wire.Frame
}

func newUBHub(t *testing.T) *ubHub {
	t.Helper()
	h := &ubHub{gone: make(chan struct{})}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", h.serve)
	mux.HandleFunc("/v1/pins", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"pins":[]}`))
	})
	h.srv = httptest.NewServer(mux)
	t.Cleanup(h.srv.Close)
	return h
}

func (h *ubHub) serve(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer close(h.gone)
	defer conn.CloseNow() //nolint:errcheck
	ctx := context.Background()
	if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}); err != nil {
		return
	}
	var hello wire.Frame
	if err := wsjson.Read(ctx, conn, &hello); err != nil {
		return
	}
	if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID, UploadToken: "tok",
		UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}); err != nil {
		return
	}
	for {
		var f wire.Frame
		if err := wsjson.Read(ctx, conn, &f); err != nil {
			return
		}
		sends := h.record(f)
		if f.Type != wire.TSend {
			continue
		}
		out := wire.Frame{Type: wire.TSent, MsgID: wire.InnerMsgID(f.Env), Delivery: wire.DeliverySent}
		if sends == 1 {
			out = *srNotAnnounced()
			out.MsgID = wire.InnerMsgID(f.Env)
		}
		if err := wsjson.Write(ctx, conn, out); err != nil {
			return
		}
	}
}

// record keeps f and returns how many sends the hub has seen.
func (h *ubHub) record(f wire.Frame) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.frames = append(h.frames, f)
	n := 0
	for _, g := range h.frames {
		if g.Type == wire.TSend {
			n++
		}
	}
	return n
}

// types is the type of each recorded frame, in arrival order.
func (h *ubHub) types() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]string, 0, len(h.frames))
	for _, f := range h.frames {
		out = append(out, f.Type)
	}
	return out
}

// ubClient is a client of h on whose box ubAgent has a mailbox.
func ubClient(t *testing.T, h *ubHub) *Client {
	t.Helper()
	c := testClient(t)
	c.Cfg.HubURL = h.srv.URL
	c.Cfg.Tenant = "t1"
	c.ReadyTimeout = 10 * time.Second
	if err := os.MkdirAll(filepath.Join(c.Cfg.SpoolRoot, ubAgent), 0o755); err != nil {
		t.Fatal(err)
	}
	return c
}

// ubWaiter is a session waiting for queue_end that never comes, with no socket
// behind it: exactly one arm of the select is ready in each case below.
func ubWaiter(ready time.Duration) *Session {
	return &Session{c: &Client{ReadyTimeout: ready}, queueEnd: make(chan int), done: make(chan struct{})}
}

func TestUBWaitQueueEndSocketClosed(t *testing.T) {
	s := ubWaiter(time.Hour)
	close(s.done)
	n, err := s.WaitQueueEnd(context.Background())
	if !errors.Is(err, ErrUnreachable) || n != 0 {
		t.Fatalf("n %d err %v, want 0 and ErrUnreachable", n, err)
	}
}

func TestUBWaitQueueEndContextCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	n, err := ubWaiter(time.Hour).WaitQueueEnd(ctx)
	if !errors.Is(err, context.Canceled) || errors.Is(err, ErrUnreachable) || n != 0 {
		t.Fatalf("n %d err %v, want 0 and context.Canceled alone", n, err)
	}
}

func TestUBWaitQueueEndTimeout(t *testing.T) {
	n, err := ubWaiter(10 * time.Millisecond).WaitQueueEnd(context.Background())
	if !errors.Is(err, ErrUnreachable) || n != 0 {
		t.Fatalf("n %d err %v, want 0 and ErrUnreachable", n, err)
	}
}

// A new agent's first line beat the announce scan: one announce naming it, one
// resend of the same envelope, and the caller gets the second answer.
func TestUBSendFrameAnnouncesAndResends(t *testing.T) {
	h := newUBHub(t)
	c := ubClient(t, h)
	m, env, _ := srPending(t, c, "first line")
	s := srSession(t, c, wire.RoleBox)
	f, err := s.sendFrame(context.Background(), env, wire.Frame{})
	if err != nil || f.Type != wire.TSent || f.MsgID != m.MsgID {
		t.Fatalf("frame %+v err %v, want the sent frame of %s", f, err, m.MsgID)
	}
	want := []string{wire.TSend, wire.TAnnounce, wire.TSend}
	if got := h.types(); !reflect.DeepEqual(got, want) {
		t.Fatalf("hub read %v, want %v", got, want)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if !slices.Contains(h.frames[1].Agents, ubAgent) {
		t.Fatalf("announce lists %v, want %s in it", h.frames[1].Agents, ubAgent)
	}
	if string(h.frames[0].Env) != string(h.frames[2].Env) {
		t.Fatal("the resend carries a different envelope")
	}
}

// The announce cannot be written: no resend, and the caller keeps the hub's
// refusal. AgentRun runs inside Announce, after both agent scans and before the
// write, so closing the socket there fails exactly that write.
func TestUBSendFrameFailedAnnounceNoResend(t *testing.T) {
	h := newUBHub(t)
	c := ubClient(t, h)
	_, env, _ := srPending(t, c, "first line")
	s := srSession(t, c, wire.RoleBox)
	c.AgentRun = func([]string) map[string]bool {
		s.conn.CloseNow() //nolint:errcheck
		return nil
	}
	_, err := s.sendFrame(context.Background(), env, wire.Frame{})
	var he *HubError
	if !errors.As(err, &he) || he.Token != wire.TokenFromNotAnnounced {
		t.Fatalf("err %v, want the hub's %s", err, wire.TokenFromNotAnnounced)
	}
	select {
	case <-h.gone:
	case <-time.After(10 * time.Second):
		t.Fatal("hub never saw the socket end")
	}
	if got, want := h.types(), []string{wire.TSend}; !reflect.DeepEqual(got, want) {
		t.Fatalf("hub read %v, want %v", got, want)
	}
}

// A host with no kernel boot id gets a random id, kept for this Client's life.
func TestUBBootIDRandomWhenPathMissing(t *testing.T) {
	old := bootIDPath
	t.Cleanup(func() { bootIDPath = old })
	bootIDPath = filepath.Join(t.TempDir(), "no-such-boot-id")
	c, other := &Client{}, &Client{}
	first := c.bootID()
	if b, err := hex.DecodeString(first); err != nil || len(b) != 16 {
		t.Fatalf("boot id %q is not 16 random hex bytes (err %v)", first, err)
	}
	if again := c.bootID(); again != first {
		t.Fatalf("second call %q, first %q", again, first)
	}
	if o := other.bootID(); o == first {
		t.Fatalf("two clients drew the same id %q", o)
	}
}
