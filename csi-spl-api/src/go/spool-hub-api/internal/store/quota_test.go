package store

import (
	"context"
	"sync"
	"testing"
	"time"
)

// rdb 0127 (specs/077 3.7): a take counts up to limit and refuses the next
// without writing; counters are per (tenant, human, kind, window). Run on
// Memory and Postgres. CONTROL: 30 concurrent takes on a limit of 20 take
// exactly 20 - drop the WHERE n < limit and they all succeed.
func TestQuotaCounter(t *testing.T) {
	ctx := context.Background()
	w := time.Date(2026, 10, 5, 7, 0, 0, 123456000, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			qc := st.(QuotaCounter)
			tid, other := newTenant(t, st), newTenant(t, st)
			for i := 1; i <= 3; i++ {
				if n, ok, err := qc.TakeQuota(ctx, tid, "HUM-a", "agent_turn", w, 3); err != nil || !ok || n != i {
					t.Fatalf("take %d: %d %v %v", i, n, ok, err)
				}
			}
			if n, ok, err := qc.TakeQuota(ctx, tid, "HUM-a", "agent_turn", w, 3); err != nil || ok || n != 3 {
				t.Fatalf("4th take on limit 3: %d %v %v", n, ok, err)
			}
			// Raising the limit continues from the stored count: the refusal wrote nothing.
			if n, ok, err := qc.TakeQuota(ctx, tid, "HUM-a", "agent_turn", w, 4); err != nil || !ok || n != 4 {
				t.Fatalf("take on limit 4: %d %v %v", n, ok, err)
			}
			for what, k := range map[string]struct {
				tenant, human, kind string
				window              time.Time
			}{
				"another human":  {tid, "HUM-b", "agent_turn", w},
				"another kind":   {tid, "HUM-a", "post_min", w},
				"another window": {tid, "HUM-a", "agent_turn", w.Add(time.Second)},
				"another tenant": {other, "HUM-a", "agent_turn", w},
			} {
				if n, ok, err := qc.TakeQuota(ctx, k.tenant, k.human, k.kind, k.window, 3); err != nil || !ok || n != 1 {
					t.Fatalf("%s: %d %v %v", what, n, ok, err)
				}
			}
			if _, ok, err := qc.TakeQuota(ctx, tid, "HUM-c", "agent_turn", w, 0); err != nil || ok {
				t.Fatalf("limit 0 must refuse: %v %v", ok, err)
			}
			if _, _, err := qc.TakeQuota(ctx, tid, "", "agent_turn", w, 3); err == nil {
				t.Fatal("empty human taken")
			}

			var wg sync.WaitGroup
			var mu sync.Mutex
			taken := 0
			for range 30 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					_, ok, err := qc.TakeQuota(ctx, tid, "HUM-race", "agent_turn", w, 20)
					if err != nil {
						t.Error(err)
					}
					if ok {
						mu.Lock()
						taken++
						mu.Unlock()
					}
				}()
			}
			wg.Wait()
			if taken != 20 {
				t.Fatalf("CONTROL: 30 racing takes on limit 20 took %d", taken)
			}
		})
	}
}

// MemberSince is the membership's created_at, ErrNotFound for a non-member.
func TestQuotaMemberSince(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			qc, h := st.(QuotaCounter), st.(Humans)
			tid := newTenant(t, st)
			hum, err := h.Admit(ctx, Identity{Provider: "google", Subject: "sub-" + tid, Email: tid + "@example.com"},
				tid, AdmitPolicy{BootstrapOwner: true}, now)
			if err != nil {
				t.Fatal(err)
			}
			if since, err := qc.MemberSince(ctx, tid, hum); err != nil || !since.Equal(now) {
				t.Fatalf("since %v %v, want %v", since, err, now)
			}
			if _, err := qc.MemberSince(ctx, tid, "HUM-nobody"); err != ErrNotFound {
				t.Fatalf("non-member: %v", err)
			}
		})
	}
}
