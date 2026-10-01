package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-1024 (specs/045 contracts/move-v1.md). The author, the tenant owner or
// an admin moves a topic into a channel they may post in, or a reply into a
// topic they may read and post in; nobody else, and never an agent. Every
// refusal is a control: remove its guard in message_move.go and the test
// goes red.

type moveRig struct {
	e                *env
	tid              string
	T, U, W          string // topics: T in devel (HUM-1), U in ops (HUM-2), W in secret (HUM-2)
	card, r, r3      string // T's card (HUM-1), a reply by HUM-2, a reply by HUM-1
	uCard, wCard, x1 string // U's and W's cards, a thread row on r3
}

// moveEnv is archiveEnv plus three created channels: devel and ops hold every
// human of the test, secret only HUM-2.
func moveEnv(t *testing.T) moveRig {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	everyone := []string{"HUM-1", "HUM-2", "HUM-8", "HUM-9"}
	for ch, hums := range map[string][]string{"devel": everyone, "ops": everyone, "secret": {"HUM-2"}} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: "HUM-2", CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := e.st.AddChannelHumans(ctx, tid, ch, hums, "HUM-2", now); err != nil {
			t.Fatal(err)
		}
	}
	g := moveRig{e: e, tid: tid, T: uuidV4(), U: uuidV4(), W: uuidV4()}
	put := func(task, parent, channel, from string, isParent, n int) string {
		t.Helper()
		id, at := uuidV4(), now.Add(time.Duration(n)*time.Second)
		m := store.Message{TenantID: tid, MsgID: id, TaskID: task, ParentTaskID: parent, Channel: channel, IsParent: isParent,
			TS: at, FromBox: hub.WUIBox, FromID: from, ToBox: hub.WUIBox, ToID: "ALL-0", Kind: "note", Body: "hello " + id,
			Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + id + `"}`),
			ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
		if _, err := e.st.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return id
	}
	g.card = put(g.T, "", "devel", "HUM-1", 1, 0)
	g.r = put(g.T, "", "devel", "HUM-2", 0, 1)
	g.r3 = put(g.T, "", "devel", "HUM-1", 0, 2)
	g.x1 = put(g.r3, g.T, "devel", "HUM-2", 0, 3)
	g.uCard = put(g.U, "", "ops", "HUM-2", 1, 4)
	g.wCard = put(g.W, "", "secret", "HUM-2", 1, 5)
	return g
}

