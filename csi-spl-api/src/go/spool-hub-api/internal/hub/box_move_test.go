package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A box agent moves a topic to another channel by its task id (owner HUM-10,
// t1 b316397f) through the real front end (action.Move == `spool move`): the
// box twin of the browser's POST /v1/messages/{card}/move {to_channel}, with
// spec 041's rule read for an agent - the agent that started the topic, or an
// agent acting for a bound workspace owner / admin. Every refusal is a
// control: remove its guard in box_move.go and that case turns red. The
// browser path stays covered by message_move_test.go, unchanged.

type boxMoveRig struct {
	e                *env
	tid              string
	b, c             *box   // box-b seats CLE-08 and CLE-10; box-c seats CLE-09
	own, hum         string // topics in devel: own opened by CLE-08@box-b, hum by HUM-1 in the browser (to box-b)
	ownCard, humCard string
	admin, dev       string // two box-b operators: an admin and a developer
	roles            roleOf
}

func boxMoveEnv(t *testing.T) boxMoveRig {
	t.Helper()
	roles := roleOf{"HUM-8": rbac.BizOwner, "HUM-9": rbac.Admin}
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Authorizer = roles
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
	tid, _ := e.tenant()
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	g := boxMoveRig{e: e, tid: tid, roles: roles}
	g.b = e.box(tid, "box-b", "CLE-08", "CLE-10")
	g.c = e.box(tid, "box-c", "CLE-09")
	e.pin(tid, g.b)
	e.pin(tid, g.c)

	h := e.st.(store.Humans)
	admit := func(sub string) string {
		mail := sub + tid + "@example.com"
		if err := h.PutInvite(ctx, store.Invite{TenantID: tid, Email: mail, Role: "developer", InvitedBy: "operator",
			ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		id, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: sub + tid, Email: mail},
			tid, store.AdmitPolicy{BootstrapOwner: true}, now)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	g.admin, g.dev = admit("adm-"), admit("dev-")
	roles[g.admin], roles[g.dev] = rbac.Admin, rbac.Developer
	ops := e.st.(store.BoxOperators)
	for _, hm := range []string{g.admin, g.dev} {
		if err := ops.GrantBoxOperator(ctx, tid, "box-b", hm, "operator", now); err != nil {
			t.Fatal(err)
		}
	}
	everyone := []string{"HUM-1", "HUM-2", g.admin, g.dev}
	for ch, hums := range map[string][]string{"devel": everyone, "ops": everyone, "secret": {"HUM-2"}} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: "HUM-2", CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := e.st.AddChannelHumans(ctx, tid, ch, hums, "HUM-2", now); err != nil {
			t.Fatal(err)
		}
	}
	for _, seat := range [][2]string{{"devel", "CLE-08"}, {"ops", "CLE-08"}, {"ops", "CLE-10"}} {
		if err := e.st.InviteChannelAgent(ctx, tid, seat[0], "box-b", seat[1], now); err != nil {
			t.Fatal(err)
		}
	}
	put := func(task, from, fromBox, toBox string) string {
		t.Helper()
		id := uuidV4()
		m := store.Message{TenantID: tid, MsgID: id, TaskID: task, Channel: "devel", IsParent: 1,
			TS: now, FromBox: fromBox, FromID: from, ToBox: toBox, ToID: "ALL-0", Kind: "note", Body: "hello " + id,
			Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + id + `"}`),
			ReceivedAt: now, ExpiresAt: now.Add(30 * 24 * time.Hour)}
		if _, err := e.st.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return id
	}
	g.own, g.hum = uuidV4(), uuidV4()
	g.ownCard = put(g.own, "CLE-08", "box-b", hub.WUIBox)
	g.humCard = put(g.hum, "HUM-1", hub.WUIBox, "box-b") // addressed to box-b, so box-b reads it
	return g
}

func (g boxMoveRig) channelOf(t *testing.T, card string) string {
	t.Helper()
	m, err := g.e.st.GetEditable(context.Background(), g.tid, card, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m.Channel
}

func moveAnswer(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("answer %s: %v", raw, err)
	}
	return out
}

