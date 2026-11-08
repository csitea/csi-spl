package hubclient

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestCloseAfterCancelSkipsHandshake: `timeout 4 spool lane` on a stalled
// link took 9 s to exit, n=6 (SPL-4631): the SIGTERM cancelled the context,
// and the deferred Session.Close then waited in the close handshake for a hub
// that never answers it. With the caller's context cancelled Close returns at
// once. The control: the same hub with the context alive still pays the
// handshake wait, so the silent hub really never answers the close.
func TestCloseAfterCancelSkipsHandshake(t *testing.T) {
	h := &silentHub{}
	c := testClient(t)
	c.Cfg.HubURL = h.start(t)
	c.Cfg.Tenant = "t1"

	ctx, cancel := context.WithCancel(context.Background())
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	cancel()
	start := time.Now()
	sess.Close()
	if d := time.Since(start); d >= time.Second {
		t.Fatalf("Close after a cancelled context took %s, want under 1 s: it waited in the close handshake", d)
	}

	if testing.Short() {
		return
	}
	h2 := &silentHub{} // silent on its first session only
	c.Cfg.HubURL = h2.start(t)
	live, stop := context.WithTimeout(context.Background(), 30*time.Second)
	defer stop()
	sess, err = c.Dial(live, wire.RoleCLI)
	if err != nil {
		t.Fatalf("control dial: %v", err)
	}
	start = time.Now()
	sess.Close()
	if d := time.Since(start); d < 4*time.Second {
		t.Fatalf("control: Close with a live context took %s, want the handshake wait (about 5 s): the hub answered the close", d)
	}
}
