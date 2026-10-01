package store

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// CLE-77911 (rdb 0094): the fleet-wide lease is a compare-and-set on gen, with
// the age read from the hub's clock. Run on Memory and Postgres. Each step is
// a control: drop the gen condition in CASFleetLease and the stale write, the
// second first-write and the race all turn red.
func TestFleetLeaseCAS(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 1, 19, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			other := newTenant(t, st)

			l, err := st.GetFleetLease(ctx, tid, "main", "dispatch", t0)
			if err != nil || l.Gen != 0 || l.Holder != "" {
				t.Fatalf("no row: %+v %v", l, err)
			}
			// first write: if_gen 0
			l, err = st.CASFleetLease(ctx, tid, "main", "dispatch", "pc:CLE-002", "box-desk", 0, t0)
			if err != nil || l.Gen != 1 || l.Holder != "pc:CLE-002" || l.Box != "box-desk" {
				t.Fatalf("first write: %+v %v", l, err)
			}
			// a second first-write loses and gets the current row back
			l, err = st.CASFleetLease(ctx, tid, "main", "dispatch", "sat:CLE-102", "box-sat", 0, t0)
			if !errors.Is(err, ErrConflict) || l.Gen != 1 || l.Holder != "pc:CLE-002" {
				t.Fatalf("second first-write: %+v %v", l, err)
			}
			// renew on the gen read
			l, err = st.CASFleetLease(ctx, tid, "main", "dispatch", "pc:CLE-002", "box-desk", 1, t0.Add(60*time.Second))
			if err != nil || l.Gen != 2 {
				t.Fatalf("renew: %+v %v", l, err)
			}
			// age on the given (hub) clock
			l, err = st.GetFleetLease(ctx, tid, "main", "dispatch", t0.Add(300*time.Second))
			if err != nil || l.Age != 240*time.Second || l.Gen != 2 {
				t.Fatalf("age: %+v %v", l, err)
			}
			// a stale gen loses
			if _, err = st.CASFleetLease(ctx, tid, "main", "dispatch", "sat:CLE-102", "box-sat", 1, t0.Add(300*time.Second)); !errors.Is(err, ErrConflict) {
				t.Fatalf("stale gen: %v", err)
			}
			// takeover on the current gen
			l, err = st.CASFleetLease(ctx, tid, "main", "dispatch", "sat:CLE-102", "box-sat", 2, t0.Add(300*time.Second))
			if err != nil || l.Gen != 3 || l.Holder != "sat:CLE-102" || l.Box != "box-sat" || l.Age != 0 {
				t.Fatalf("takeover: %+v %v", l, err)
			}
			// roles and tenants are separate leases
			if l, _ := st.GetFleetLease(ctx, tid, "main", "orch", t0); l.Gen != 0 {
				t.Fatalf("orch saw dispatch: %+v", l)
			}
			if l, _ := st.GetFleetLease(ctx, other, "main", "dispatch", t0); l.Gen != 0 {
				t.Fatalf("other tenant saw it: %+v", l)
			}

			// two machines race on the same gen: exactly one wins
			var wg sync.WaitGroup
			wins := make(chan string, 2)
			for _, h := range []string{"pc:CLE-001", "sat:CLE-101"} {
				wg.Add(1)
				go func(h string) {
					defer wg.Done()
					if _, err := st.CASFleetLease(ctx, tid, "main", "orch", h, "b", 0, t0); err == nil {
						wins <- h
					} else if !errors.Is(err, ErrConflict) {
						t.Errorf("race %s: %v", h, err)
					}
				}(h)
			}
			wg.Wait()
			close(wins)
			if n := len(wins); n != 1 {
				t.Fatalf("race winners %d, want 1", n)
			}
		})
	}
}
