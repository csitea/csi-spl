package hub_test

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// spec 059 §11 S1: two hub processes on one store. The box sits on the peer;
// a message stored by the first process reaches it through the wake-up, with
// no relay tick. The control runs the same send with the wake-up off: the row
// stays queued until a relay tick.

func newWakePeer(t *testing.T, e *env, wake bool) (*hub.Server, *http.Client) {
	t.Helper()
	srv, err := hub.New(hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-peer",
		Wake: wake,
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
	return srv, &http.Client{Transport: tr}
}

func wakeRig(t *testing.T, wake bool) (*env, *hub.Server, *box, *box) {
	t.Helper()
	e := newEnv(t)
	tid, _ := e.tenant()
	sender := e.box(tid, "box-s", "GRK-03")
	desk := e.box(tid, "box-desk", "CLE-07")
	e.pin(tid, sender)
	e.pin(tid, desk)
	peer, client := newWakePeer(t, e, wake)
	desk.c.HTTP = client
	s, err := desk.c.Dial(context.Background(), wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return e, peer, sender, desk
}

func TestWakePushesAcrossProcesses(t *testing.T) {
	_, _, sender, desk := wakeRig(t, true)
	for i, body := range []string{"one", "two", "three"} {
		// queued, or already sent when the peer's wake-up won the race
		if out := send(t, sender, "GRK-03", "CLE-07", "note", body, "box-desk"); out.Delivery != wire.DeliveryQueued && out.Delivery != wire.DeliverySent {
			t.Fatalf("send %d: %q", i, out.Delivery)
		}
	}
	// The clock starts after the sends: it times the wake-up, not three sends
	// under -race on a loaded runner (wf 10 run 37991567317: 2.11 s for all).
	start := time.Now()
	eventually(t, "all three on the peer's box without a relay tick", func() bool {
		return len(inbox(t, desk, "CLE-07")) == 3
	})
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("took %v; the wake-up should beat the 5 s relay tick", d)
	}
	time.Sleep(200 * time.Millisecond)
	if n := len(inbox(t, desk, "CLE-07")); n != 3 {
		t.Fatalf("inbox %d after the wake-ups settled, want 3 (no double push)", n)
	}
}

func TestWakeOffWaitsForTheRelay(t *testing.T) { // CONTROL
	_, peer, sender, desk := wakeRig(t, false)
	if out := send(t, sender, "GRK-03", "CLE-07", "note", "one", "box-desk"); out.Delivery != wire.DeliveryQueued {
		t.Fatalf("send: %q, want queued", out.Delivery)
	}
	notWithin(t, 500*time.Millisecond, "a delivery with the wake-up off", func() bool {
		return len(inbox(t, desk, "CLE-07")) > 0
	})
	peer.Relay(context.Background())
	eventually(t, "the relay tick delivers it", func() bool { return len(inbox(t, desk, "CLE-07")) == 1 })
}
