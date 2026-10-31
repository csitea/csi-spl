package hub_test

import (
	"context"
	"testing"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-4444 (topic 63674838, 2026-10-30): the dispatch holder took a topic
// from one box's desk, and the other box's desk then refused the routed
// seat's reply twice as a "first agent reply", because that box's tail holds
// only what it sent or was sent. An agent_count tail counts the topic's agent
// messages (not a person, not the responder) from any box. CONTROLS: the
// box's own tail still holds only its own share; rsp_count is unchanged; a
// box that holds nothing of the topic reads 0; a frame asking both counts is
// refused.
func TestTailAgentCountSeesAnotherBoxesAgent(t *testing.T) {
	rsp := agentid.Responder
	e := newEnv(t)
	tid, _ := e.tenant()
	h := e.box(tid, "box-h", "CLE-07")
	a := e.box(tid, "box-a", "CLE-08")
	r := e.box(tid, "box-rsp", rsp)
	b := e.box(tid, "box-b", "AGY-09")
	x := e.box(tid, "box-x", "AGY-10")
	for _, bx := range []*box{h, a, r, b, x} {
		e.pin(tid, bx)
	}
	ctx := context.Background()
	for _, bx := range []*box{h, a, r, b, x} {
		bx.c.Sync(ctx) //nolint:errcheck
	}
	first := send(t, h, "CLE-07", "CLE-08", "note", "take this", "box-a")
	action.SendCtx(ctx, a.cfg, action.SendArgs{From: "CLE-08", To: "CLE-07", Kind: "note", //nolint:errcheck
		Body: "taken", TaskID: first.TaskID, ToBox: "box-h", Hub: a.c})
	action.SendCtx(ctx, r.cfg, action.SendArgs{From: rsp, To: "CLE-07", Kind: "note", //nolint:errcheck
		Body: "Seen: routed to the team.", TaskID: first.TaskID, ToBox: "box-h", Hub: r.c})
	action.SendCtx(ctx, h.cfg, action.SendArgs{From: "CLE-07", To: "AGY-09", Kind: "task", //nolint:errcheck
		Body: "answer it", TaskID: first.TaskID, ToBox: "box-b", Hub: h.c})

	dial := func(bx *box) *hubclient.Session {
		t.Helper()
		sess, err := bx.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { closeWait(sess) })
		return sess
	}
	count := func(bx *box) int {
		t.Helper()
		n, err := dial(bx).AgentCount(ctx, first.TaskID)
		if err != nil {
			t.Fatalf("%s agent_count: %v", bx.id, err)
		}
		return n
	}
	if n := count(b); n != 3 {
		t.Fatalf("box-b read %d agent message(s), want 3 (CLE-07 twice, CLE-08; not the responder)", n)
	}
	held, err := dial(b).Tail(ctx, first.TaskID, false, func(*wire.Envelope) {})
	if err != nil || held != 1 {
		t.Fatalf("CONTROL: box-b's own tail holds %d envelope(s) (err %v), want 1: the count must cross boxes", held, err)
	}
	if n, err := dial(b).RSPCount(ctx, first.TaskID); err != nil || n != 1 {
		t.Fatalf("CONTROL: rsp_count read %d (err %v), want 1", n, err)
	}
	if n := count(x); n != 0 {
		t.Fatalf("CONTROL: box-x holds nothing of the topic and read %d", n)
	}
	raw := e.rawBox(tid, x, []string{"AGY-10"}, nil)
	wsjson.Write(ctx, raw.c, wire.Frame{Type: wire.TTail, TaskID: first.TaskID, RSPCount: true, AgentCount: true}) //nolint:errcheck
	if f := raw.next(wire.TError); f.Error != "bad_frame" {
		t.Fatalf("CONTROL: a tail asking both counts answered %+v, want bad_frame", f)
	}
}