// The agent that started the topic moves it; the browser hears topic_moved;
// the row carries moved_by = the agent.
func TestBoxMoveStarterAgent(t *testing.T) {
	g := boxMoveEnv(t)
	ctx := context.Background()
	watcher := dialMember(t, g.e, g.tid, "HUM-2", "HUM-2")
	wsjson.Write(ctx, watcher, map[string]string{"type": "subscribe", "task_id": g.own}) //nolint:errcheck
	readType(t, watcher, "subscribed")

	raw, err := action.Move(ctx, g.b.cfg, action.MoveArgs{TaskID: g.own, Channel: "#ops", As: "CLE-08", Hub: g.b.c})
	if err != nil {
		t.Fatalf("move: %v", err)
	}
	out := moveAnswer(t, raw)
	if out["kind"] != "topic" || out["msg_id"] != g.ownCard || out["task_id"] != g.own || out["channel"] != "ops" ||
		out["from_channel"] != "devel" || out["moved_by"] != "CLE-08" || out["moved"] != true {
		t.Fatalf("move answer %v", out)
	}
	if ch := g.channelOf(t, g.ownCard); ch != "ops" {
		t.Fatalf("stored channel %q, want ops", ch)
	}
	m, _ := g.e.st.GetEditable(ctx, g.tid, g.ownCard, time.Now())
	if m.Move.By != "CLE-08" || m.Move.FromChannel != "devel" {
		t.Fatalf("move mark %+v", m.Move)
	}
	if f := readType(t, watcher, "topic_moved"); f["msg_id"] != g.ownCard || f["channel"] != "ops" || f["moved_by"] != "CLE-08" {
		t.Fatalf("browser frame %v", f)
	}
	// Back home clears the mark, like the browser's Undo.
	raw, err = action.Move(ctx, g.b.cfg, action.MoveArgs{TaskID: g.own, Channel: "devel", As: "CLE-08", Hub: g.b.c})
	if err != nil || moveAnswer(t, raw)["moved"] != false || g.channelOf(t, g.ownCard) != "devel" {
		t.Fatalf("move home: %s %v", raw, err)
	}
}

// An agent acting for a bound workspace admin moves a topic a human started.
func TestBoxMoveActingForAdmin(t *testing.T) {
	g := boxMoveEnv(t)
	ctx := context.Background()
	raw, err := action.Move(ctx, g.b.cfg, action.MoveArgs{TaskID: g.hum, Channel: "ops", As: "CLE-10", ActingFor: g.admin, Hub: g.b.c})
	if err != nil {
		t.Fatalf("move for admin: %v", err)
	}
	if out := moveAnswer(t, raw); out["moved_by"] != "CLE-10" || out["channel"] != "ops" {
		t.Fatalf("answer %v", out)
	}
	if ch := g.channelOf(t, g.humCard); ch != "ops" {
		t.Fatalf("stored channel %q, want ops", ch)
	}
}

