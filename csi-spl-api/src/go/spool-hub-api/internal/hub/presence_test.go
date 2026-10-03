package hub_test

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// newPeer is a second hub instance on e's store (another Cloud Run instance,
// or the next revision of a roll): nobody's socket is on it.
func newPeer(t *testing.T, e *env, mut ...func(*hub.Options)) *env {
	t.Helper()
	o := hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-peer",
	}
	for _, m := range mut {
		m(&o)
	}
	srv, err := hub.New(o)
	if err != nil {
		t.Fatal(err)
	}
	p := &env{t: t, st: e.st, srv: srv, blobs: e.blobs, ts: httptest.NewServer(srv.Handler())}
	t.Cleanup(func() { srv.Shutdown(); p.ts.Close() })
	addr := p.ts.Listener.Addr().String()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	p.client = &http.Client{Transport: tr}
	return p
}

// rosterOnline is GET /v1/view/roster's online flag per box.
func rosterOnline(t *testing.T, e *env, tenant string) map[string]bool {
	t.Helper()
	code, _, body := viewGet(t, e, tenant, "/v1/view/roster")
	var r struct {
		Boxes []struct {
			BoxID  string `json:"box_id"`
			Online bool   `json:"online"`
		} `json:"boxes"`
	}
	if err := json.Unmarshal(body, &r); err != nil || code != 200 {
		t.Fatalf("roster %d %s", code, body)
	}
	out := map[string]bool{}
	for _, b := range r.Boxes {
		out[b.BoxID] = b.Online
	}
	return out
}

// connectBox says hello as a role=box socket on e and keeps reading (so pings
// are answered) until the test ends or the socket is closed.
func connectBox(t *testing.T, e *env, tenant string, b *box, agents ...string) *websocket.Conn {
	t.Helper()
	ctx := context.Background()
	c, n := e.raw(tenant)
	h := helloFrame(b, n, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents = agents
	wsjson.Write(ctx, c, h) //nolint:errcheck
	var wel wire.Frame
	if err := wsjson.Read(ctx, c, &wel); err != nil || wel.Type != wire.TWelcome {
		t.Fatalf("welcome %v %+v", err, wel)
	}
	go func() {
		for {
			if _, _, err := c.Read(ctx); err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() { c.CloseNow() }) //nolint:errcheck
	return c
}

// t1 b3bf3d13: after every hub roll every machine read OFFLINE, because
// online meant "this instance holds the socket" and the roster is read from
// the new revision while the sockets sit on the old one. Presence is now the
// shared stamp: a box on instance A reads online from instance B, and a box
// silent past the TTL reads offline everywhere.
func TestBoxPresenceAcrossInstances(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	quiet := e.box(tid, "box-q", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, quiet) // pinned, never connected
	var skew atomic.Int64
	peer := newPeer(t, e, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.Now = func() time.Time { return time.Now().Add(time.Duration(skew.Load())) }
	})

	c := connectBox(t, e, tid, a, "GRK-03")
	if on := rosterOnline(t, e, tid); !on["box-a"] || on["box-q"] {
		t.Fatalf("instance A (holds the socket): %v", on)
	}
	if on := rosterOnline(t, peer, tid); !on["box-a"] {
		t.Fatalf("box-a connected to instance A reads offline from instance B: %v", on)
	}
	if on := rosterOnline(t, peer, tid); on["box-q"] {
		t.Fatalf("a pinned box that never said hello reads online: %v", on)
	}

	// Silent past the TTL (A's 30 s stamp never ticks inside this test):
	// offline on B, while A, which holds the socket, still says online.
	skew.Store(int64(61 * time.Second))
	if on := rosterOnline(t, peer, tid); on["box-a"] {
		t.Fatalf("box-a silent past the TTL still reads online on B: %v", on)
	}
	skew.Store(0)

	// A real disconnect reads offline at once where it happened, not a TTL later.
	c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	deadline := time.Now().Add(2 * time.Second)
	for rosterOnline(t, e, tid)["box-a"] {
		if time.Now().After(deadline) {
			t.Fatal("box-a still online on A after its socket closed")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// ... and a redial (here onto B) reads online on both again.
	connectBox(t, peer, tid, a, "GRK-03")
	if !rosterOnline(t, e, tid)["box-a"] || !rosterOnline(t, peer, tid)["box-a"] {
		t.Fatal("box-a redialled onto B but does not read online everywhere")
	}
}

// The instance holding the socket re-stamps the box once per ping interval,
// so a long-lived socket stays fresh for every other instance.
func TestBoxPresenceStampRefreshes(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.PingInterval, o.PingTimeout = 30*time.Millisecond, time.Second
	})
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	ctx := context.Background()
	hello := func() time.Time {
		bs, err := e.st.ViewBoxes(ctx, tid)
		if err != nil || len(bs) != 1 {
			t.Fatalf("boxes %v %v", bs, err)
		}
		return bs[0].LastHelloAt
	}
	connectBox(t, e, tid, a, "GRK-03")
	first := hello()
	deadline := time.Now().Add(2 * time.Second)
	for !hello().After(first) {
		if time.Now().After(deadline) {
			t.Fatalf("last_hello_at never refreshed past %v while the socket lived", first)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
