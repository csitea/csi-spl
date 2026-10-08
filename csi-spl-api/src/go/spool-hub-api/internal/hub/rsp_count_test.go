package hub_test

import (
	"context"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// c-082 (prd t1 139c58c8, 2026-10-03): two machines each posted an RSP-01
// "Seen" into one topic, because the second responder (sat-rsp, after the
// lease moved) could only tail what ITS box holds and box-rsp's "Seen" is
// not among it. A rsp_count tail counts the topic's RSP-* messages from any
// box. CONTROLS: a topic with no RSP row reads 0, and a box that holds
// nothing of the topic reads 0 (the tail door still holds).
func TestTailRSPCountSeesAnotherBoxesResponder(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	h := e.box(tid, "box-h", "CLE-07")
	a := e.box(tid, "box-rsp", "RSP-01")
	b := e.box(tid, "sat-rsp", "RSP-01")
	x := e.box(tid, "box-x", "AGY-09")
	for _, bx := range []*box{h, a, b, x} {
		e.pin(tid, bx)
	}
	ctx := context.Background()
	for _, bx := range []*box{h, a, b, x} {
		bx.c.Sync(ctx) //nolint:errcheck
	}
	first := send(t, h, "CLE-07", "RSP-01", "note", "anyone?", "box-rsp")
	action.SendCtx(ctx, a.cfg, action.SendArgs{From: "RSP-01", To: "CLE-07", Kind: "note", //nolint:errcheck
		Body: "Seen: routed to the team.", TaskID: first.TaskID, ToBox: "box-h", Hub: a.c})
	action.SendCtx(ctx, h.cfg, action.SendArgs{From: "CLE-07", To: "RSP-01", Kind: "note", //nolint:errcheck
		Body: "still there?", TaskID: first.TaskID, ToBox: "sat-rsp", Hub: h.c})
	other := send(t, h, "CLE-07", "RSP-01", "note", "a fresh topic", "sat-rsp")

	count := func(bx *box, task string) int {
		t.Helper()
		sess, err := bx.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		defer closeWait(sess)
		n, err := sess.RSPCount(ctx, task)
		if err != nil {
			t.Fatalf("%s rsp_count: %v", bx.id, err)
		}
		return n
	}
	if n := count(b, first.TaskID); n != 1 {
		t.Fatalf("sat-rsp read %d RSP row(s) in a topic box-rsp answered, want 1", n)
	}
	if n := count(b, other.TaskID); n != 0 {
		t.Fatalf("CONTROL: a topic with no RSP row read %d", n)
	}
	if n := count(x, first.TaskID); n != 0 {
		t.Fatalf("CONTROL: box-x holds nothing of the topic and read %d", n)
	}
}