func (g moveRig) row(t *testing.T, id string) store.EditableMessage {
	t.Helper()
	m, err := g.e.st.GetEditable(context.Background(), g.tid, id, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func (g moveRig) move(t *testing.T, id, as string, body map[string]string) (int, map[string]any) {
	t.Helper()
	return call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+id+"/move", as, body)
}

func TestMoveTopicPermissionsAndRefusals(t *testing.T) {
	g := moveEnv(t)
	to := func(ch string) map[string]string { return map[string]string{"to_channel": ch} }
	refused := []struct {
		name, id, as string
		body         map[string]string
		code         int
		token        string
	}{
		{"no session", g.card, "", to("ops"), http.StatusForbidden, ""},
		{"a member who is not the author", g.card, "HUM-2", to("ops"), http.StatusForbidden, "not_allowed"},
		{"a reply is not a card", g.r3, "HUM-1", to("ops"), http.StatusConflict, "not_a_card"},
		{"a members-only channel the mover is not in", g.card, "HUM-1", to("secret"), http.StatusNotFound, "unknown_channel"},
		{"a channel that does not exist", g.card, "HUM-1", to("nope"), http.StatusNotFound, "unknown_channel"},
		{"the reserved issues channel", g.card, "HUM-1", to("issues"), http.StatusNotFound, "unknown_channel"},
		{"the lobby", g.card, "HUM-1", to("lobby"), http.StatusConflict, "lobby"},
		{"the same channel", g.card, "HUM-1", to("#Devel"), http.StatusConflict, "same_place"},
		{"no target", g.card, "HUM-1", map[string]string{}, http.StatusBadRequest, "bad_json"},
		{"two targets", g.card, "HUM-1", map[string]string{"to_channel": "ops", "to_task": g.U}, http.StatusBadRequest, "bad_json"},
	}
	for _, c := range refused {
		code, out := g.move(t, c.id, c.as, c.body)
		if code != c.code || (c.token != "" && out["error"] != c.token) {
			t.Fatalf("%s: %d %v", c.name, code, out)
		}
	}
	if m := g.row(t, g.card); m.Channel != "devel" || m.Move.Moved() {
		t.Fatalf("a refusal moved the topic: %+v", m)
	}
	other, _ := g.e.tenant()
	if code, _ := call(t, g.e, other, http.MethodPost, "/v1/messages/"+g.card+"/move", "HUM-1", to("ops")); code != http.StatusNotFound {
		t.Fatalf("another tenant's card: %d", code)
	}

	// What the menu may offer.
	if code, out := call(t, g.e, g.tid, http.MethodGet, "/v1/view/messages/"+g.card+"/move", "HUM-2", nil); code != http.StatusOK || out["can_move"] != false || out["is_card"] != true {
		t.Fatalf("move info for a member: %d %v", code, out)
	}
	if _, out := call(t, g.e, g.tid, http.MethodGet, "/v1/view/messages/"+g.card+"/move", "HUM-1", nil); out["can_move"] != true {
		t.Fatalf("move info for the author: %v", out)
	}

	// A watcher of the NEW channel and one of the OLD channel both hear it.
	oldW := dialMember(t, g.e, g.tid, "HUM-2", "HUM-2")
	newW := dialMember(t, g.e, g.tid, "HUM-9", "HUM-9")
	wsjson.Write(context.Background(), oldW, map[string]string{"type": "subscribe", "channel": "devel"}) //nolint:errcheck
	readType(t, oldW, "subscribed")
	wsjson.Write(context.Background(), newW, map[string]string{"type": "subscribe", "channel": "ops"}) //nolint:errcheck
	readType(t, newW, "subscribed")

	// The author moves T to ops: every row of the topic, nothing else.
	code, out := g.move(t, g.card, "HUM-1", to("ops"))
	if code != http.StatusOK || out["channel"] != "ops" || out["from_channel"] != "devel" || out["moved"] != true {
		t.Fatalf("author move: %d %v", code, out)
	}
	if u, _ := out["undo"].(map[string]any); u["to_channel"] != "devel" {
		t.Fatalf("undo: %v", out["undo"])
	}
	if ids, _ := out["msg_ids"].([]any); len(ids) != 4 {
		t.Fatalf("moved rows: %v", out["msg_ids"])
	}
	for _, id := range []string{g.card, g.r, g.r3, g.x1} {
		if m := g.row(t, id); m.Channel != "ops" || m.Move.FromChannel != "devel" || m.Move.By != "HUM-1" {
			t.Fatalf("row %s after the move: %+v", id, m)
		}
	}
	if m := g.row(t, g.uCard); m.Move.Moved() {
		t.Fatal("a row outside the topic was marked")
	}
	for _, w := range []struct {
		name string
		f    map[string]any
	}{{"old channel", readType(t, oldW, "topic_moved")}, {"new channel", readType(t, newW, "topic_moved")}} {
		if w.f["msg_id"] != g.card || w.f["channel"] != "ops" || w.f["from_channel"] != "devel" || w.f["task_id"] != g.T {
			t.Fatalf("%s frame: %v", w.name, w.f)
		}
	}
	// The view element carries the override beside the envelope.
	_, feed := call(t, g.e, g.tid, http.MethodGet, "/v1/view/topics/"+g.T, "HUM-2", nil)
	rows, _ := feed["messages"].([]any)
	if len(rows) != 3 {
		t.Fatalf("topic read: %v", feed)
	}
	for _, raw := range rows {
		v, _ := raw.(map[string]any)
		if v["channel"] != "ops" || v["moved_from_channel"] != "devel" || v["task_id"] != g.T || v["moved_by"] != "HUM-1" {
			t.Fatalf("view element: %v", v)
		}
	}

	// §3.7: a reply that still carries the old tag follows the topic.
	author := dialMember(t, g.e, g.tid, "HUM-1", "HUM-1")
	wsjson.Write(context.Background(), author, map[string]any{"type": "send", "task_id": g.T, "channel": "devel", "body": "late reply", "is_parent": 0}) //nolint:errcheck
	ack := readType(t, author, "ack")
	id, _ := ack["msg_id"].(string)
	if id == "" {
		t.Fatalf("late reply: %v", ack)
	}
	if m := g.row(t, id); m.Channel != "ops" {
		t.Fatalf("a reply with the old tag was stored in %q", m.Channel)
	}

	// Undo: back home clears the mark, and the override goes with it.
	code, out = g.move(t, g.card, "HUM-1", to("devel"))
	if code != http.StatusOK || out["moved"] != false {
		t.Fatalf("undo: %d %v", code, out)
	}
	if m := g.row(t, g.r); m.Channel != "devel" || m.Move.Moved() {
		t.Fatalf("row after undo: %+v", m)
	}
	_, feed = call(t, g.e, g.tid, http.MethodGet, "/v1/view/topics/"+g.T, "HUM-2", nil)
	rows, _ = feed["messages"].([]any)
	// The stub env names no channel, so the row's own channel rides beside it
	// (CLE-77845) - home, never the old override.
	if v, _ := rows[0].(map[string]any); (v["channel"] != nil && v["channel"] != "devel") || v["moved_at"] != nil {
		t.Fatalf("a row back home still carries an override: %v", v)
	}

	// The tenant owner and an admin may move a topic they did not write.
	if code, out := g.move(t, g.uCard, "HUM-8", to("devel")); code != http.StatusOK {
		t.Fatalf("owner move: %d %v", code, out)
	}
	if code, out := g.move(t, g.uCard, "HUM-9", to("ops")); code != http.StatusOK {
		t.Fatalf("admin move: %d %v", code, out)
	}
}

func TestMoveMessagePermissionsAndRefusals(t *testing.T) {
	g := moveEnv(t)
	to := func(task string) map[string]string { return map[string]string{"to_task": task} }
	refused := []struct {
		name, id, as string
		body         map[string]string
		code         int
		token        string
	}{
		{"no session", g.r, "", to(g.U), http.StatusForbidden, ""},
		{"a member who is not the author", g.r3, "HUM-2", to(g.U), http.StatusForbidden, "not_allowed"},
		{"a topic's card", g.card, "HUM-1", to(g.U), http.StatusConflict, "is_card"},
		{"the same topic", g.r3, "HUM-1", to(g.T), http.StatusConflict, "same_place"},
		{"the lobby", g.r3, "HUM-1", to(lobby), http.StatusConflict, "lobby"},
		{"a topic the mover may not read", g.r3, "HUM-1", to(g.W), http.StatusNotFound, "not_found"},
		{"a task that does not exist", g.r3, "HUM-1", to(uuidV4()), http.StatusNotFound, "not_found"},
		{"a thread that has no card", g.r, "HUM-2", to(g.r3), http.StatusConflict, "not_a_card"},
		{"not a uuid", g.r3, "HUM-1", to("nope"), http.StatusBadRequest, "bad_json"},
	}
	for _, c := range refused {
		code, out := g.move(t, c.id, c.as, c.body)
		if code != c.code || (c.token != "" && out["error"] != c.token) {
			t.Fatalf("%s: %d %v", c.name, code, out)
		}
	}
	if m := g.row(t, g.r3); m.TaskID != g.T || m.Move.Moved() {
		t.Fatalf("a refusal moved the message: %+v", m)
	}

	watcher := dialMember(t, g.e, g.tid, "HUM-9", "HUM-9")
	wsjson.Write(context.Background(), watcher, map[string]string{"type": "subscribe", "task_id": g.U}) //nolint:errcheck
	readType(t, watcher, "subscribed")

	// The author moves r3 (and its thread x1) into U.
	code, out := g.move(t, g.r3, "HUM-1", to(g.U))
	if code != http.StatusOK || out["task_id"] != g.U || out["from_task"] != g.T || out["channel"] != "ops" || out["moved"] != true {
		t.Fatalf("author move: %d %v", code, out)
	}
	if u, _ := out["undo"].(map[string]any); u["to_task"] != g.T {
		t.Fatalf("undo: %v", out["undo"])
	}
	if m := g.row(t, g.r3); m.TaskID != g.U || m.Channel != "ops" || m.Move.FromTask != g.T {
		t.Fatalf("moved row: %+v", m)
	}
	if m := g.row(t, g.x1); m.ParentTaskID != g.U || m.Channel != "ops" {
		t.Fatalf("its thread: %+v", m)
	}
	if f := readType(t, watcher, "message_moved"); f["msg_id"] != g.r3 || f["task_id"] != g.U || f["from_task"] != g.T {
		t.Fatalf("frame: %v", f)
	}
	_, feed := call(t, g.e, g.tid, http.MethodGet, "/v1/view/topics/"+g.U, "HUM-2", nil)
	rows, _ := feed["messages"].([]any)
	if len(rows) != 2 {
		t.Fatalf("U after the move: %v", feed)
	}
	if v, _ := rows[1].(map[string]any); v["task_id"] != g.U || v["moved_from_task"] != g.T || v["parent_task_id"] != "" {
		t.Fatalf("moved view element: %v", v)
	}
	// The owner moves someone else's reply; undo takes r3 home.
	if code, out := g.move(t, g.r, "HUM-8", to(g.U)); code != http.StatusOK {
		t.Fatalf("owner move: %d %v", code, out)
	}
	if code, out := g.move(t, g.r3, "HUM-1", to(g.T)); code != http.StatusOK || out["moved"] != false {
		t.Fatalf("undo: %d %v", code, out)
	}
	if m := g.row(t, g.r3); m.TaskID != g.T || m.Channel != "devel" || m.Move.Moved() {
		t.Fatalf("row home: %+v", m)
	}
}

func TestMovePreflight(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+"/v1/messages/"+uuidV4()+"/move", nil)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Access-Control-Request-Method", "POST")
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Methods") != "POST" ||
		resp.Header.Get("Access-Control-Allow-Headers") != "Authorization, Content-Type, X-Locale" {
		t.Fatalf("preflight: %d %q", resp.StatusCode, resp.Header.Get("Access-Control-Allow-Methods"))
	}
}

