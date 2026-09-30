package hub_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/coder/websocket/wsjson"
)

// 8f588edd: the author, the tenant owner or an admin promotes a reply into a
// NEW topic of its own; nobody else, and never an agent. A card cannot be
// promoted (it is already a topic). The reply becomes the opening card of a
// fresh task in the same channel and its sub-thread moves with it, so the new
// topic is archivable at once; an undo re-seats the reply. Every refusal is a
// guard in topic_promote.go: remove it and this goes red.
func TestPromoteTopic(t *testing.T) {
	g := moveEnv(t)
	promote := func(id, as string, body any) (int, map[string]any) {
		t.Helper()
		return call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+id+"/promote-topic", as, body)
	}
	refused := []struct {
		name, id, as string
		body         any
		code         int
		token        string
	}{
		{"no session", g.r3, "", map[string]any{}, http.StatusForbidden, ""},
		{"a member who is not the author", g.r3, "HUM-2", map[string]any{}, http.StatusForbidden, "not_allowed"},
		{"a topic's card", g.card, "HUM-1", map[string]any{}, http.StatusConflict, "is_card"},
		{"an unknown field", g.r3, "HUM-1", map[string]any{"to_task": g.U}, http.StatusBadRequest, "bad_json"},
		{"an empty undo", g.r3, "HUM-1", map[string]any{"undo": map[string]any{"from_task": g.T, "msg_ids": []string{}}}, http.StatusBadRequest, "bad_json"},
	}
	for _, c := range refused {
		code, out := promote(c.id, c.as, c.body)
		if code != c.code || (c.token != "" && out["error"] != c.token) {
			t.Fatalf("%s: %d %v", c.name, code, out)
		}
	}
	if m := g.row(t, g.r3); m.TaskID != g.T || m.Move.Moved() {
		t.Fatalf("a refusal promoted the message: %+v", m)
	}
	other, _ := g.e.tenant()
	if code, _ := call(t, g.e, other, http.MethodPost, "/v1/messages/"+g.r3+"/promote-topic", "HUM-1", map[string]any{}); code != http.StatusNotFound {
		t.Fatalf("another tenant's row: %d", code)
	}

	// A watcher of the message's channel hears it (old topic and new both there).
	watcher := dialMember(t, g.e, g.tid, "HUM-9", "HUM-9")
	wsjson.Write(context.Background(), watcher, map[string]string{"type": "subscribe", "channel": "devel"}) //nolint:errcheck
	readType(t, watcher, "subscribed")

	// The author promotes r3 (and its thread x1) into a new topic.
	code, out := promote(g.r3, "HUM-1", map[string]any{})
	newTask, _ := out["task_id"].(string)
	if code != http.StatusOK || newTask == "" || newTask == g.T || out["from_task"] != g.T || out["channel"] != "devel" {
		t.Fatalf("author promote: %d %v", code, out)
	}
	ids, _ := out["msg_ids"].([]any)
	if len(ids) != 2 {
		t.Fatalf("promoted rows: %v", out["msg_ids"])
	}
	u, _ := out["undo"].(map[string]any)
	if u["from_task"] != newTask {
		t.Fatalf("undo: %v", out["undo"])
	}
	if m := g.row(t, g.r3); m.TaskID != newTask || m.ParentTaskID != "" || m.Channel != "devel" || m.Move.FromTask != g.T {
		t.Fatalf("promoted card: %+v", m)
	}
	if m := g.row(t, g.x1); m.TaskID != g.r3 || m.ParentTaskID != newTask || m.Channel != "devel" || m.Move.Moved() {
		t.Fatalf("its thread: %+v", m)
	}
	if f := readType(t, watcher, "topic_promoted"); f["msg_id"] != g.r3 || f["task_id"] != newTask || f["from_task"] != g.T {
		t.Fatalf("frame: %v", f)
	}
	// The new topic reads as a topic: its card at top level, the promoted
	// message's own thread (x1) nested under it, not a second top-level row.
	_, feed := call(t, g.e, g.tid, http.MethodGet, "/v1/view/topics/"+newTask, "HUM-2", nil)
	rows, _ := feed["messages"].([]any)
	if len(rows) != 1 {
		t.Fatalf("new topic read: %v", feed)
	}
	if v, _ := rows[0].(map[string]any); v["is_parent"] != float64(1) || v["task_id"] != newTask || v["moved_from_task"] != g.T {
		t.Fatalf("new topic card: %v", rows[0])
	}
	// The new topic is archivable at once (its card is is_parent 1, first).
	if code, _ := call(t, g.e, g.tid, http.MethodPut, "/v1/messages/"+g.r3+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("new topic not archivable: %d", code)
	}
	if code, _ := call(t, g.e, g.tid, http.MethodDelete, "/v1/messages/"+g.r3+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d", code)
	}

	// Undo re-seats r3 as a reply of its old topic and takes its thread back.
	code, out = promote(g.r3, "HUM-1", map[string]any{"undo": u})
	if code != http.StatusOK || out["task_id"] != g.T || out["from_task"] != newTask {
		t.Fatalf("undo promote: %d %v", code, out)
	}
	if m := g.row(t, g.r3); m.TaskID != g.T || m.Move.Moved() {
		t.Fatalf("reply after undo: %+v", m)
	}
	if m := g.row(t, g.x1); m.TaskID != g.r3 || m.ParentTaskID != g.T {
		t.Fatalf("thread after undo: %+v", m)
	}
	// The restored reply can be promoted again.
	if code, _ := promote(g.r3, "HUM-1", map[string]any{}); code != http.StatusOK {
		t.Fatalf("restored reply not promotable: %d", code)
	}

	// The tenant owner and an admin may promote a reply they did not write.
	if code, _ := promote(g.r, "HUM-8", map[string]any{}); code != http.StatusOK {
		t.Fatalf("owner promote: %d", code)
	}
}

func TestPromotePreflight(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+"/v1/messages/"+uuidV4()+"/promote-topic", nil)
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
