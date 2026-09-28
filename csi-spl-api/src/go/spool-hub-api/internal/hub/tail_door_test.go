package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// the WS tail read any task of the tenant - TaskEnvelopes had no
// party filter - and a follow streamed every later envelope of it, so a box
// holding a task_id (a removed channel member, a guess from a log) read other
// boxes' DMs and private-channel posts, bodies included. A box now tails only
// what it sent, was addressed or was delivered; the follow applies the same
// rule. CONTROL: the party boxes read the same task in full.
func TestTailReadsOnlyWhatTheBoxHolds(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	x := e.box(tid, "box-x", "AGY-09")
	for _, bx := range []*box{a, b, x} {
		e.pin(tid, bx)
	}
	ctx := context.Background()
	b.c.Sync(ctx) //nolint:errcheck
	a.c.Sync(ctx) //nolint:errcheck
	first := send(t, a, "GRK-03", "CLE-07", "task", "a to b only", "box-b")

	tail := func(bx *box) int {
		t.Helper()
		sess, err := bx.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		defer sess.Close()
		n, err := sess.Tail(ctx, first.TaskID, false, func(*wire.Envelope) {})
		if err != nil {
			t.Fatalf("%s tail: %v", bx.id, err)
		}
		return n
	}
	if n := tail(x); n != 0 {
		t.Fatalf("box-x read %d envelope(s) of a box-a -> box-b task", n)
	}
	if na, nb := tail(a), tail(b); na != 1 || nb != 1 {
		t.Fatalf("CONTROL: the parties read a=%d b=%d, want 1 each", na, nb)
	}

	// follow: box-x sees nothing of the next line; box-b (CONTROL) does.
	follow := func(bx *box) (chan string, context.CancelFunc) {
		fctx, cancel := context.WithCancel(ctx)
		sess, err := bx.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		got := make(chan string, 8)
		go func() {
			defer sess.Close()
			sess.Tail(fctx, first.TaskID, true, func(e *wire.Envelope) { //nolint:errcheck
				m, _ := e.Inner()
				got <- m.Body
			})
		}()
		return got, cancel
	}
	gx, cx := follow(x)
	defer cx()
	gb, cb := follow(b)
	defer cb()
	<-gb // box-b's stored line
	time.Sleep(100 * time.Millisecond)
	action.SendCtx(ctx, a.cfg, action.SendArgs{From: "GRK-03", To: "CLE-07", Kind: "note", Body: "second", TaskID: first.TaskID, Hub: a.c}) //nolint:errcheck
	select {
	case body := <-gb:
		if body != "second" {
			t.Fatalf("box-b follow got %q", body)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("CONTROL: box-b's follow did not see the new line")
	}
	select {
	case body := <-gx:
		t.Fatalf("box-x's follow streamed %q", body)
	case <-time.After(300 * time.Millisecond):
	}
}
