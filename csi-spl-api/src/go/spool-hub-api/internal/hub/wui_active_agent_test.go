package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// replyFrame sends a browser line INTO a thread (task_id, is_parent 0), the
// way the WUI sends a reply typed in an open topic.
func replyFrame(t *testing.T, c *websocket.Conn, id, task, body string) map[string]any {
	t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": task, "kind": "note", "body": body, "is_parent": 0}
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	return readType(t, c, "ack")
}

// Owner 2026-10-05 (prd t1 dc6d5e3f): "I should be able to tag only currently
// active agents". HUM-10 tagged AGY-3499 - a legacy id retired 2026-10-03
// that the csi-rel desk still announced - so the hub dispatched it and the
// box dropped it ("AGY-3499 is retired as an id"). Past agentid.LegacyUntil a
// browser send to a legacy id goes to its successor (alias table, same
// thread) or is refused with retired_id; nothing reaches a box under the old
// id. CONTROL: before the fix both sends below were queued for AGY-* (n=1).
func TestWUISendToRetiredIDGoesToSuccessorOrIsRefused(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(nil)
	e := dispatchEnv(t, true, key)
	tid, root := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "a-004")
	e.pin(tid, a)
	if code, eb := e.postPin(tid, root, hub.WUIBox, b64(key.Public().(ed25519.PublicKey))); code != http.StatusOK {
		t.Fatalf("pin box-wui: %d %+v", code, eb)
	}
	// the stale desk still announces the legacy ids beside the successor
	if err := e.st.SetRoster(ctx, tid, "box-a", []string{"a-004", "AGY-3499", "AGY-77"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.st.PutAgentAlias(ctx, tid, store.AgentAlias{OldID: "AGY-3499", NewID: "a-004", Kind: "agy", BoxID: "box-a"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	pinAgentClock(t, agentid.LegacyUntil.Add(time.Hour))
	w := dialMember(t, e, tid, "Alice", "HUM-google-sub-1@"+tid)
	thread := "ac43e7c8-c0e1-433e-9c0c-4d217c1ce3e7"

	// an aliased legacy id: delivered to the successor, in the same thread
	id := "5f0d5200-7ecf-49a6-8cd1-75193d20880c"
	ack := replyFrame(t, w, id, thread, "@AGY-3499 still here?")
	if ack["type"] != "ack" || ack["task_id"] != thread || ack["to_box"] != "box-a" {
		t.Fatalf("aliased legacy id: %v", ack)
	}
	q, err := e.st.QueuedFor(ctx, tid, "box-a", time.Now())
	if err != nil || len(q) != 1 || q[0].MsgID != id {
		t.Fatalf("queued for box-a: %v %+v", err, q)
	}
	envl, err := wire.ParseEnvelope(q[0].Env)
	if err != nil {
		t.Fatal(err)
	}
	m, err := envl.Inner()
	if err != nil || m.To != "a-004" || m.TaskID != thread {
		t.Fatalf("inner to %q task %q (want a-004 in %s): %v", m.To, m.TaskID, thread, err)
	}

	// a legacy id with no successor: refused with a reason, nothing stored
	id2 := "5f0d5200-7ecf-49a6-8cd1-75193d20880d"
	f := replyFrame(t, w, id2, thread, "@AGY-77 hello")
	if f["type"] != "error" || f["error"] != hub.TokenRetiredID || !strings.Contains(f["detail"].(string), "no longer active") {
		t.Fatalf("unaliased legacy id: %v", f)
	}
	if has, _ := e.st.HasMessage(ctx, tid, id2); has {
		t.Fatal("a refused send was stored")
	}

	// the successor itself and a plain reply are unchanged
	if ack := replyFrame(t, w, "5f0d5200-7ecf-49a6-8cd1-75193d20880e", thread, "@a-004 look"); ack["type"] != "ack" || ack["task_id"] != thread {
		t.Fatalf("new id: %v", ack)
	}
	if ack := replyFrame(t, w, "5f0d5200-7ecf-49a6-8cd1-75193d20880f", thread, "thanks @AGY-77"); ack["type"] != "ack" {
		t.Fatalf("a mention later in the line is text: %v", ack)
	}
}
