package store

// perf edition 20261004 E02: the read-marks write locks its rows in one
// order, so two clients of ONE member (the web app and the phone, each
// pushing every 5 s and on tab hide: csi-spl-wui/src/utils/read-sync.mjs)
// never deadlock each other, and the write and the read each cost one round
// trip. Skipped without SPOOL_TEST_PG_DSN (the memory store has one mutex).
//
//	SPOOL_TEST_PG_DSN=... go test ./internal/store -run 'TestSaveReadMarks(LockOrder|RoundTrips)' -v

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"sort"
	"sync"
	"testing"
	"time"
)

// TestSaveReadMarksLockOrder: 32 concurrent writes of one member, each with
// an overlapping slice of 60 shared keys, and every one of them stores. A
// write that ranges the Go map in random order locks the same rows in
// different orders and gets "deadlock detected (40P01)" (prd 2026-10-04:
// 47 x HTTP 500 in 24 h).
func TestSaveReadMarksLockOrder(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)
	keys := make([]string, 60)
	for i := range keys {
		keys[i] = fmt.Sprintf("ch:c%02d", i)
	}
	const writers, rounds = 32, 4
	for r := 0; r < rounds; r++ {
		var wg sync.WaitGroup
		errs := make(chan error, writers)
		for w := 0; w < writers; w++ {
			marks := map[string]ReadMark{}
			for i := 0; i < 40; i++ { // writer w covers keys w..w+39, wrapped
				at := now.Add(time.Duration(r*writers+w) * time.Millisecond)
				marks[keys[(w+i)%len(keys)]] = ReadMark{At: at, MsgID: fmt.Sprintf("m%03d", r*writers+w), Seen: w}
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				errs <- pg.SaveReadMarks(ctx, tid, "HUM-1", marks, now)
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			if err != nil {
				t.Fatalf("round %d: concurrent SaveReadMarks of one member: %v", r, err)
			}
		}
	}
	got, err := pg.ReadMarksOf(ctx, tid, "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(keys) {
		t.Fatalf("%d marks stored, want %d", len(got), len(keys))
	}
	// The merge rules held under the race: key 59 is covered by writers
	// 20..31, so it ends on the last round's writer 31 (the newest at) with
	// the highest seen.
	last := (rounds-1)*writers + writers - 1
	if m := got[keys[59]]; m.Seen != writers-1 || m.MsgID != fmt.Sprintf("m%03d", last) {
		t.Fatalf("%s = %+v, want seen %d and msg m%03d", keys[59], m, writers-1, last)
	}
}

// TestSaveReadMarksNotifiesOnCommit: the one-batch write still announces
// "<tenant>|f:<member>" on the browser wake channel (spec 062 FR-007): the
// batch's implicit transaction commits, and the NOTIFY goes with it.
func TestSaveReadMarksNotifiesOnCommit(t *testing.T) {
	pg := rlsStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tid := newTenant(t, pg)
	conn, err := pg.Pool().Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `LISTEN `+WUIWakeChannel); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	if err := pg.SaveReadMarks(ctx, tid, "HUM-1", map[string]ReadMark{"ch:devel": {At: now, MsgID: "m1"}}, now); err != nil {
		t.Fatal(err)
	}
	for {
		n, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			t.Fatalf("no %s notification for the read-marks write: %v", WUIWakeChannel, err)
		}
		if n.Payload == tid+"|f:HUM-1" {
			return
		}
	}
}

// TestSaveReadMarksRoundTrips: the write and the read each go as one batch
// (tenant scope + statement, one implicit transaction), where inTenant paid
// BEGIN, scope, statement and COMMIT.
func TestSaveReadMarksRoundTrips(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if u.Host == "" {
		t.Skip("SPOOL_TEST_PG_DSN is a unix socket; the counting proxy needs TCP")
	}
	rlsStore(t) // migrated, and RLS binds the role
	ctx := context.Background()
	proxy := newRTProxy(t, u.Host)
	u.Host = proxy.ln.Addr().String()
	pg, err := OpenPostgres(ctx, u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	tid := newTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)
	marks := map[string]ReadMark{"ch:devel": {At: now, MsgID: "m1", Seen: 1}, "t:T1": {At: now, MsgID: "m1"}, "f:seen": {At: now, MsgID: "m1"}}
	probes := []struct {
		name   string
		budget int64
		run    func() error
	}{
		{"SaveReadMarks", 1, func() error { return pg.SaveReadMarks(ctx, tid, "HUM-1", marks, now) }},
		{"ReadMarksOf", 1, func() error { _, err := pg.ReadMarksOf(ctx, tid, "HUM-1"); return err }},
	}
	const n = 5
	for _, p := range probes {
		if err := p.run(); err != nil { // warm the statement cache
			t.Fatalf("%s: %v", p.name, err)
		}
		var got []int64
		for i := 0; i < n; i++ {
			before := proxy.packets.Load()
			if err := p.run(); err != nil {
				t.Fatalf("%s: %v", p.name, err)
			}
			got = append(got, proxy.packets.Load()-before)
		}
		sort.Slice(got, func(a, b int) bool { return got[a] < got[b] })
		t.Logf("%-14s RT n=%d min/median/max %d/%d/%d", p.name, n, got[0], got[n/2], got[n-1])
		if got[n/2] > p.budget {
			t.Errorf("%s: median %d round trips, budget %d", p.name, got[n/2], p.budget)
		}
	}
}
