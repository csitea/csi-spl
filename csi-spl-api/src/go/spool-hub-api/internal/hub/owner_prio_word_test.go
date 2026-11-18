package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
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
	t0 := time.Now().UTC().Add(-time.Hour)
	q := prioQueue{e: e, tid: tid, task: uuidV4(), askTopic: uuidV4(), askOther: uuidV4()}
	putCard(t, e, tid, q.task, "", "HUM-2", hub.WUIBox, 1, t0)
	queuePrioAsks(t, e, tid, q)
	return q
}

// queuePrioAsks queues, in tid, an older bug with no discussion and a
// feature ask working for q.task, which therefore ranks 2nd.
func queuePrioAsks(t *testing.T, e *env, tid string, q prioQueue) {
	t.Helper()
	ctx := context.Background()
	t0 := time.Now().UTC().Add(-time.Hour)
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
	q.tid = tid
	if got := q.position(t); got != 2 {
		t.Fatalf("before any post the topic's ask is at %d in %s, want 2", got, tid)
	}
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
	for _, body := range []string{"prio", "This is PRIO, please.", "priority  one for this", "urgent: the queue", "> was it done?\n\nurgent, please"} {
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
		{"prio in a quoted line (R7 W2)", "HUM-8", "> is this urgent?\n\nNo, next week."},
		{"prio in a code span (R7 W2)", "HUM-8", "the word `prio` is a hub word"},
		{"prio in a code fence (R7 W2)", "HUM-8", "see:\n```\nSPOOL_HUB_OWNER_PRIO_WORDS=prio\n```\nfine"},
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

// tenantRoles is an authorizer whose roles depend on the workspace; any
// other member is a developer.
type tenantRoles map[string]map[string]string

func (m tenantRoles) Access(ctx context.Context, hum, tenant string) (rbac.Access, error) {
	if r, ok := m[tenant][hum]; ok {
		return rbac.Fixed(r).Access(ctx, hum, tenant)
	}
	return rbac.Fixed(rbac.Developer).Access(ctx, hum, tenant)
}

func (m tenantRoles) Roles(ctx context.Context, tenant string) (map[string]rbac.Role, error) {
	return rbac.Fixed(rbac.Developer).Roles(ctx, tenant)
}

// R7 W1 (csitea weekly item 10's own case): the spawn queue lives in the
// operator workspace op, a topic is in another workspace. The operator
// workspace's owner (HUM-7) posting the prio word in that topic moves op's
// ask working for it to the head; the other workspace's own owner (HUM-8,
// not op's owner) sets the topic there but never reorders op's queue.
// RED CONTROL: drop the "if op != \"\"" block in ownerPrioWord -> the
// operator owner case fails with the ask at 2.
func TestOwnerPrioWordOperatorQueue(t *testing.T) {
	for _, c := range []struct {
		name, as string
		want     int
	}{
		{"the operator workspace's owner", "HUM-7", 1},
		{"the topic workspace's owner only", "HUM-8", 2},
	} {
		t.Run(c.name, func(t *testing.T) {
			op := newTenantID("op")
			roles := tenantRoles{op: {"HUM-7": rbac.BizOwner}}
			e := archiveEnv(t, func(o *hub.Options) {
				o.OwnerPrioWords = testPrioWords
				o.OperatorTenant = op
				o.Authorizer = roles
			})
			pub, _, _ := ed25519.GenerateKey(nil)
			if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
				t.Fatal(err)
			}
			tid, _ := e.tenant()
			roles[tid] = map[string]string{"HUM-8": rbac.BizOwner} // before any request
			q := prioQueue{e: e, tid: tid, task: uuidV4(), askTopic: uuidV4(), askOther: uuidV4()}
			queuePrioAsks(t, e, op, q)
			putCard(t, e, tid, q.task, "", "HUM-2", hub.WUIBox, 1, time.Now().UTC().Add(-time.Hour))
			opq := q
			opq.tid = op
			q.post(t, c.as, "prio")
			// the post was handled once the topic's own priority is 1
			for end := time.Now().Add(3 * time.Second); storedPriority(t, e, tid, q.task) != 1; time.Sleep(20 * time.Millisecond) {
				if time.Now().After(end) {
					t.Fatalf("%s: the topic's own priority never reached 1", c.as)
				}
			}
			if got := opq.waitPosition(t, 1, 500*time.Millisecond); got != c.want {
				t.Fatalf("%s: op's ask is at %d, want %d", c.as, got, c.want)
			}
		})
	}
}

// SPL-5905 (prd ask 58a67da0): the priority chooser, PUT
// /v1/topics/{task_id}/priority, on a topic of another workspace follows the
// prio word's rule (R7 W1, TestOwnerPrioWordOperatorQueue). The operator
// workspace's owner (HUM-7, also an owner of the topic's workspace) setting
// 1 moves op's ask working for the topic to the head; the topic workspace's
// own owner (HUM-8, not op's) sets the topic there and op's queue keeps its
// order and its own unset row.
// RED CONTROL: drop the priorityToOperator call in handleTopicPriority ->
// the HUM-7 case fails with op's ask at 2 and op's row at 3.
func TestTopicPriorityOperatorQueue(t *testing.T) {
	for _, c := range []struct {
		name, as      string
		want, wantRow int
	}{
		{"the operator workspace's owner", "HUM-7", 1, 1},
		{"the topic workspace's owner only", "HUM-8", 2, unsetTopicPriority},
	} {
		t.Run(c.name, func(t *testing.T) {
			op := newTenantID("op")
			roles := tenantRoles{op: {"HUM-7": rbac.BizOwner}}
			e := archiveEnv(t, func(o *hub.Options) {
				o.OperatorTenant = op
				o.Authorizer = roles
			})
			pub, _, _ := ed25519.GenerateKey(nil)
			if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
				t.Fatal(err)
			}
			tid, _ := e.tenant()
			roles[tid] = map[string]string{"HUM-7": rbac.BizOwner, "HUM-8": rbac.BizOwner}
			q := prioQueue{e: e, tid: op, task: uuidV4(), askTopic: uuidV4(), askOther: uuidV4()}
			queuePrioAsks(t, e, op, q)
			putCard(t, e, tid, q.task, "", "HUM-2", hub.WUIBox, 1, time.Now().UTC().Add(-time.Hour))
			if code, out := putPriority(t, e, tid, q.task, c.as, map[string]any{"priority": 1}); code != http.StatusOK {
				t.Fatalf("%s: PUT priority %d %v", c.as, code, out)
			}
			if got := storedPriority(t, e, tid, q.task); got != 1 {
				t.Fatalf("%s: the topic's own priority %d, want 1", c.as, got)
			}
			if got := storedPriority(t, e, op, q.task); got != c.wantRow {
				t.Fatalf("%s: op's row for the topic %d, want %d", c.as, got, c.wantRow)
			}
			if got := q.position(t); got != c.want {
				t.Fatalf("%s: op's ask is at %d, want %d", c.as, got, c.want)
			}
		})
	}
}
