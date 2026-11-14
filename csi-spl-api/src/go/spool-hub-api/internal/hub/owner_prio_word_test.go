package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-5524 (spec 157 section 4.1): the owner's prio word on a browser post
// sets the topic to priority 1, so its queued spawn ask moves to position 1.
// archiveEnv: HUM-8 owns the workspace, HUM-9 is an admin, HUM-2 a developer.
// RED CONTROL: drop the s.ownerPrioWord call from wuiAfterStore (or run on
// origin/master, which has none) -> TestOwnerPrioWordMovesAskToHead fails
// with position 2; the refusals pass either way, so they are pinned by the
// owner case being green in the same rig.

var testPrioWords = []string{"prio", "priority one", "urgent"}

// prioQueue is a topic with an opening card, a queued feature ask working
// for it, and an older queued bug with no discussion that ranks before it.
type prioQueue struct {
	e        *env
	tid      string
	task     string
	askTopic string
	askOther string
}

func newPrioQueue(t *testing.T, words ...string) prioQueue {
	t.Helper()
	e := archiveEnv(t, func(o *hub.Options) { o.OwnerPrioWords = words })
	tid, _ := e.tenant()
	ctx := context.Background()
	t0 := time.Now().UTC().Add(-time.Hour)
	q := prioQueue{e: e, tid: tid, task: uuidV4(), askTopic: uuidV4(), askOther: uuidV4()}
	putCard(t, e, tid, q.task, "", "HUM-2", hub.WUIBox, 1, t0)
	for i, a := range []struct{ id, disc, class string }{{q.askOther, "", "bug"}, {q.askTopic, q.task, "feature"}} {
		at := t0.Add(time.Duration(i) * time.Minute)
		if _, _, err := e.st.PutFleetAsk(ctx, tid, store.FleetAsk{Fleet: "main", AskID: a.id, Role: "orch", Kind: "task",
			From: "c-002@box-b", Topic: "dispatch-" + q.task[:8], Discussion: a.disc, Summary: "SPAWN REQUEST " + a.class}, "box-b", at); err != nil {
			t.Fatal(err)
		}
		if _, err := e.st.UpdateFleetAsk(ctx, tid, store.AskUpdate{Fleet: "main", AskID: a.id, Op: store.AskQueue, By: "c-001@sat", Class: a.class}, "sat", at); err != nil {
			t.Fatal(err)
		}
	}
	if got := q.position(t); got != 2 {
		t.Fatalf("before any post the topic's ask is at %d, want 2", got)
	}
	return q
}

// position is the topic's ask's place in the orch queue.
func (q prioQueue) position(t *testing.T) int {
	t.Helper()
	as, err := q.e.st.ListFleetAsks(context.Background(), q.tid, "main", "orch", false, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range as {
		if a.AskID == q.askTopic {
			return a.Position
		}
	}
	t.Fatalf("ask %s is not listed", q.askTopic)
	return 0
}

// post sends body as member into the topic and waits for its ack.
func (q prioQueue) post(t *testing.T, member, body string) {
	t.Helper()
	c := dialMember(t, q.e, q.tid, member, member)
	f := map[string]any{"type": "send", "msg_id": uuidV4(), "task_id": q.task, "kind": "note", "body": body, "is_parent": 0, "channel": "lobby"}
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	if ack := readType(t, c, "ack"); ack["type"] != "ack" {
		t.Fatalf("%s %q: %v", member, body, ack)
	}
}

// waitPosition polls (the step runs after the ack) until the ask is at want
// or the deadline; it answers the last position read.
func (q prioQueue) waitPosition(t *testing.T, want int, d time.Duration) int {
	t.Helper()
	end := time.Now().Add(d)
	for {
		got := q.position(t)
		if got == want || time.Now().After(end) {
			return got
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestOwnerPrioWordMovesAskToHead(t *testing.T) {
	for _, body := range []string{"prio", "This is PRIO, please.", "priority  one for this", "urgent: the queue"} {
		t.Run(body, func(t *testing.T) {
			q := newPrioQueue(t, testPrioWords...)
			q.post(t, "HUM-8", body)
			if got := q.waitPosition(t, 1, 3*time.Second); got != 1 {
				t.Fatalf("owner post %q: the ask is at %d, want 1", body, got)
			}
			if got := storedPriority(t, q.e, q.tid, q.task); got != 1 {
				t.Fatalf("owner post %q: topic priority %d, want 1", body, got)
			}
		})
	}
}

func TestOwnerPrioWordRefusals(t *testing.T) {
	cases := []struct{ name, as, body string }{
		{"a developer's prio", "HUM-2", "prio"},
		{"an admin's urgent", "HUM-9", "urgent"},
		{"prio inside priority", "HUM-8", "what is the priority here?"},
		{"prio inside prioritize", "HUM-8", "please prioritize this"},
		{"urgent inside urgently", "HUM-8", "needed urgently"},
		{"priority one split by a word", "HUM-8", "priority is one thing"},
		{"no word", "HUM-8", "looks good"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			q := newPrioQueue(t, testPrioWords...)
			q.post(t, c.as, c.body)
			if got := q.waitPosition(t, 1, 300*time.Millisecond); got != 2 {
				t.Fatalf("%s %q moved the ask to %d", c.as, c.body, got)
			}
			if got := storedPriority(t, q.e, q.tid, q.task); got != unsetTopicPriority {
				t.Fatalf("%s %q set the topic to %d", c.as, c.body, got)
			}
		})
	}
}

// Off: no words configured, the owner's prio moves nothing.
func TestOwnerPrioWordOff(t *testing.T) {
	q := newPrioQueue(t)
	q.post(t, "HUM-8", "prio")
	if got := q.waitPosition(t, 1, 300*time.Millisecond); got != 2 {
		t.Fatalf("words off: the ask moved to %d", got)
	}
}
