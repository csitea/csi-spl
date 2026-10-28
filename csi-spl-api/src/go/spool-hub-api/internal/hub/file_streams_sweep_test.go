package hub_test

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestFileStreamsSweeperRunsTheRetention (spec 160 row B6, case C22's hub
// half): a sweeper tick runs the file streams retention, so lines 8 days old
// are gone without a push. The store side (expiry, caps, counts, Postgres)
// is store.TestFileStreamSweep. CONTROL: RunSweeper without
// s.sweepFileStreams keeps the 3 lines and the wait times out.
func TestFileStreamsSweeperRunsTheRetention(t *testing.T) {
	var clock atomic.Int64
	clock.Store(time.Now().UnixNano())
	r := newFSRig(t, store.FileStreamLimits{}, func(o *hub.Options) {
		o.Now = func() time.Time { return time.Unix(0, clock.Load()) }
	})
	if _, ok := r.e.st.(*store.Memory); !ok {
		t.Skip("memory only: on the shared Postgres test database a sweep 8 days ahead would delete other runs' lines")
	}
	if _, err := r.lane(t, r.a, wire.FileStreamsAnnounceOp, fsAnnounce("app")); err != nil {
		t.Fatal(err)
	}
	if _, err := r.lane(t, r.a, wire.FileStreamsPushOp, fsPushBody("app", 1, 3, time.Now())); err != nil {
		t.Fatal(err)
	}
	if ls := r.lines(t, r.w, "app"); len(ls) != 3 {
		t.Fatalf("stored %d lines, want 3", len(ls))
	}
	clock.Add(int64(8 * 24 * time.Hour))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.e.srv.RunSweeper(ctx, 10*time.Millisecond)
	deadline := time.Now().Add(5 * time.Second)
	for len(r.lines(t, r.w, "app")) > 0 {
		if time.Now().After(deadline) {
			t.Fatalf("8-day-old lines still kept after 5 s of sweeper ticks: %d", len(r.lines(t, r.w, "app")))
		}
		time.Sleep(20 * time.Millisecond)
	}
}
