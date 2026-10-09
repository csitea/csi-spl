package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// dmSees reports whether reader sees msg id in topic task (the read door).
func dmSees(t *testing.T, e *env, tid, task, reader, id string) bool {
	t.Helper()
	code, out := call(t, e, tid, "GET", "/v1/view/topics/"+task, reader, nil)
	if code != http.StatusOK {
		return false
	}
	ms, _ := out["messages"].([]any)
	for _, m := range ms {
		if raw, _ := json.Marshal(m); strings.Contains(string(raw), id) { // the row's env carries it
			return true
		}
	}
	return false
}

// prd t1 f87e6c9d (2026-10-09): A sends B a DM, B answers in the topic's
// reply pane (no `to`), and the reply was stored to ALL-0 with no channel,
// which the read door shows to its poster only - A never saw it. It is now
// readdressed to the other end of the DM, so A reads it, and so does a reply
// in a message-rooted topic off that DM. A third member still reads neither.
// CONTROL: on the code before spec 117 (wui.go without topicReplyPerson)
// this fails at "A cannot read B's reply to A's DM". Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full).
func TestWUIDMReplyReachesTheOtherPerson(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	a, b, x := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	wa, wb := dialMember(t, e, tid, "", a), dialMember(t, e, tid, "", b)

	dm, root := uuidV4(), uuidV4()
	if f := sendDM(t, wa, root, dm, b, 1); f["type"] != "ack" {
		t.Fatalf("A's DM to B: %v", f)
	}
	reply := uuidV4()
	if f := sendDM(t, wb, reply, dm, "", 0); f["type"] != "ack" || f["to"] != a { // FR-3: the ack names the final to
		t.Fatalf("B's reply to the topic: %v, want an ack to %s", f, a)
	}
	if !dmSees(t, e, tid, dm, a, reply) {
		t.Fatal("A cannot read B's reply to A's DM")
	}
	if !dmSees(t, e, tid, dm, b, reply) || dmSees(t, e, tid, dm, x, reply) {
		t.Fatal("B lost its own reply, or a third member reads the DM")
	}
	// A answers back the same way: B reads it
	back := uuidV4()
	if f := sendDM(t, wa, back, dm, "", 0); f["type"] != "ack" || !dmSees(t, e, tid, dm, b, back) {
		t.Fatalf("B cannot read A's reply: %v", f)
	}
	// a message-rooted topic off the DM (parent_task_id, no channel)
	sub, line := uuidV4(), uuidV4()
	f := map[string]any{"type": "send", "msg_id": line, "task_id": sub, "parent_task_id": dm, "kind": "note", "body": "hello", "is_parent": 0}
	wsjson.Write(context.Background(), wb, f) //nolint:errcheck
	if ack := readType(t, wb, "ack"); ack["type"] != "ack" || !dmSees(t, e, tid, sub, a, line) {
		t.Fatalf("A cannot read B's thread off the DM: %v", ack)
	}
}

// A NEW topic with no channel and no `to` has nobody to reach: it is refused
// (400 dm_needs_to) and not stored, never put in the lobby. CONTROL: the same
// new topic addressed to B is stored and B reads it; a lobby post with no `to`
// is still accepted. A third member's reply to nobody in that DM has two
// other people to choose from: refused as well (FR-1). Memory, and Postgres under SPOOL_TEST_PG_DSN.
func TestWUINewChannelLessTopicToNobodyRefused(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	a, b := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	wa := dialMember(t, e, tid, "", a)

	id := uuidV4()
	f := sendDM(t, wa, id, uuidV4(), "", 1)
	if f["type"] != "error" || f["error"] != "dm_needs_to" || f["status"] != float64(http.StatusBadRequest) {
		t.Fatalf("a new channel-less topic to nobody: %v, want 400 dm_needs_to", f)
	}
	if stored(t, e, tid, id) {
		t.Fatal("the refused topic was stored")
	}
	task, cid := uuidV4(), uuidV4()
	if f := sendDM(t, wa, cid, task, b, 1); f["type"] != "ack" || !dmSees(t, e, tid, task, b, cid) {
		t.Fatalf("CONTROL the same topic to B: %v", f)
	}
	// FR-1: a reply to nobody with two other people in the topic is refused too
	wx := dialMember(t, e, tid, "", seat(t, e, tid, rbac.Developer))
	if f := sendDM(t, wx, uuidV4(), task, "", 0); f["error"] != "dm_needs_to" {
		t.Fatalf("a third member's reply to nobody in a DM: %v, want dm_needs_to", f)
	}
	if f := sendDM(t, wa, uuidV4(), "lobby", "", 1); f["type"] != "ack" {
		t.Fatalf("CONTROL a lobby post: %v", f)
	}
}