// §3.7: an agent that has not seen the move replies with the old channel in
// its signed tag. The reply is stored in the topic's channel now; the control
// is the same reply on an unmoved topic, which keeps its tag.
func TestMoveBoxReplyFollowsTopic(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	b := e.box(tid, "box-b", "CLE-07")
	for _, ch := range []string{"old", "new"} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: "wui", CreatedAt: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	e.pin(tid, b)
	if err := e.st.InviteChannelAgent(ctx, tid, "old", "box-b", "CLE-07", time.Now()); err != nil {
		t.Fatal(err)
	}
	post := func(task, body string) action.SendResult {
		t.Helper()
		out, err := action.SendCtx(ctx, b.cfg, action.SendArgs{From: "CLE-07", Channel: "old", TaskID: task, Body: body, Hub: b.c})
		if err != nil {
			t.Fatalf("%s: %v", body, err)
		}
		return out
	}
	stored := func(id string) store.EditableMessage {
		t.Helper()
		m, err := e.st.GetEditable(ctx, tid, id, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		return m
	}
	moved, kept := post("", "a topic that moves"), post("", "a topic that stays")
	if _, err := e.st.MoveTopic(ctx, tid, moved.MsgID, moved.TaskID, "new", "HUM-1", time.Now()); err != nil {
		t.Fatal(err)
	}
	if m := stored(post(moved.TaskID, "late reply").MsgID); m.Channel != "new" || m.TaskID != moved.TaskID {
		t.Fatalf("a stale-tag reply on a moved topic: channel %q task %s", m.Channel, m.TaskID)
	}
	if m := stored(post(kept.TaskID, "control reply").MsgID); m.Channel != "old" {
		t.Fatalf("control: a reply on an unmoved topic lost its tag: %q", m.Channel)
	}
}
