package store

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"sync"
	"testing"
	"time"
)

// SPL-2238 (prd outage 2026-10-16): SetRoster's cold agent_seats probe took a
// second pool connection while its own transaction held the first, so a pool
// of N with N hellos in flight on a fresh process waited forever. A fresh
// Postgres has a cold probe; a pool of one leaves no second connection.
func TestSetRosterColdProbeOneConnPool(t *testing.T) {
	pg, ok := claimKeyDrivers(t, 1)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	tid := seatedTenant(t, pg, "box-a")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := pg.SetRoster(ctx, tid, "box-a", []string{"c-004"}, time.Now().UTC()); err != nil {
		t.Fatalf("SetRoster on a cold probe with a one-connection pool: %v", err)
	}
	if !pg.seats.ok {
		t.Fatal("control: the probe never saw agent_seats, so the cold path was not taken")
	}
}

// N concurrent SetRoster calls on N tenants with a pool of N, every probe
// cold: each holds one connection and none may wait for another.
func TestSetRosterColdProbeConcurrent(t *testing.T) {
	const n = 4
	pg, ok := claimKeyDrivers(t, n)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	tids := make([]string, n)
	for i := range tids {
		tids[i] = seatedTenant(t, pg, "box-a")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	start := make(chan struct{})
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i, tid := range tids {
		wg.Add(1)
		go func(i int, tid string) {
			defer wg.Done()
			<-start
			errs[i] = pg.SetRoster(ctx, tid, "box-a", []string{fmt.Sprintf("c-%03d", i+10)}, time.Now().UTC())
		}(i, tid)
	}
	close(start)
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("SetRoster %d of %d (pool %d, cold probe): %v", i+1, n, n, err)
		}
	}
}

// seatedTenant is a new tenant with box pinned (SetRoster's seat gate).
func seatedTenant(t *testing.T, pg *Postgres, box string) string {
	t.Helper()
	tid := newTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := pg.PutPin(context.Background(), tid, box, pub, false, now, now); err != nil {
		t.Fatal(err)
	}
	return tid
}
