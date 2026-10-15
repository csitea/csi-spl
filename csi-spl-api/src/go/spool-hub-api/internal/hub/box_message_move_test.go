package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A box agent moves ONE message into another topic by its msg id (SPL-1988,
// owner HUM-10, t1 69fd5022) through the real front end (action.MoveMsg ==
// `spool move --msg`): the box twin of the browser's POST
// /v1/messages/{msg_id}/move {to_task}, with spec 045's rule read for an
// agent - an agent's message by any agent that reaches it, a person's only
// for a bound workspace owner / admin. Every refusal is a control: remove its
// guard in box_message_move.go and that case turns red. The browser path
// stays covered by message_move_test.go, unchanged.

type boxMsgMoveRig struct {
	boxMoveRig
	botReply, humReply, dm, lobbyRow string // rows to move: replies in g.own, a DM, a lobby row
	secret, dmTask                   string // target topics: a #secret card box-b reads, a DM topic
}

func boxMsgMoveEnv(t *testing.T) boxMsgMoveRig {
	t.Helper()
	g := boxMsgMoveRig{boxMoveRig: boxMoveEnv(t)}
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	n := 0
	put := func(task, channel string, isParent int, from, fromBox, to, toBox string) string {
		t.Helper()
		n++
		id, at := uuidV4(), now.Add(time.Duration(n)*time.Second)
		m := store.Message{TenantID: g.tid, MsgID: id, TaskID: task, Channel: channel, IsParent: isParent,
			TS: at, FromBox: fromBox, FromID: from, ToBox: toBox, ToID: to, Kind: "note", Body: "row " + id,
			Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + id + `"}`),
			ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
		if _, err := g.e.st.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return id
	}
	// An agent of ANOTHER box replies in CLE-08's topic; a person replies too.
	g.botReply = put(g.own, "devel", 0, "CLE-09", "box-c", "ALL-0", hub.WUIBox)
	g.humReply = put(g.own, "devel", 0, "HUM-1", hub.WUIBox, "ALL-0", hub.WUIBox)
	g.dm = put(g.own, "", 0, "CLE-08", "box-b", "CLE-10", "box-b")
	g.lobbyRow = put(lobby, "lobby", 0, "CLE-08", "box-b", "ALL-0", hub.WUIBox)
	g.secret = uuidV4()
	put(g.secret, "secret", 1, "HUM-2", hub.WUIBox, "ALL-0", "box-b") // box-b reads it; CLE-08 is not in #secret
	g.dmTask = uuidV4()
	put(g.dmTask, "", 1, "CLE-10", "box-b", "CLE-08", "box-b")
	return g
}

func (g boxMsgMoveRig) taskOf(t *testing.T, id string) string {
	t.Helper()
	m, err := g.e.st.GetEditable(context.Background(), g.tid, id, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m.TaskID
}

// Any agent that reaches an agent's message moves it: CLE-08 (a #devel
// member) moves CLE-09@box-c's reply into another topic; the browser hears
// message_moved; the row carries moved_by = CLE-08. Back home clears the mark.
func TestBoxMessageMoveAgentReply(t *testing.T) {
	g := boxMsgMoveEnv(t)
	ctx := context.Background()
	watcher := dialMember(t, g.e, g.tid, "HUM-2", "HUM-2")
	wsjson.Write(ctx, watcher, map[string]string{"type": "subscribe", "task_id": g.hum}) //nolint:errcheck
	readType(t, watcher, "subscribed")

	raw, err := action.MoveMsg(ctx, g.b.cfg, action.MoveMsgArgs{MsgID: g.botReply, ToTask: g.hum, As: "CLE-08", Hub: g.b.c})
	if err != nil {
		t.Fatalf("move: %v", err)
	}
	out := moveAnswer(t, raw)
	if out["kind"] != "message" || out["msg_id"] != g.botReply || out["task_id"] != g.hum || out["from_task"] != g.own ||
		out["channel"] != "devel" || out["moved_by"] != "CLE-08" || out["moved"] != true {
		t.Fatalf("move answer %v", out)
	}
	if task := g.taskOf(t, g.botReply); task != g.hum {
		t.Fatalf("stored task %q, want %q", task, g.hum)
	}
	m, _ := g.e.st.GetEditable(ctx, g.tid, g.botReply, time.Now())
	if m.Move.By != "CLE-08" || m.Move.FromTask != g.own {
		t.Fatalf("move mark %+v", m.Move)
	}
	if f := readType(t, watcher, "message_moved"); f["msg_id"] != g.botReply || f["task_id"] != g.hum || f["moved_by"] != "CLE-08" {
		t.Fatalf("browser frame %v", f)
	}
	raw, err = action.MoveMsg(ctx, g.b.cfg, action.MoveMsgArgs{MsgID: g.botReply, ToTask: g.own, As: "CLE-08", Hub: g.b.c})
	if err != nil || moveAnswer(t, raw)["moved"] != false || g.taskOf(t, g.botReply) != g.own {
		t.Fatalf("move home: %s %v", raw, err)
	}
}

// An agent acting for a bound workspace admin moves a person's message; the
// agent is not in #devel, the admin reads it.
func TestBoxMessageMoveActingForAdmin(t *testing.T) {
	g := boxMsgMoveEnv(t)
	ctx := context.Background()
	raw, err := action.MoveMsg(ctx, g.b.cfg, action.MoveMsgArgs{MsgID: g.humReply, ToTask: g.hum, As: "CLE-10", ActingFor: g.admin, Hub: g.b.c})
	if err != nil {
		t.Fatalf("move for admin: %v", err)
	}
	if out := moveAnswer(t, raw); out["moved_by"] != "CLE-10" || out["task_id"] != g.hum {
		t.Fatalf("answer %v", out)
	}
	if task := g.taskOf(t, g.humReply); task != g.hum {
		t.Fatalf("stored task %q, want %q", task, g.hum)
	}
}

func TestBoxMessageMoveRefusals(t *testing.T) {
	g := boxMsgMoveEnv(t)
	ctx := context.Background()
	rows := map[string]string{g.botReply: g.own, g.humReply: g.own, g.dm: g.own, g.lobbyRow: lobby, g.ownCard: g.own}
	refused := func(label, want string, in action.MoveMsgArgs, bx *box) {
		t.Helper()
		in.Hub = bx.c
		if _, err := action.MoveMsg(ctx, bx.cfg, in); hubToken(err) != want {
			t.Fatalf("%s: want %s, got %v", label, want, err)
		}
		for id, task := range rows {
			if g.taskOf(t, id) != task {
				t.Fatalf("%s moved %s", label, id)
			}
		}
	}
	// A person's message: no acting-for, a bound developer, an unbound admin.
	refused("person's message, no acting-for", "not_allowed", action.MoveMsgArgs{MsgID: g.humReply, ToTask: g.hum, As: "CLE-08"}, g.b)
	refused("acting for a developer", "not_allowed", action.MoveMsgArgs{MsgID: g.humReply, ToTask: g.hum, As: "CLE-08", ActingFor: g.dev}, g.b)
	refused("acting for an unbound admin", "not_allowed", action.MoveMsgArgs{MsgID: g.botReply, ToTask: g.hum, As: "CLE-09", ActingFor: g.admin}, g.c)
	refused("unannounced agent", hub.TokenFromNotAnnounced, action.MoveMsgArgs{MsgID: g.botReply, ToTask: g.hum, As: "CLE-09"}, g.b)
	// The read door: box-c never got the person's reply and CLE-09 is not in #devel.
	refused("unreached message", "not_found", action.MoveMsgArgs{MsgID: g.humReply, ToTask: g.hum, As: "CLE-09"}, g.c)
	refused("unknown message", "not_found", action.MoveMsgArgs{MsgID: uuidV4(), ToTask: g.hum, As: "CLE-08"}, g.b)
	// The row refusals, the browser's tokens.
	refused("a lobby row", "lobby", action.MoveMsgArgs{MsgID: g.lobbyRow, ToTask: g.hum, As: "CLE-08"}, g.b)
	refused("a DM row", "not_in_channel", action.MoveMsgArgs{MsgID: g.dm, ToTask: g.hum, As: "CLE-08"}, g.b)
	refused("a topic's card", "is_card", action.MoveMsgArgs{MsgID: g.ownCard, ToTask: g.hum, As: "CLE-08"}, g.b)
	refused("same topic", "same_place", action.MoveMsgArgs{MsgID: g.botReply, ToTask: g.own, As: "CLE-08"}, g.b)
	refused("into the lobby", "lobby", action.MoveMsgArgs{MsgID: g.botReply, ToTask: lobby, As: "CLE-08"}, g.b)
	// The target: absent, unreached, a DM, a channel the agent may not post in.
	refused("unknown target", "not_found", action.MoveMsgArgs{MsgID: g.botReply, ToTask: uuidV4(), As: "CLE-08"}, g.b)
	refused("unreached target", "not_found", action.MoveMsgArgs{MsgID: g.botReply, ToTask: g.secret, As: "CLE-09"}, g.c)
	refused("a DM target", "not_in_channel", action.MoveMsgArgs{MsgID: g.botReply, ToTask: g.dmTask, As: "CLE-08"}, g.b)
	refused("target channel not postable", "unknown_channel", action.MoveMsgArgs{MsgID: g.botReply, ToTask: g.secret, As: "CLE-08"}, g.b)
	refused("admin not in target", "unknown_channel", action.MoveMsgArgs{MsgID: g.humReply, ToTask: g.secret, As: "CLE-10", ActingFor: g.admin}, g.b)
}

// Cross-workspace: a box of another tenant cannot reach this tenant's message.
func TestBoxMessageMoveCrossWorkspace(t *testing.T) {
	g := boxMsgMoveEnv(t)
	ctx := context.Background()
	other, _ := g.e.tenant()
	x := g.e.box(other, "box-b", "CLE-08")
	g.e.pin(other, x)
	if _, err := action.MoveMsg(ctx, x.cfg, action.MoveMsgArgs{MsgID: g.botReply, ToTask: g.hum, As: "CLE-08", Hub: x.c}); hubToken(err) != "not_found" {
		t.Fatalf("another tenant's same-named box moved this tenant's message: %v", err)
	}
	if g.taskOf(t, g.botReply) != g.own {
		t.Fatal("the message moved across workspaces")
	}
}

// The front end refuses a bad request before it dials.
func TestBoxMessageMoveArgs(t *testing.T) {
	g := boxMsgMoveEnv(t)
	ctx := context.Background()
	for label, in := range map[string]action.MoveMsgArgs{
		"no msg":         {ToTask: g.hum, As: "CLE-08"},
		"bad msg":        {MsgID: "nope", ToTask: g.hum, As: "CLE-08"},
		"no to-task":     {MsgID: g.botReply, As: "CLE-08"},
		"no agent":       {MsgID: g.botReply, ToTask: g.hum},
		"bad acting-for": {MsgID: g.botReply, ToTask: g.hum, As: "CLE-08", ActingFor: "CLE-01"},
	} {
		in.Hub = g.b.c
		if _, err := action.MoveMsg(ctx, g.b.cfg, in); err == nil || hubToken(err) != "" {
			t.Fatalf("%s: want a local refusal, got %v", label, err)
		}
	}
}
