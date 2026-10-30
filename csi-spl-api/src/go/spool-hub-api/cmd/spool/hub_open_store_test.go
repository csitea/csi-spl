package main

import (
	"bytes"
	"context"
	"math"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgproto3"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// flakyPostgres listens on 127.0.0.1. It closes the first `refuse`
// connections at once (a dial that fails, like the Cloud SQL dial of dev
// revision 01128-muv) and answers later ones as a minimal Postgres: trust
// auth, then an empty reply to every query (pgx's ping is "-- ping"). It
// returns a DSN for it and the count of accepted connections.
func flakyPostgres(t *testing.T, refuse int32) (string, *int32) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	accepted := new(int32)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			if atomic.AddInt32(accepted, 1) <= refuse {
				c.Close()
				continue
			}
			go servePing(c)
		}
	}()
	return "postgres://u:p@" + ln.Addr().String() + "/db?sslmode=disable&connect_timeout=1", accepted
}

// servePing speaks just enough of the backend protocol for a connect + ping.
func servePing(c net.Conn) {
	defer c.Close()
	be := pgproto3.NewBackend(c, c)
	if _, err := be.ReceiveStartupMessage(); err != nil {
		return
	}
	be.Send(&pgproto3.AuthenticationOk{})
	be.Send(&pgproto3.ReadyForQuery{TxStatus: 'I'})
	if be.Flush() != nil {
		return
	}
	for {
		m, err := be.Receive()
		if err != nil {
			return
		}
		switch m.(type) {
		case *pgproto3.Query:
			be.Send(&pgproto3.EmptyQueryResponse{})
			be.Send(&pgproto3.ReadyForQuery{TxStatus: 'I'})
			if be.Flush() != nil {
				return
			}
		case *pgproto3.Terminate:
			return
		}
	}
}

// fastStoreBackoff shrinks the 1 s first backoff so a test waits ms, not s.
func fastStoreBackoff(t *testing.T) {
	t.Helper()
	old := openStoreBackoff
	openStoreBackoff = 10 * time.Millisecond
	t.Cleanup(func() { openStoreBackoff = old })
}

// CI panel 2026-10-28 row F5 (SPL-4130), red control: the first dial fails
// and the second succeeds. Before the fix openStore made ONE try and returned
// "ping postgres", so the hub exited with most of its 120 s startup probe
// left. Now the second try opens the store, after one WARN line.
func TestHubOpenStoreRetriesAFailedFirstDial(t *testing.T) {
	fastStoreBackoff(t)
	dsn, accepted := flakyPostgres(t, 1)
	var logs bytes.Buffer
	st, err := openStore(context.Background(), dsn, store.PoolLimits{}, 10*time.Second, zerolog.New(&logs))
	if err != nil {
		t.Fatalf("openStore after one refused dial: %v", err)
	}
	st.Close()
	if n := atomic.LoadInt32(accepted); n < 2 {
		t.Fatalf("%d dial(s), want the refused one plus the one that opened", n)
	}
	if w := strings.Count(logs.String(), `"level":"warn"`); w != 1 {
		t.Fatalf("%d WARN lines, want 1 (one per failed try):\n%s", w, logs.String())
	}
}

// Every dial fails: openStore gives up once its deadline is spent, with the
// last ping error, and has logged one WARN line per failed try.
func TestHubOpenStoreGivesUpAtTheDeadline(t *testing.T) {
	fastStoreBackoff(t)
	dsn, _ := flakyPostgres(t, 1<<30)
	var logs bytes.Buffer
	start := time.Now()
	_, err := openStore(context.Background(), dsn, store.PoolLimits{}, 200*time.Millisecond, zerolog.New(&logs))
	if err == nil || !strings.Contains(err.Error(), "ping postgres") {
		t.Fatalf("err %v, want the last ping postgres error once the deadline is spent", err)
	}
	if w := strings.Count(logs.String(), `"level":"warn"`); w < 2 {
		t.Fatalf("%d WARN lines, want one per failed try:\n%s", w, logs.String())
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("took %s, want it bounded by the 200 ms deadline (+ one try)", d)
	}
}

// within 0 is the one-shot path (hub-reset-password): one try, no WARN.
func TestHubOpenStoreOneShotTriesOnce(t *testing.T) {
	fastStoreBackoff(t)
	dsn, _ := flakyPostgres(t, 1)
	var logs bytes.Buffer
	_, err := openStore(context.Background(), dsn, store.PoolLimits{}, 0, zerolog.New(&logs))
	if err == nil || !strings.Contains(err.Error(), "ping postgres") {
		t.Fatalf("err %v, want the first try's ping postgres error", err)
	}
	if logs.Len() != 0 {
		t.Fatalf("one-shot logged %q, want nothing", logs.String())
	}
}

// A cancelled start (SIGTERM during the wait) stops the retries at once.
func TestHubOpenStoreStopsOnCancel(t *testing.T) {
	dsn, _ := flakyPostgres(t, 1<<30)
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(100*time.Millisecond, cancel)
	start := time.Now()
	if _, err := openStore(ctx, dsn, store.PoolLimits{}, time.Minute, zerolog.Nop()); err == nil {
		t.Fatal("want an error after the cancel")
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Fatalf("took %s after a cancel at 100 ms", d)
	}
}

// memory: never dials and never waits.
func TestHubOpenStoreMemory(t *testing.T) {
	st, err := openStore(context.Background(), "memory:", store.PoolLimits{}, time.Minute, zerolog.Nop())
	if err != nil || st == nil {
		t.Fatalf("memory: store %v err %v", st, err)
	}
	st.Close()
}

// The deadline env: default 60 s, a duration below the 120 s startup probe.
func TestHubOpenStoreDeadlineEnv(t *testing.T) {
	cases := []struct {
		val  string
		want time.Duration
		bad  bool
	}{
		{"", 60 * time.Second, false},
		{"30s", 30 * time.Second, false},
		{"0s", 0, false},
		{"abc", 0, true},
		{"-1s", 0, true},
		{"120s", 0, true},
	}
	for _, c := range cases {
		t.Setenv("SPOOL_HUB_DB_OPEN_WITHIN", c.val)
		got, err := openStoreWithin()
		if (err != nil) != c.bad || (!c.bad && got != c.want) {
			t.Errorf("SPOOL_HUB_DB_OPEN_WITHIN=%q: got %s err %v, want %s bad=%v", c.val, got, err, c.want, c.bad)
		}
	}
}

// r42-04: a valid pool size passes as is; out of int32 range it is clamped.
func TestHubPoolSizeBounds(t *testing.T) {
	for in, want := range map[int]int32{0: 0, 2: 2, 8: 8, -1: 0, math.MaxInt32: math.MaxInt32, math.MaxInt32 + 1: math.MaxInt32} {
		if got := poolSize(in); got != want {
			t.Errorf("poolSize(%d) = %d, want %d", in, got, want)
		}
	}
}
