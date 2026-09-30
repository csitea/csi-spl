package hub_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/coder/websocket/wsjson"
)

// 714c7028: the author, the tenant owner or an admin merges a whole topic into
// another topic they may post in; nobody else, and never an agent. The source
// opener is demoted to a reply so the target's card is not unseated, and the
// merged topic stays archivable (control: prd t1 e802196b). Every refusal is a
// guard in topic_merge.go: remove it and this goes red.
func TestMergeTopic(t *testing.T) {
	g := moveEnv(t)
	merge := func(id, as string, body any) (int, map[string]any) {
		t.Helper()
		return call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+id+"/merge-topic", as, body)
	}
	toU := map[string]any{"to_task": g.U}
	refused := []struct {
		name, id, as string
		body         any
		code         int
		token        string
	}{
		{"no session", g.card, "", toU, http.StatusForbidden, ""},
		{"a member who is not the author", g.card, "HUM-2", toU, http.StatusForbidden, "not_allowed"},
		{"a reply is not a card", g.r3, "HUM-1", toU, http.StatusConflict, "not_a_card"},
		{"into the same topic", g.card, "HUM-1", map[string]any{"to_task": g.T}, http.StatusConflict, "same_place"},
		{"into a topic that is not there", g.card, "HUM-1", map[string]any{"to_task": uuidV4()}, http.StatusNotFound, "not_found"},
		{"into a topic the mover cannot read", g.card, "HUM-1", map[string]any{"to_task": g.W}, http.StatusNotFound, "not_found"},
		{"no target", g.card, "HUM-1", map[string]any{}, http.StatusBadRequest, "bad_json"},
		{"both a target and an undo", g.card, "HUM-1", map[string]any{"to_task": g.U, "undo": map[string]any{"from_task": g.T}}, http.StatusBadRequest, "bad_json"},
	}
	for _, c := range refused {
		code, out := merge(c.id, c.as, c.body)
		if code != c.code || (c.token != "" && out["error"] != c.token) {
			t.Fatalf("%s: %d %v", c.name, code, out)
		}
	}
	if m := g.row(t, g.card); m.TaskID != g.T || m.Move.Moved() {
		t.Fatalf("a refusal merged the topic: %+v", m)
	}
	other, _ := g.e.tenant()
	if code, _ := call(t, g.e, other, http.MethodPost, "/v1/messages/"+g.card+"/merge-topic", "HUM-1", toU); code != http.StatusNotFound {
		t.Fatalf("another tenant's card: %d", code)
	}

	// A watcher of the source channel and one of the target channel both hear it.
	oldW := dialMember(t, g.e, g.tid, "HUM-2", "HUM-2")
	newW := dialMember(t, g.e, g.tid, "HUM-9", "HUM-9")
	wsjson.Write(context.Background(), oldW, map[string]string{"type": "subscribe", "channel": "devel"}) //nolint:errcheck
	readType(t, oldW, "subscribed")
	wsjson.Write(context.Background(), newW, map[string]string{"type": "subscribe", "channel": "ops"}) //nolint:errcheck
	readType(t, newW, "subscribed")

	// The author merges T into U: every row of T re-homed, the opener demoted.
	code, out := merge(g.card, "HUM-1", toU)
	if code != http.StatusOK || out["task_id"] != g.U || out["from_task"] != g.T || out["channel"] != "ops" ||
		out["from_channel"] != "devel" || out["merged"] != float64(4) {
		t.Fatalf("author merge: %d %v", code, out)
	}
	if ids, _ := out["msg_ids"].([]any); len(ids) != 4 {
		t.Fatalf("merged rows: %v", out["msg_ids"])
	}
	if u, _ := out["undo"].(map[string]any); u["from_task"] != g.T {
		t.Fatalf("undo: %v", out["undo"])
	}
	for _, id := range []string{g.card, g.r, g.r3, g.x1} {
		if m := g.row(t, id); m.Channel != "ops" || m.Move.By != "HUM-1" {
			t.Fatalf("row %s after the merge: %+v", id, m)
		}
	}
	if m := g.row(t, g.card); m.TaskID != g.U || m.ParentTaskID != "" || m.Move.FromTask != g.T {
		t.Fatalf("opener not re-homed: %+v", m)
	}
	for _, w := range []struct {
		name string
		f    map[string]any
	}{{"source channel", readType(t, oldW, "topic_merged")}, {"target channel", readType(t, newW, "topic_merged")}} {
		if w.f["msg_id"] != g.card || w.f["task_id"] != g.U || w.f["from_task"] != g.T || w.f["channel"] != "ops" {
			t.Fatalf("%s frame: %v", w.name, w.f)
		}
	}

	// The merged topic is still archivable though its oldest row is now the
	// demoted opener (older than U's card): the e802196b-shaped control.
	if code, _ := call(t, g.e, g.tid, http.MethodPut, "/v1/messages/"+g.uCard+"/archive", "HUM-2", nil); code != http.StatusOK {
		t.Fatalf("merged topic not archivable: %d", code)
	}
	if code, _ := call(t, g.e, g.tid, http.MethodDelete, "/v1/messages/"+g.uCard+"/archive", "HUM-2", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d", code)
	}

	// Undo puts the source topic back and re-seats its card.
	code, out = merge(g.card, "HUM-1", map[string]any{"undo": out["undo"]})
	if code != http.StatusOK || out["task_id"] != g.T {
		t.Fatalf("undo merge: %d %v", code, out)
	}
	if m := g.row(t, g.card); m.TaskID != g.T || m.Channel != "devel" || m.Move.Moved() {
		t.Fatalf("opener after undo: %+v", m)
	}
	// The restored source topic can be moved again - TaskCard resolves its card.
	if code, _ := g.move(t, g.card, "HUM-1", map[string]string{"to_channel": "ops"}); code != http.StatusOK {
		t.Fatalf("restored topic not a card: %d", code)
	}
}
