package hub_test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-6514 (latency action 4): a box's hub link ended 315 times a day on the
// prd t1 desk, ~288 of them the hub's planned 1012 max-life close, and each
// end took the submit listener with it: sends in that gap were refused (23 a
// day), cold-dialled their own socket, or waited in pending/ for the 10 s
// scan tick (15 a day). Now the listener outlives the session, hub-run swaps
// sessions make-before-break, and a planned close is redialled at once.
//
// n sends go out of one box while its session is replaced under them; every
// send must ride the sidecar's session (no cold dial of the sender's own),
// none may be left pending, each must take under 1 s, and the receiving box
// must get all n.
func TestForcedReconnectLosesNoSend(t *testing.T) {
	for _, tc := range []struct {
		name            string
		maxLife, rotate time.Duration
	}{
		// the hub ends every socket at 1.2..1.5 s: the reactive path
		{"hub max-life close", 1500 * time.Millisecond, -1},
		// the box swaps first, every 400 ms: make before break
		{"make before break", 0, 400 * time.Millisecond},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t, func(o *hub.Options) { o.WSMaxLife = tc.maxLife })
			tid, _ := e.tenant()
			a := e.box(tid, "box-a", "GRK-03")
			b := e.box(tid, "box-b", "CLE-07")
			e.pin(tid, a)
			e.pin(tid, b)
			b.cfg.SubmitSocket = shortSocket(t)
			daemon := newSplit(e.client, e.client)
			b.c.HTTP = daemon.client()
			b.c.SessionProbe = -1
			b.c.RotateAfter = tc.rotate
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- b.c.Run(ctx) }()
			eventually(t, "the submit listener", func() bool { _, err := os.Stat(b.cfg.SubmitPath()); return err == nil })

			took, cold := sendThroughChurn(ctx, t, e, b)
			if d := daemon.dials.Load(); d < 2 {
				t.Fatalf("box sessions: %d, want >= 2 (the link must be replaced during the sends)", d)
			}
			if cold != 0 {
				t.Errorf("cold dials by the sender: %d, want 0 (every send rides the sidecar's session)", cold)
			}
			left, _ := filepath.Glob(filepath.Join(b.cfg.HubDir(), "pending", "*.json"))
			if len(left) != 0 {
				t.Errorf("pending after the sends: %d, want 0", len(left))
			}
			n := len(took)
			t.Logf("n=%d sessions=%d send p50=%v p95=%v max=%v", n, daemon.dials.Load(),
				took[n/2].Round(time.Millisecond), took[n*95/100].Round(time.Millisecond), took[n-1].Round(time.Millisecond))
			if took[n-1] >= time.Second {
				t.Errorf("slowest send %v, want under 1 s", took[n-1])
			}
			cancel()
			<-done
			if _, err := a.c.Sync(context.Background()); err != nil {
				t.Fatal(err)
			}
			if got := len(inbox(t, a, "GRK-03")); got != n {
				t.Fatalf("box-a received %d of %d sends", got, n)
			}
		})
	}
}

// sendThroughChurn sends 24 notes from b's CLE-07 to box-a, 100 ms apart, as
// `spool send` does (its own client, which offers each to the sidecar
// first). It returns the sorted send times and the sender's own upgrades.
func sendThroughChurn(ctx context.Context, t *testing.T, e *env, b *box) ([]time.Duration, int32) {
	t.Helper()
	const n = 24
	cli := hubclient.New(b.cfg)
	cli.ReadyTimeout = 5 * time.Second
	cold := newSplit(e.client, e.client)
	cli.HTTP = cold.client()
	took := make([]time.Duration, 0, n)
	for i := range n {
		start := time.Now()
		out, err := action.SendCtx(ctx, b.cfg, action.SendArgs{
			From: "CLE-07", To: "GRK-03", Kind: "note", Body: fmt.Sprintf("send %d", i), ToBox: "box-a", Hub: cli,
		})
		took = append(took, time.Since(start))
		if err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
		if out.Delivery == wire.DeliveryPending {
			t.Errorf("send %d left pending: it met a closed link", i)
		}
		time.Sleep(100 * time.Millisecond)
	}
	sort.Slice(took, func(i, j int) bool { return took[i] < took[j] })
	return took, cold.dials.Load()
}

// shortSocket is a unix socket path short enough for sun_path (108 bytes),
// which a t.TempDir() under a long TMPDIR is not.
func shortSocket(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "sk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "s")
}
