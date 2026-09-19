package store

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"
)

// TestEnqueueConcurrentCap (027 T040): concurrent sends to one box over its
// cap. Before the per-box cap lock, the cap UPDATEs deadlocked each other and
// the hub answered 500 (measured on pg16). CONTROL: every Enqueue succeeds,
// and one more sequential send leaves exactly the cap queued, newest kept.
func TestEnqueueConcurrentCap(t *testing.T) {
	const capN, workers, perWorker = 20, 16, 40
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			ttl := now.Add(time.Hour)
			var wg sync.WaitGroup
			errs := make(chan error, workers*perWorker)
			for w := 0; w < workers; w++ {
				wg.Add(1)
				go func(w int) {
					defer wg.Done()
					for i := 0; i < perWorker; i++ {
						at := now.Add(time.Duration(w*perWorker+i) * time.Millisecond)
						m := msgFor(tid, uuid4(), "box-q", at, at, fmt.Sprintf(`{"w":%d,"i":%d}`, w, i))
						if _, err := s.InsertMessage(ctx, m); err != nil {
							errs <- err
							return
						}
						if err := s.Enqueue(ctx, tid, m.MsgID, "box-q", at, ttl, capN); err != nil {
							errs <- err
							return
						}
					}
				}(w)
			}
			wg.Wait()
			close(errs)
			for err := range errs {
				t.Fatalf("concurrent enqueue over the cap: %v", err)
			}
			// A send that finds the cap lock held skips its trim, so right
			// after the burst the queue may exceed the cap by the sends that
			// committed while the last trim held the lock. That window, not
			// the burst, bounds it: never the whole burst accumulating.
			burst, err := s.QueuedFor(ctx, tid, "box-q", now)
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("queued right after %d concurrent sends: %d (cap %d)", workers*perWorker, len(burst), capN)
			if over := len(burst) - capN; over > workers*perWorker/4 {
				t.Fatalf("overshoot %d of %d sends: the cap is not trimming during the burst", over, workers*perWorker)
			}
			last := now.Add(time.Hour / 2)
			m := msgFor(tid, uuid4(), "box-q", last, last, `{"last":1}`)
			if _, err := s.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
			if err := s.Enqueue(ctx, tid, m.MsgID, "box-q", last, ttl, capN); err != nil {
				t.Fatal(err)
			}
			q, err := s.QueuedFor(ctx, tid, "box-q", now)
			if err != nil {
				t.Fatal(err)
			}
			if len(q) != capN {
				t.Fatalf("queued %d after a sequential send, want the cap %d", len(q), capN)
			}
			if q[len(q)-1].MsgID != m.MsgID {
				t.Fatalf("newest queued is %s, want the last send %s", q[len(q)-1].MsgID, m.MsgID)
			}
		})
	}
}
