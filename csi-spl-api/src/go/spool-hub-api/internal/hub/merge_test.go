package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// POST /v1/messages/{msg_id}/merge {"into"} edits the kept message
// and deletes the source in ONE transaction, and tells every open tab with ONE
// message_merged frame. Every refusal is a control: remove its guard in
// merge.go and the test goes red on the status AND on the stored rows.

// postIn sends one browser note into task (in #lobby) and returns its msg_id.
func postIn(t *testing.T, c *websocket.Conn, task, body string, isParent int) string {
	t.Helper()
	wsjson.Write(context.Background(), c, map[string]any{"type": "send", "task_id": task, "channel": "lobby", //nolint:errcheck
		"body": body, "is_parent": isParent})
	ack := readType(t, c, "ack")
	id, _ := ack["msg_id"].(string)
	if id == "" {
		t.Fatalf("send %q: %v", body, ack)
	}
	return id
}

func merge(t *testing.T, e *env, tid, src, into, as string) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodPost, "/v1/messages/"+src+"/merge", as, map[string]string{"into": into})
}

// The owner's case: the newer message merged into the previous one. The kept
// row holds both bodies with a revision, the source is gone from the store and
// from a re-read, and a second session gets ONE message_merged frame.
func TestMergeMessageIntoPrevious(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	watcher := dialMember(t, e, tid, "HUM-2", "HUM-2")
	for _, c := range []*websocket.Conn{author, watcher} {
		wsjson.Write(context.Background(), c, map[string]string{"type": "subscribe", "task_id": lobby}) //nolint:errcheck
		readType(t, c, "subscribed")
	}
	older, _ := postNote(t, author, "first part  ")["msg_id"].(string)
	readType(t, watcher, "message")
	newer, _ := postNote(t, author, "\nsecond part")["msg_id"].(string)
	readType(t, watcher, "message")

	code, out := merge(t, e, tid, newer, older, "HUM-1")
	if code != http.StatusOK {
		t.Fatalf("merge: %d %v", code, out)
	}
	if got := bodyOfEnv(t, out); got != "first part\n\nsecond part" {
		t.Fatalf("response body %q", got)
	}
	if out["merged_from"] != newer || out["edited_by"] != "HUM-1" || out["revision"] != float64(2) {
		t.Fatalf("response marker: %v", out)
	}
	if got := storedBody(t, e, tid, older); got != "first part\n\nsecond part" {
		t.Fatalf("stored body %q", got)
	}
	if has(t, e, tid, newer) {
		t.Fatal("the source message is still stored: the merge did not delete it")
	}
	if rs := revisions(t, e, tid, older); len(rs) != 2 || rs[0].Body != "first part  " {
		t.Fatalf("register: %+v", rs)
	}

	f := readType(t, watcher, "message_merged")
	if f["msg_id"] != older || f["merged_from"] != newer || f["task_id"] != lobby {
		t.Fatalf("watcher frame: %v", f)
	}
	if inner, _ := f["envelope"].(map[string]any); inner["body"] != "first part\n\nsecond part" {
		t.Fatalf("frame body: %v", f["envelope"])
	}
	if g := readType(t, author, "message_merged"); g["merged_from"] != newer {
		t.Fatalf("author frame: %v", g)
	}

	_, feed := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+lobby, "HUM-2", nil)
	rows, _ := feed["messages"].([]any)
	if len(rows) != 1 {
		t.Fatalf("lobby after merge: %d rows, want 1: %v", len(rows), feed)
	}
}

// Merge with next: the source is the OLDER row, and its body still comes first.
func TestMergeMessageIntoNext(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	older, _ := postNote(t, author, "one")["msg_id"].(string)
	newer, _ := postNote(t, author, "two")["msg_id"].(string)

	if code, out := merge(t, e, tid, older, newer, "HUM-1"); code != http.StatusOK {
		t.Fatalf("merge: %d %v", code, out)
	}
	if got := storedBody(t, e, tid, newer); got != "one\n\ntwo" {
		t.Fatalf("kept body %q (older first)", got)
	}
	if has(t, e, tid, older) {
		t.Fatal("the source is still stored")
	}
}

