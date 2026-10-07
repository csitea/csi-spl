package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// seatFrame sends a browser line addressed to <to>@<toBox> in task: a reply
// (is_parent 0) the way the WUI answers an agent's post from its DM page.
func seatFrame(t *testing.T, c *websocket.Conn, id, task, to, toBox, body string, isParent int) map[string]any {
	t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": task, "kind": "note", "body": body,
		"to": to, "to_box": toBox, "is_parent": isParent}
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	return readType(t, c, "ack")
}

// retiredSeatRig: `author` on box-old opens a channel-less topic with a note
// to a person, then box-old is retired (announces nobody). box-new is pinned
// and announces `live`. box-wui is pinned.
func retiredSeatRig(t *testing.T, author string, live ...string) (*env, string, string, *websocket.Conn, *box) {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	e := dispatchEnv(t, true, key)
	tid, _ := e.tenant()
	ctx := context.Background()
	old := e.box(tid, "box-old", author)
	e.pin(tid, old)
	nb := e.box(tid, "box-new", live...)
	e.pin(tid, nb)
	e.pinKey(tid, hub.WUIBox, pub)
	note, err := action.SendCtx(ctx, old.cfg, action.SendArgs{
		From: author, To: "HUM-1", Kind: "note", Body: "posted 10-03", ToBox: hub.WUIBox, Hub: old.c})
	if err != nil {
		t.Fatalf("author note: %v", err)
	}
	if err := e.st.SetRoster(ctx, tid, "box-old", []string{}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if len(live) == 0 {
		if err := e.st.SetRoster(ctx, tid, "box-new", []string{}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	w := dialMember(t, e, tid, "Owner", "HUM-google-sub-1@"+tid)
	return e, tid, note.TaskID, w, nb
}

// queuedInner is the one message queued for box: its inner `to` and task.
func queuedInner(t *testing.T, e *env, tid, box, id string) (string, string) {
	t.Helper()
	q, err := e.st.QueuedFor(context.Background(), tid, box, time.Now())
	if err != nil || len(q) != 1 || q[0].MsgID != id {
		t.Fatalf("queued for %s: %v %+v", box, err, q)
	}
	envl, err := wire.ParseEnvelope(q[0].Env)
	if err != nil {
		t.Fatal(err)
	}
	m, err := envl.Inner()
	if err != nil {
		t.Fatal(err)
	}
	return m.To, m.TaskID
}

// Owner HUM-10 (t1 894678f1, ERR-CLIENT-20261007-185950-2F39): a reply to a
// post by c-002@<retired box>, while c-002 is seated on another box, goes to
// that seat. CONTROL: before the fix this ack was error unknown_agent (n=1).
func TestWUIReplyToRetiredSeatGoesToLiveSeat(t *testing.T) {
	e, tid, task, w, _ := retiredSeatRig(t, "c-002", "c-002")
	id := "89467800-0000-4000-8000-000000000001"
	ack := seatFrame(t, w, id, task, "c-002", "box-old", "still on it?", 0)
	if ack["type"] != "ack" || ack["to_box"] != "box-new" || ack["fallback"] != hub.FallbackBox || ack["retired"] != "c-002@box-old" {
		t.Fatalf("reply to a moved seat: %v", ack)
	}
	if to, tk := queuedInner(t, e, tid, "box-new", id); to != "c-002" || tk != task {
		t.Fatalf("inner to %q task %q", to, tk)
	}
}

// A reply to an id no box announces any more is posted to the topic (ALL-0):
// stored, acked with the fallback, no delivery for the retired box.
// CONTROL: before the fix, unknown_agent and nothing stored (n=1).
func TestWUIReplyToFullyRetiredSeatPostsToTopic(t *testing.T) {
	e, tid, task, w, _ := retiredSeatRig(t, "c-002")
	ctx := context.Background()
	id := "89467800-0000-4000-8000-000000000002"
	ack := seatFrame(t, w, id, task, "c-002", "box-old", "anyone?", 0)
	if ack["type"] != "ack" || ack["fallback"] != hub.FallbackTopic || ack["retired"] != "c-002@box-old" || ack["task_id"] != task {
		t.Fatalf("reply to a retired seat: %v", ack)
	}
	if has, _ := e.st.HasMessage(ctx, tid, id); !has {
		t.Fatal("the reply was not stored")
	}
	if _, err := e.st.DeliveryState(ctx, tid, id, "box-old"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("a delivery was built for the retired box: %v", err)
	}
}

// The topic post reaches the topic's other announced agent, as any ALL-0
// reply in a channel-less topic does (topic_reply.go).
func TestWUIReplyToRetiredSeatReachesTopicAgent(t *testing.T) {
	e, tid, task, w, nb := retiredSeatRig(t, "c-002", "c-001")
	ctx := context.Background()
	if _, err := action.SendCtx(ctx, nb.cfg, action.SendArgs{From: "c-001", To: "HUM-1", TaskID: task, Kind: "note",
		Body: "I hold this now", ToBox: hub.WUIBox, Hub: nb.c}); err != nil {
		t.Fatalf("od note: %v", err)
	}
	id := "89467800-0000-4000-8000-000000000003"
	ack := seatFrame(t, w, id, task, "c-002", "box-old", "who has it?", 0)
	if ack["type"] != "ack" || ack["fallback"] != hub.FallbackTopic || ack["to_box"] != "box-new" {
		t.Fatalf("topic fallback to the topic agent: %v", ack)
	}
	if to, tk := queuedInner(t, e, tid, "box-new", id); to != "c-001" || tk != task {
		t.Fatalf("inner to %q task %q", to, tk)
	}
}

// A legacy author (spec 061): a reply to a CLE-002 post goes to its alias
// c-002, here seated on another box; a legacy author with no alias posts to
// the topic. CONTROL: before the fix unknown_agent / retired_id (n=1 each).
func TestWUIReplyToLegacyAuthor(t *testing.T) {
	pinAgentClock(t, agentid.LegacyUntil.Add(-time.Hour))
	e, tid, task, w, _ := retiredSeatRig(t, "CLE-002", "c-002")
	ctx := context.Background()
	if _, _, err := e.st.PutAgentAlias(ctx, tid, store.AgentAlias{OldID: "CLE-002", NewID: "c-002", Kind: "claude", BoxID: "box-old"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	pinAgentClock(t, agentid.LegacyUntil.Add(time.Hour))
	id := "89467800-0000-4000-8000-000000000004"
	ack := seatFrame(t, w, id, task, "CLE-002", "box-old", "still there?", 0)
	if ack["type"] != "ack" || ack["to_box"] != "box-new" || ack["fallback"] != hub.FallbackBox {
		t.Fatalf("reply to an aliased legacy author: %v", ack)
	}
	if to, _ := queuedInner(t, e, tid, "box-new", id); to != "c-002" {
		t.Fatalf("inner to %q, want c-002", to)
	}

	pinAgentClock(t, agentid.LegacyUntil.Add(-time.Hour))
	_, _, task2, w2, _ := retiredSeatRig(t, "CLE-77")
	pinAgentClock(t, agentid.LegacyUntil.Add(time.Hour))
	id2 := "89467800-0000-4000-8000-000000000005"
	ack = seatFrame(t, w2, id2, task2, "CLE-77", "box-old", "hello?", 0)
	if ack["type"] != "ack" || ack["fallback"] != hub.FallbackTopic || ack["retired"] != "CLE-77@box-old" {
		t.Fatalf("reply to an unaliased legacy author: %v", ack)
	}
}

// CONTROLS: an explicit tag of a dead agent that is NOT a reply to it keeps
// today's answer - a new topic, and a thread the agent never took part in.
func TestWUITagOfDeadAgentStillRefused(t *testing.T) {
	e, tid, task, w, _ := retiredSeatRig(t, "c-002")
	ctx := context.Background()
	id := "89467800-0000-4000-8000-000000000006"
	if f := seatFrame(t, w, id, "89467800-0000-4000-8000-0000000000aa", "c-002", "box-old", "do x", 1); f["type"] != "error" || f["error"] != "unknown_agent" {
		t.Fatalf("new topic to a dead agent: %v", f)
	}
	if has, _ := e.st.HasMessage(ctx, tid, id); has {
		t.Fatal("a refused send was stored")
	}
	if f := seatFrame(t, w, "89467800-0000-4000-8000-000000000007", task, "c-099", "box-old", "you?", 0); f["type"] != "error" || f["error"] != "unknown_agent" {
		t.Fatalf("a stranger in the thread: %v", f)
	}
}