func TestBoxMoveRefusals(t *testing.T) {
	g := boxMoveEnv(t)
	ctx := context.Background()
	refused := func(label, want string, in action.MoveArgs, bx *box) {
		t.Helper()
		in.Hub = bx.c
		if _, err := action.Move(ctx, bx.cfg, in); hubToken(err) != want {
			t.Fatalf("%s: want %s, got %v", label, want, err)
		}
		if g.channelOf(t, g.ownCard) != "devel" || g.channelOf(t, g.humCard) != "devel" {
			t.Fatalf("%s moved a topic", label)
		}
	}
	// Not the starter: another agent of the same box, and any agent on a
	// human's topic without an admin behind it.
	refused("same box, other agent", "not_allowed", action.MoveArgs{TaskID: g.own, Channel: "ops", As: "CLE-10"}, g.b)
	refused("human's topic, no acting-for", "not_allowed", action.MoveArgs{TaskID: g.hum, Channel: "ops", As: "CLE-08"}, g.b)
	// Acting for a bound developer is not acting for an admin.
	refused("acting for a developer", "not_allowed", action.MoveArgs{TaskID: g.hum, Channel: "ops", As: "CLE-08", ActingFor: g.dev}, g.b)
	// An admin who is not bound to this box: box-c has no operator.
	refused("acting for an unbound admin", "not_allowed", action.MoveArgs{TaskID: g.hum, Channel: "ops", As: "CLE-09", ActingFor: g.admin}, g.c)
	// An agent this box does not seat.
	refused("unannounced agent", hub.TokenFromNotAnnounced, action.MoveArgs{TaskID: g.own, Channel: "ops", As: "CLE-09"}, g.b)
	// A box that never saw the topic reads it as absent.
	refused("unread topic", "not_found", action.MoveArgs{TaskID: g.own, Channel: "ops", As: "CLE-09"}, g.c)
	// box-c never saw the human's topic; acting for a human does not open it
	// to a box without that human's binding (the binding is checked first).
	refused("unread human topic", "not_found", action.MoveArgs{TaskID: g.hum, Channel: "ops", As: "CLE-09"}, g.c)
	refused("unknown task", "not_found", action.MoveArgs{TaskID: uuidV4(), Channel: "ops", As: "CLE-08"}, g.b)
	refused("the lobby task", "lobby", action.MoveArgs{TaskID: lobby, Channel: "ops", As: "CLE-08"}, g.b)
	refused("into the lobby", "lobby", action.MoveArgs{TaskID: g.own, Channel: "lobby", As: "CLE-08"}, g.b)
	refused("same place", "same_place", action.MoveArgs{TaskID: g.own, Channel: "devel", As: "CLE-08"}, g.b)
	// The target door: a channel the agent is not in, one that does not
	// exist, a reserved one - all answer like a missing channel.
	refused("not a member of the target", "unknown_channel", action.MoveArgs{TaskID: g.own, Channel: "secret", As: "CLE-08"}, g.b)
	refused("no such channel", "unknown_channel", action.MoveArgs{TaskID: g.own, Channel: "nowhere", As: "CLE-08"}, g.b)
	refused("reserved channel", "unknown_channel", action.MoveArgs{TaskID: g.own, Channel: store.ChannelIssues, As: "CLE-08"}, g.b)
	// Acting for an admin does not open a channel the admin cannot read.
	refused("admin not in target", "unknown_channel", action.MoveArgs{TaskID: g.hum, Channel: "secret", As: "CLE-10", ActingFor: g.admin}, g.b)
}

// Cross-workspace: a box of another tenant cannot reach this tenant's topic,
// nor move its own topic into a channel only this tenant has.
func TestBoxMoveCrossWorkspace(t *testing.T) {
	g := boxMoveEnv(t)
	ctx := context.Background()
	other, _ := g.e.tenant()
	x := g.e.box(other, "box-b", "CLE-08")
	g.e.pin(other, x)
	if _, err := action.Move(ctx, x.cfg, action.MoveArgs{TaskID: g.own, Channel: "ops", As: "CLE-08", Hub: x.c}); hubToken(err) != "not_found" {
		t.Fatalf("another tenant's same-named box moved this tenant's topic: %v", err)
	}
	if g.channelOf(t, g.ownCard) != "devel" {
		t.Fatal("the topic moved across workspaces")
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	task, id := uuidV4(), uuidV4()
	m := store.Message{TenantID: other, MsgID: id, TaskID: task, Channel: "lobby", IsParent: 1,
		TS: now, FromBox: "box-b", FromID: "CLE-08", ToBox: hub.WUIBox, ToID: "ALL-0", Kind: "note", Body: "x",
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + id + `"}`),
		ReceivedAt: now, ExpiresAt: now.Add(time.Hour)}
	if _, err := g.e.st.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	if _, err := action.Move(ctx, x.cfg, action.MoveArgs{TaskID: task, Channel: "ops", As: "CLE-08", Hub: x.c}); hubToken(err) != "unknown_channel" {
		t.Fatalf("moved into another tenant's channel: %v", err)
	}
}

// The front end refuses a bad request before it dials.
func TestBoxMoveArgs(t *testing.T) {
	g := boxMoveEnv(t)
	ctx := context.Background()
	for label, in := range map[string]action.MoveArgs{
		"no task":        {Channel: "ops", As: "CLE-08"},
		"bad task":       {TaskID: "nope", Channel: "ops", As: "CLE-08"},
		"no channel":     {TaskID: g.own, As: "CLE-08"},
		"no agent":       {TaskID: g.own, Channel: "ops"},
		"bad acting-for": {TaskID: g.own, Channel: "ops", As: "CLE-08", ActingFor: "CLE-01"},
	} {
		in.Hub = g.b.c
		if _, err := action.Move(ctx, g.b.cfg, in); err == nil || hubToken(err) != "" {
			t.Fatalf("%s: want a local refusal, got %v", label, err)
		}
	}
}