// CONTROL — who may: another member is refused and nothing changes; the
// tenant admin may, as for a topic delete (specs/041 §3.3).
func TestMergeMessagePermissions(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	a, _ := postNote(t, author, "a")["msg_id"].(string)
	b, _ := postNote(t, author, "b")["msg_id"].(string)

	if code, out := merge(t, e, tid, b, a, "HUM-2"); code != http.StatusForbidden || out["error"] != "not_allowed" {
		t.Fatalf("another member: %d %v (want 403 not_allowed)", code, out)
	}
	if !has(t, e, tid, b) || storedBody(t, e, tid, a) != "a" {
		t.Fatal("a refused merge changed the rows")
	}
	if code, out := merge(t, e, tid, b, a, ""); code != http.StatusForbidden {
		t.Fatalf("no session: %d %v", code, out)
	}
	if code, out := merge(t, e, tid, b, a, "HUM-9"); code != http.StatusOK {
		t.Fatalf("an admin: %d %v", code, out)
	}
	if has(t, e, tid, b) || storedBody(t, e, tid, a) != "a\n\nb" {
		t.Fatal("the admin's merge did not land")
	}
}

// CONTROL — the pair: one thread, one author, two browser messages, two ids.
func TestMergeMessagePairRefusals(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	h1 := dialMember(t, e, tid, "HUM-1", "HUM-1")
	h2 := dialMember(t, e, tid, "HUM-2", "HUM-2")
	mine, _ := postNote(t, h1, "mine")["msg_id"].(string)
	theirs, _ := postNote(t, h2, "theirs")["msg_id"].(string)
	T := uuidV4()
	card := postIn(t, h1, T, "card", 1)
	reply := postIn(t, h1, T, "reply", 0)
	bot := putCard(t, e, tid, lobby, "", "HUM-1", "box-a", 1, time.Now().UTC())

	cases := []struct {
		name, src, into, want string
		code                  int
	}{
		{"another author's message", mine, theirs, "not_same_author", http.StatusConflict},
		{"another thread", reply, mine, "not_same_thread", http.StatusConflict},
		{"itself", mine, mine, "bad_json", http.StatusBadRequest},
		{"an unknown message", mine, uuidV4(), "not_found", http.StatusNotFound},
		{"a box-signed message", bot, mine, "not_editable", http.StatusConflict},
		{"the topic's card", card, reply, "is_card", http.StatusConflict},
	}
	for _, c := range cases {
		code, out := merge(t, e, tid, c.src, c.into, "HUM-1")
		if code != c.code || out["error"] != c.want {
			t.Fatalf("%s: %d %v (want %d %s)", c.name, code, out, c.code, c.want)
		}
	}
	for _, id := range []string{mine, theirs, card, reply, bot} {
		if !has(t, e, tid, id) {
			t.Fatalf("a refused merge deleted %s", id)
		}
	}
	if storedBody(t, e, tid, reply) != "reply" || storedBody(t, e, tid, card) != "card" {
		t.Fatal("a refused merge edited a row")
	}
	// CONTROL of the control: the reply folds into the card.
	if code, out := merge(t, e, tid, reply, card, "HUM-1"); code != http.StatusOK {
		t.Fatalf("reply into its card: %d %v", code, out)
	}
	if has(t, e, tid, reply) || storedBody(t, e, tid, card) != "card\n\nreply" {
		t.Fatal("reply into card did not land")
	}
}

// CONTROL — a source with a thread of its own is refused, in the store's
// transaction, and nothing is edited: the edit and the delete are one unit.
func TestMergeMessageHasReplies(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	keep, _ := postNote(t, author, "keep")["msg_id"].(string)
	src, _ := postNote(t, author, "src")["msg_id"].(string)
	thread := putCard(t, e, tid, src, lobby, "HUM-2", hub.WUIBox, 0, time.Now().UTC())

	code, out := merge(t, e, tid, src, keep, "HUM-1")
	if code != http.StatusConflict || out["error"] != "has_replies" {
		t.Fatalf("merge a message with replies: %d %v (want 409 has_replies)", code, out)
	}
	if !has(t, e, tid, src) || !has(t, e, tid, thread) || storedBody(t, e, tid, keep) != "keep" {
		t.Fatal("a refused merge changed the rows")
	}
	if rs := revisions(t, e, tid, keep); len(rs) != 0 {
		t.Fatalf("a refused merge wrote %d revision(s): the edit is not in the merge's transaction", len(rs))
	}
}

func TestMergeMessagePreflight(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+"/v1/messages/"+uuidV4()+"/merge", nil)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Access-Control-Request-Method", "POST")
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Methods") != "POST" {
		t.Fatalf("preflight: %d %q", resp.StatusCode, resp.Header.Get("Access-Control-Allow-Methods"))
	}
}
