package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ---- US4: tail ---------------------------------------------------------------------

func TestTailStoredAndFollow(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	b.c.Sync(ctx) //nolint:errcheck
	a.c.Sync(ctx) //nolint:errcheck
	first := send(t, a, "GRK-03", "CLE-07", "task", "one", "box-b")

	sess, err := b.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sess)
	var bodies []string
	n, err := sess.Tail(ctx, first.TaskID, false, func(e *wire.Envelope) {
		m, _ := e.Inner()
		bodies = append(bodies, m.Body)
	})
	if err != nil || n != 1 || bodies[0] != "one" {
		t.Fatalf("stored tail: %d %v %v", n, bodies, err)
	}

	fctx, cancel := context.WithCancel(ctx)
	got := make(chan string, 4)
	go sess.Tail(fctx, first.TaskID, true, func(e *wire.Envelope) { //nolint:errcheck
		m, _ := e.Inner()
		got <- m.Body
	})
	<-got                                                                                                                                // the stored "one" again
	action.SendCtx(ctx, a.cfg, action.SendArgs{From: "GRK-03", To: "CLE-07", Kind: "note", Body: "two", TaskID: first.TaskID, Hub: a.c}) //nolint:errcheck
	select {
	case b := <-got:
		if b != "two" {
			t.Fatalf("follow got %q", b)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("follower did not see the new message")
	}
	cancel()
}
