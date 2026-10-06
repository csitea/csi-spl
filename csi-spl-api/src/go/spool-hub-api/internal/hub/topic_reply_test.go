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
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// topicReplyFrame is a browser reply in a topic with no channel and no `to`: what
// the WUI sends when a person answers under an agent's DM-style note.
func topicReplyFrame(t *testing.T, c *websocket.Conn, id, task, body string) map[string]any {
	t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": task, "kind": "note", "body": body, "is_parent": 0}
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	return readType(t, c, "ack")
}

// topicReplyRig: CLE-07 on box-a opens a channel-less topic with a note to a
// person (prd t1 916c8696's shape), and box-wui is pinned.
func topicReplyRig(t *testing.T) (*env, string, *box, string) {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	e := dispatchEnv(t, true, key)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	e.pinKey(tid, hub.WUIBox, pub)
	note, err := action.SendCtx(context.Background(), a.cfg, action.SendArgs{
		From: "CLE-07", To: "HUM-1", Kind: "note", Body: "the outage is over", ToBox: hub.WUIBox, Hub: a.c})
	if err != nil {
		t.Fatalf("agent note: %v", err)
	}
	return e, tid, a, note.TaskID
}

// The prd defect (2026-10-06, msg c88ae040): the owner's reply to ALL-0 in a
// channel-less topic got only a box-wui delivery row, so no agent read it.
// It is now dispatched to the topic's agent participant: a deliveries row for
// its box, signed by box-wui, addressed to that agent.
func TestWUIChannelLessReplyReachesTopicAgent(t *testing.T) {
	e, tid, _, task := topicReplyRig(t)
	ctx := context.Background()
	w := dialMember(t, e, tid, "Owner", "HUM-google-sub-1@"+tid)
	id := "91600000-0000-4000-8000-000000000001"
	ack := topicReplyFrame(t, w, id, task, "thanks, is the hub back on prd?")
	if ack["type"] != "ack" || ack["to_box"] != "box-a" {
		t.Fatalf("a channel-less reply reached no agent box: %v", ack)
	}
	q, err := e.st.QueuedFor(ctx, tid, "box-a", time.Now())
	if err != nil || len(q) != 1 || q[0].MsgID != id {
		t.Fatalf("queued for box-a: %v %+v", err, q)
	}
	envl, err := wire.ParseEnvelope(q[0].Env)
	if err != nil || envl.FromBox != hub.WUIBox || envl.ToBox != "box-a" || envl.Sig == "" {
		t.Fatalf("envelope %+v %v", envl, err)
	}
	if m, err := envl.Inner(); err != nil || m.To != "CLE-07" || m.TaskID != task {
		t.Fatalf("inner %+v %v", m, err)
	}
}

// A topic whose agent is no longer announced keeps the browser-only post:
// the reply is stored and acked, never refused.
func TestWUIChannelLessReplyWithoutAnnouncedAgentStaysBrowserOnly(t *testing.T) {
	e, tid, _, task := topicReplyRig(t)
	ctx := context.Background()
	if err := e.st.SetRoster(ctx, tid, "box-a", []string{}, time.Now()); err != nil {
		t.Fatal(err)
	}
	w := dialMember(t, e, tid, "Owner", "HUM-google-sub-1@"+tid)
	id := "91600000-0000-4000-8000-000000000002"
	if ack := topicReplyFrame(t, w, id, task, "anyone?"); ack["type"] != "ack" || ack["to_box"] != nil {
		t.Fatalf("ack %v", ack)
	}
	if _, err := e.st.DeliveryState(ctx, tid, id, "box-a"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("a reply reached a box whose agent left: %v", err)
	}
}
