package hubclient

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// The daemon under a hub that answers every upgrade 429 (prd 2026-10-11
// 16:12-16:28Z, Cloud Run "no available instance"): each attempt is ONE
// upgrade, and no two upgrades are closer than half the first ceiling, so 23
// desks on a box cannot hot-loop the front. The jitter is pinned to the
// bottom of its range, the worst case for spacing. Before the fix the daemon
// stacked the single-shot dial retry inside its own full-jitter backoff: with
// that draw at 0 the upgrades came back to back.
func TestRunBacksOffOn429NoHotLoop(t *testing.T) {
	b, m, j := runBackoffBase, runBackoffMax, jitter
	runBackoffBase, runBackoffMax = 20*time.Millisecond, 80*time.Millisecond
	jitter = func(int64) int64 { return 0 }
	t.Cleanup(func() { runBackoffBase, runBackoffMax, jitter = b, m, j })
	withDialBudget(t, 2, time.Millisecond, time.Millisecond, time.Millisecond, false)
	jitter = func(int64) int64 { return 0 }

	h := &busyHub{busy: 1 << 30, status: http.StatusTooManyRequests}
	c := testClient(t)
	c.Cfg.HubURL = h.start(t)
	c.Cfg.Tenant = "t1"
	c.Cfg.SubmitSocket = "off"
	ctx, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer cancel()
	if err := c.Run(ctx); err != nil {
		t.Fatalf("Run: %v", err)
	}

	gaps := h.gaps()
	if len(gaps) < 2 {
		t.Fatalf("only %d upgrades in 600 ms: the test did not exercise the loop", len(gaps)+1)
	}
	floor := runBackoffBase / 2
	for i, g := range gaps {
		if g < floor {
			t.Fatalf("upgrade %d came %v after the previous one, under the %v floor: a hot retry (%d upgrades in 600 ms)", i+1, g, floor, len(gaps)+1)
		}
	}
	// waits 10, 20, 40, 40, ... ms: at most ~16 upgrades fit in 600 ms
	if n := len(gaps) + 1; n > 20 {
		t.Fatalf("%d upgrades in 600 ms: the backoff does not grow", n)
	}
}

// Equal jitter: every draw lies in [ceiling/2, ceiling], the ceiling still
// doubles to the cap, and the draws are spread.
func TestBackoffHalfJitterFloor(t *testing.T) {
	b := newBackoff(time.Second, time.Minute, time.Minute)
	b.half = true
	b.rnd = func(int64) int64 { return 0 }
	want := []time.Duration{500, 1000, 2000, 4000, 8000, 16000, 30000, 30000}
	for i, w := range want {
		if got := b.next(0); got != w*time.Millisecond {
			t.Fatalf("bottom wait %d = %v, want %v", i, got, w*time.Millisecond)
		}
	}
	seen := map[time.Duration]bool{}
	for range 200 {
		r := newBackoff(time.Second, time.Minute, time.Minute)
		r.half = true
		r.n = 3 // ceiling 8 s
		d := r.next(0)
		if d < 4*time.Second || d > 8*time.Second {
			t.Fatalf("draw %v outside [4s, 8s]", d)
		}
		seen[d] = true
	}
	if len(seen) < 100 {
		t.Fatalf("jitter not spread: %d distinct of 200", len(seen))
	}
}
