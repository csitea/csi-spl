package hub_test

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// spec 059 §11 S3: two hub processes on one store, a browser on each. A line
// stored through process A (a browser send, then a box agent's send) reaches
// the browser on process B through the store's announcement; A's own browser
// gets it once, not again from the announcement. The control runs the same
// sends with B's WUI wake-up off: B's browser gets nothing.

func newWUIWakePeer(t *testing.T, st *env, wake bool) *env {
	t.Helper()
	srv, err := hub.New(hub.Options{
		Store: st.st, Blob: blob.Dir{Root: st.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-peer",
		ViewDoor: hub.ViewDoorOff, LobbyTaskID: lobby, ViewCORSOrigins: []string{wuiOrigin},
		WakeWUI: wake,
	})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	ctx, cancel := context.WithCancel(context.Background())
	go srv.RunWake(ctx)
	t.Cleanup(func() { cancel(); srv.Shutdown(); ts.Close() })
	addr := ts.Listener.Addr().String()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	time.Sleep(300 * time.Millisecond) // the listener is up before the first send
	return &env{t: t, st: st.st, srv: srv, ts: ts, client: &http.Client{Transport: tr}, blobs: st.blobs}
}

// wuiWakeRig: process A (wake on, so its own announcement comes back to it)
// and the peer B, a browser subscribed to the lobby on each, and a box agent
// connected to A.
func wuiWakeRig(t *testing.T, peerWake bool) (onA, onB *wuiClient, send func(body string)) {
	t.Helper()
	a := newEnv(t, func(o *hub.Options) {
		o.ViewDoor, o.LobbyTaskID, o.ViewCORSOrigins, o.WakeWUI = hub.ViewDoorOff, lobby, []string{wuiOrigin}, true
	})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go a.srv.RunWake(ctx)
	b := newWUIWakePeer(t, a, peerWake)
	tid, _ := a.tenant()
	agent := a.box(tid, "box-a", "GRK-03")
	a.pin(tid, agent)
	if _, err := agent.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	onA, onB = dialWUI(t, a, tid, "HUM-1"), dialWUI(t, b, tid, "HUM-2")
	for _, w := range []*wuiClient{onA, onB} {
		w.send(map[string]string{"type": "subscribe", "task_id": "lobby"})
		w.read("subscribed")
	}
	return onA, onB, func(body string) {
		if body == "from a box" {
			out, err := action.SendCtx(ctx, agent.cfg, action.SendArgs{From: "GRK-03", To: hub.BroadcastID, ToBox: hub.WUIBox,
				TaskID: lobby, Kind: "note", Body: body, Hub: agent.c})
			if err != nil || out.Delivery != wire.DeliverySent {
				t.Fatalf("agent lobby send: %v %+v", err, out)
			}
			return
		}
		// the ack is not read here: A's echo precedes it, and messages() counts it
		onA.send(map[string]any{"type": "send", "task_id": "lobby", "kind": "chat", "body": body})
	}
}

// messages reads every message frame w gets within d.
func (w *wuiClient) messages(d time.Duration) []string {
	w.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	var out []string
	for {
		var f wuiFrame
		if err := wsjson.Read(ctx, w.c, &f); err != nil {
			return out
		}
		if f.Type == "message" {
			out = append(out, innerOf(w.t, f)["body"].(string))
		}
	}
}

func TestWUIWakeFansOutAcrossProcesses(t *testing.T) {
	onA, onB, send := wuiWakeRig(t, true)
	start := time.Now()
	send("from a browser")
	if m := innerOf(t, onB.read("message")); m["body"] != "from a browser" {
		t.Fatalf("browser on B got %v", m)
	}
	send("from a box")
	if m := innerOf(t, onB.read("message")); m["body"] != "from a box" {
		t.Fatalf("browser on B got %v", m)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("took %v", d)
	}
	// A's own browser: each line once (its echo before the ack, then the
	// box line); the announcement A hears back adds nothing.
	if got := onA.messages(700 * time.Millisecond); len(got) != 2 || got[0] != "from a browser" || got[1] != "from a box" {
		t.Fatalf("browser on A got %q, want each line once", got)
	}
	if got := onB.messages(300 * time.Millisecond); len(got) != 0 {
		t.Fatalf("browser on B got %q more", got)
	}
}

func TestWUIWakeOffStaysOnTheStoringProcess(t *testing.T) { // CONTROL
	onA, onB, send := wuiWakeRig(t, false)
	send("from a browser")
	send("from a box")
	if got := onA.messages(500 * time.Millisecond); len(got) != 2 {
		t.Fatalf("browser on A got %q, want both lines", got)
	}
	if got := onB.messages(500 * time.Millisecond); len(got) != 0 {
		t.Fatalf("browser on B got %q with its WUI wake-up off", got)
	}
}
