package hub_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-6145 (spec 150 section 3.3.1; the owner, t1 0f457318 msg c94e2d29):
// a new topic whose first post ends with prio:NN takes that priority, and
// the token is not stored. A reply never changes the priority.
// RED CONTROL: on origin/master (no createPrioCut in wuiSend) the topic
// reads 3 and the body keeps " prio:01"; drop the rt.createPrio line in
// wuiSend and TestCreatePrioNewTopic fails the same way.

// sendInto posts body as member into task as a browser send of the given
// level and answers the stored message's body. The socket answers its
// frames in order, so the reply to the token frame sent after it says the
// send's after-ack steps (the priority set among them) are done: no wait.
func sendInto(t *testing.T, e *env, tid, member, task, body string, isParent int) string {
	t.Helper()
	c := dialMember(t, e, tid, member, member)
	id := uuidV4()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": task, "kind": "note", "body": body, "is_parent": isParent, "channel": "lobby"}
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	if ack := readType(t, c, "ack"); ack["type"] != "ack" {
		t.Fatalf("%s %q: %v", member, body, ack)
	}
	wsjson.Write(context.Background(), c, map[string]string{"type": "token"}) //nolint:errcheck
	if tok := readType(t, c, "token"); tok["type"] != "token" {
		t.Fatalf("token barrier: %v", tok)
	}
	m, err := e.st.GetEditable(context.Background(), tid, id, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m.Body
}

func TestCreatePrioNewTopic(t *testing.T) {
	for _, c := range []struct {
		as, body string
		prio     int
	}{
		{"HUM-2", "fix the login prio:01", 1},
		{"HUM-2", "fix the login prio-04", 4},
		{"HUM-8", "fix the login PRIO 5", 5},
	} {
		t.Run(c.body, func(t *testing.T) {
			e := archiveEnv(t)
			tid, _ := e.tenant()
			task := uuidV4()
			if got := sendInto(t, e, tid, c.as, task, c.body, 1); got != "fix the login" {
				t.Fatalf("stored body %q, want the text without the token", got)
			}
			if got := storedPriority(t, e, tid, task); got != c.prio {
				t.Fatalf("topic priority %d, want %d", got, c.prio)
			}
		})
	}
}

// C410 (SPL-6622, spec 150 section 3.4.2; the owner, poll 32527755 Q2 = B
// "Drop the word rule"): the owner's prio word is retired. The workspace
// owner's browser post holding "prio", "priority one" or "urgent" leaves its
// topic at 3 and its queued ask where it was; a new topic whose first post
// ends with prio:1 still sets 1; neither hub.Options nor the hub config
// carries a word list (SPOOL_HUB_OWNER_PRIO_WORDS is gone).
// RED CONTROL: on origin/master before B14 the "no word list" case fails
// (both structs carry OwnerPrioWords); restore the s.ownerPrioWord call in
// wuiAfterStore with the old default words and the owner cases fail with the
// topic at 1 and the ask at 1.
func TestOwnerPrioWordRemoved(t *testing.T) {
	t.Run("no word list", func(t *testing.T) {
		for _, typ := range []reflect.Type{reflect.TypeOf(hub.Options{}), reflect.TypeOf(config.Hub{})} {
			if _, ok := typ.FieldByName("OwnerPrioWords"); ok {
				t.Fatalf("%s still carries OwnerPrioWords", typ)
			}
		}
	})
	for _, body := range []string{"prio", "This is PRIO, please.", "priority one for this", "urgent: the queue"} {
		t.Run("owner says "+body, func(t *testing.T) {
			q := newPrioQueue(t)
			sendInto(t, q.e, q.tid, "HUM-8", q.task, body, 0)
			if got := storedPriority(t, q.e, q.tid, q.task); got != unsetTopicPriority {
				t.Fatalf("owner post %q set the topic to %d, want %d", body, got, unsetTopicPriority)
			}
			if got := q.position(t); got != 2 {
				t.Fatalf("owner post %q moved the ask to %d, want 2", body, got)
			}
		})
	}
	t.Run("a new topic ending with prio:1 still sets 1", func(t *testing.T) {
		e := archiveEnv(t)
		tid, _ := e.tenant()
		task := uuidV4()
		if got := sendInto(t, e, tid, "HUM-8", task, "urgent but explicit prio:1", 1); got != "urgent but explicit" {
			t.Fatalf("stored body %q, want the text without the token", got)
		}
		if got := storedPriority(t, e, tid, task); got != 1 {
			t.Fatalf("topic priority %d, want 1", got)
		}
	})
}

func TestCreatePrioRefusals(t *testing.T) {
	t.Run("a reply keeps the topic's priority and its text", func(t *testing.T) {
		e := archiveEnv(t)
		tid, _ := e.tenant()
		task := uuidV4()
		putCard(t, e, tid, task, "", "HUM-2", hub.WUIBox, 1, time.Now().UTC().Add(-time.Minute))
		if got := sendInto(t, e, tid, "HUM-2", task, "a reply prio:1", 0); got != "a reply prio:1" {
			t.Fatalf("reply body %q, want it as typed", got)
		}
		if got := storedPriority(t, e, tid, task); got != unsetTopicPriority {
			t.Fatalf("a reply set the priority to %d", got)
		}
	})
	t.Run("prio:6 is plain text", func(t *testing.T) {
		e := archiveEnv(t)
		tid, _ := e.tenant()
		task := uuidV4()
		if got := sendInto(t, e, tid, "HUM-2", task, "fix it prio:6", 1); got != "fix it prio:6" {
			t.Fatalf("body %q", got)
		}
		if got := storedPriority(t, e, tid, task); got != unsetTopicPriority {
			t.Fatalf("priority %d", got)
		}
	})
	t.Run("the admins policy: a developer's token stays text", func(t *testing.T) {
		e := archiveEnv(t)
		tid, _ := e.tenant()
		p := store.ArchivePolicyAdmins
		if err := e.st.(store.TenantSettings).SetTenantConfig(context.Background(), tid, store.TenantConfigPatch{TopicArchivePolicy: &p}); err != nil {
			t.Fatal(err)
		}
		task := uuidV4()
		if got := sendInto(t, e, tid, "HUM-2", task, "fix it prio:1", 1); got != "fix it prio:1" {
			t.Fatalf("body %q", got)
		}
		if got := storedPriority(t, e, tid, task); got != unsetTopicPriority {
			t.Fatalf("priority %d", got)
		}
	})
}
