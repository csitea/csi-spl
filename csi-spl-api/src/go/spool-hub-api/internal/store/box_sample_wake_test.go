package store

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"
)

// Spec 071 7.8 "NOTIFY channel" (SPL-6239 row T4): a spool_box_sample
// announce from one store handle reaches a listener on a second handle with
// tenant, box, request id and deadline intact; a malformed payload is
// dropped, never delivered. Memory always; Postgres with SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full). RED CONTROL: a listener on another channel name
// gets nothing, and the wait for the first request fails.

const boxSampleWait = 10 * time.Second // a cap on each event wait, not a sleep

// boxSampleHandles is the announcing handle and a second handle that
// listens: the same Memory store (two hub servers share one), or a second
// Postgres pool on the same database.
func boxSampleHandles(t *testing.T, name string, st Store) (BoxSampleWaker, BoxSampleWaker) {
	t.Helper()
	a, ok := st.(BoxSampleWaker)
	if !ok {
		t.Fatalf("%s: store is not a BoxSampleWaker", name)
	}
	if name != "postgres" {
		return a, a
	}
	pg2, err := OpenPostgres(context.Background(), os.Getenv("SPOOL_TEST_PG_DSN"))
	if err != nil {
		t.Fatalf("postgres: second handle: %v", err)
	}
	t.Cleanup(pg2.Close)
	return a, pg2
}

// rawBoxSample announces a payload as is, bypassing the encoder, as a
// faulty or foreign writer on the channel would.
func rawBoxSample(t *testing.T, st BoxSampleWaker, payload string) {
	t.Helper()
	switch s := st.(type) {
	case *Memory:
		s.wake.notifyBoxSample(payload)
	case *Postgres:
		if _, err := s.pool.Exec(context.Background(), `SELECT pg_notify($1, $2)`, BoxSampleChannel, payload); err != nil {
			t.Fatalf("raw notify: %v", err)
		}
	default:
		t.Fatalf("raw notify: unknown store %T", st)
	}
}

// listenBoxSamples starts a listener on h and returns what it receives.
func listenBoxSamples(t *testing.T, h BoxSampleWaker) <-chan BoxSampleReq {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	got := make(chan BoxSampleReq, 64)
	done := make(chan error, 1)
	go func() { done <- h.ListenAll(ctx, WakeHandlers{BoxSample: func(r BoxSampleReq) { got <- r }}) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Errorf("ListenAll: %v", err)
		}
	})
	return got
}

// awaitBoxSample waits for the request with req id want, announcing probe
// again on every tick until it arrives (the listener may not be subscribed
// yet: LISTEN has no ready event). Anything else that arrives is returned in
// others.
func awaitBoxSample(t *testing.T, got <-chan BoxSampleReq, want string, probe func()) (BoxSampleReq, []BoxSampleReq) {
	t.Helper()
	var others []BoxSampleReq
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	limit := time.After(boxSampleWait)
	probe()
	for {
		select {
		case r := <-got:
			if r.ReqID == want {
				return r, others
			}
			others = append(others, r)
		case <-tick.C:
			probe()
		case <-limit:
			t.Fatalf("no box sample request %q within %s (others %v)", want, boxSampleWait, others)
		}
	}
}

func TestBoxSampleWakeChannel(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			pub, sub := boxSampleHandles(t, name, st)
			got := listenBoxSamples(t, sub)
			// the listener is up once a ready probe arrives
			ready := BoxSampleReq{Tenant: "t-ready", Box: "b", ReqID: "ready", Deadline: time.UnixMilli(1)}
			awaitBoxSample(t, got, "ready", func() { _ = pub.AnnounceBoxSample(ctx, ready) })

			want := BoxSampleReq{Tenant: "11111111-2222-3333-4444-555555555555", Box: "sat",
				ReqID: "8d7782cc-req-1", Deadline: time.UnixMilli(time.Now().Add(7 * time.Second).UnixMilli())}
			if err := pub.AnnounceBoxSample(ctx, want); err != nil {
				t.Fatalf("announce: %v", err)
			}
			r, _ := awaitBoxSample(t, got, want.ReqID, func() {})
			if r.Tenant != want.Tenant || r.Box != want.Box || r.ReqID != want.ReqID || !r.Deadline.Equal(want.Deadline) {
				t.Fatalf("got %+v, want %+v", r, want)
			}

			// malformed payloads, then a valid sentinel: on Postgres one
			// session's notifications arrive in order, so by the sentinel
			// every malformed one has been read and dropped
			for _, p := range []string{"", "t|b|r", "t|b|r|1|x", "|b|r|1", "t||r|1", "t|b||1",
				"t|b|r|", "t|b|r|soon", "t|b|r|0", "t|b|r|-5", "t-bad|b|bad-1"} {
				rawBoxSample(t, pub, p)
			}
			sentinel := BoxSampleReq{Tenant: "t", Box: "b", ReqID: "sentinel", Deadline: time.UnixMilli(2)}
			_, others := awaitBoxSample(t, got, "sentinel", func() { _ = pub.AnnounceBoxSample(ctx, sentinel) })
			for _, o := range others {
				if o.ReqID != ready.ReqID { // a late ready probe is not a delivery of a malformed payload
					t.Fatalf("malformed payload delivered: %+v", o)
				}
			}
		})
	}
}

// A request that cannot be framed is refused before it reaches the channel.
func TestBoxSampleAnnounceRefusesBadRequest(t *testing.T) {
	ok := BoxSampleReq{Tenant: "t", Box: "b", ReqID: "r", Deadline: time.UnixMilli(1)}
	bad := map[string]func(r *BoxSampleReq){
		"empty tenant":   func(r *BoxSampleReq) { r.Tenant = "" },
		"empty box":      func(r *BoxSampleReq) { r.Box = "" },
		"empty req":      func(r *BoxSampleReq) { r.ReqID = "" },
		"pipe in box":    func(r *BoxSampleReq) { r.Box = "b|x" },
		"pipe in req":    func(r *BoxSampleReq) { r.ReqID = "r|1" },
		"no deadline":    func(r *BoxSampleReq) { r.Deadline = time.Time{} },
		"epoch deadline": func(r *BoxSampleReq) { r.Deadline = time.Unix(0, 0) },
	}
	for name, st := range drivers(t) {
		w := st.(BoxSampleWaker)
		if err := w.AnnounceBoxSample(context.Background(), ok); err != nil {
			t.Fatalf("%s: a good request: %v", name, err)
		}
		for why, mut := range bad {
			r := ok
			mut(&r)
			if err := w.AnnounceBoxSample(context.Background(), r); !errors.Is(err, ErrBoxSampleReq) {
				t.Errorf("%s: %s: err = %v, want ErrBoxSampleReq", name, why, err)
			}
		}
	}
}
