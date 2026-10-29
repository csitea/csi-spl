package hub_test

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// SPL-2712 (lane c-317, SPL-2698): the Connect an Agent help suggests one
// `spool hub-sync` by hand. Its hello superseded the running `spool hub-run`,
// which exited, and the box stayed offline. Now the daemon yields and says
// hello again: a second upgrade within the yield, and it is still running.
func TestHubRunReconnectsAfterOneShotSync(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	bx := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, bx)
	sp := newSplit(e.client, e.client)
	bx.c.HTTP = sp.client()
	bx.cfg.SubmitSocket = "off"
	bx.c.SessionProbe = -1
	bx.c.SupersedeYield = 300 * time.Millisecond
	bx.c.SupersedeFight = 3 * time.Second
	logs := &syncWriter{w: &bytes.Buffer{}}
	bx.c.Log = zerolog.New(logs)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- bx.c.Run(ctx) }()
	// "hub session up", not the upgrade count: the upgrade is counted before
	// the hello, and a sync whose hello lands first is the one evicted, so
	// the daemon never sees a 4409 (wf 20 39425899442, dials 1).
	eventually(t, "the daemon's first session", func() bool { return strings.Contains(logs.String(), "hub session up") })

	sync := hubclient.New(bx.cfg) // the hand-run hub-sync: same box, own process
	sync.HTTP = e.client
	sync.ReadyTimeout = 5 * time.Second
	if _, err := sync.Sync(ctx); err != nil {
		t.Fatalf("hub-sync: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for sp.dials.Load() < 2 {
		select {
		case err := <-done:
			t.Fatalf("hub-run exited after a one-shot hub-sync (%v): the box stays offline", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("hub-run did not say hello again within 5 s of the sync (dials %d)", sp.dials.Load())
		}
		time.Sleep(20 * time.Millisecond)
	}
	// past the fight window the re-hello still holds: nobody took it back
	select {
	case err := <-done:
		t.Fatalf("hub-run exited after its re-hello: %v", err)
	case <-time.After(bx.c.SupersedeFight + 500*time.Millisecond):
	}
	if d := sp.dials.Load(); d != 2 {
		t.Fatalf("daemon upgrades: %d, want 2 (one re-hello)", d)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run after cancel: %v", err)
	}
}

// Two long-running hub-runs on one box must not fight for it: after one
// re-hello each, exactly one exits with ErrSuperseded and the other keeps it.
//
// B starts only once A's session is up, not once A's upgrade is counted: the
// upgrade is counted before A's hello, so B's hello could land first, A's
// then evicts B inside B's dial (no 4409 for Run to yield on, a plain redial)
// and B pays one extra hello: "upgrades A 2 + B 3" (wf 10 40813917512,
// SPL-4173).
func TestHubRunTwoDaemonsOneLeaves(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	bx := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, bx)
	bx.cfg.SubmitSocket = "off"
	daemon := func() (*hubclient.Client, *split, *syncWriter) {
		c := hubclient.New(bx.cfg)
		sp := newSplit(e.client, e.client)
		c.HTTP = sp.client()
		c.ReadyTimeout = 5 * time.Second
		c.SessionProbe = -1
		c.SupersedeYield = 300 * time.Millisecond
		c.SupersedeFight = 3 * time.Second
		logs := &syncWriter{w: &bytes.Buffer{}}
		c.Log = zerolog.New(logs).With().Timestamp().Logger()
		return c, sp, logs
	}
	ca, spa, la := daemon()
	cb, spb, lb := daemon()
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("daemon A log:\n%s\ndaemon B log:\n%s", la.String(), lb.String())
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	da, db := make(chan error, 1), make(chan error, 1)
	go func() { da <- ca.Run(ctx) }()
	eventually(t, "daemon A's session", func() bool { return strings.Contains(la.String(), "hub session up") })
	go func() { db <- cb.Run(ctx) }()

	var left error
	var stays chan error
	select {
	case left = <-da:
		stays = db
	case left = <-db:
		stays = da
	case <-time.After(5 * time.Second):
		t.Fatalf("both daemons still running after 5 s (upgrades A %d, B %d): they fight", spa.dials.Load(), spb.dials.Load())
	}
	if !errors.Is(left, hubclient.ErrSuperseded) {
		t.Fatalf("the daemon that left returned %v, want ErrSuperseded", left)
	}
	na, nb := spa.dials.Load(), spb.dials.Load()
	select {
	case err := <-stays:
		t.Fatalf("the other daemon exited too: %v", err)
	case <-time.After(1500 * time.Millisecond):
	}
	if a, b := spa.dials.Load(), spb.dials.Load(); a != na || b != nb {
		t.Fatalf("upgrades after one daemon left: A %d->%d, B %d->%d: the survivor lost the box", na, a, nb, b)
	}
	if na+nb > 4 {
		t.Fatalf("upgrades A %d + B %d: more than one re-hello each", na, nb)
	}
	cancel()
	<-stays
}
