package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Owner, t1 ffc3b83c: "the humans should be able to move the bots msgs to a
// desired topic". Any member who may read the channel moves (or promotes) an
// AGENT's reply; a person's reply and an agent's topic keep 041's rule. Drop
// byAgent from mayReply in message_move.go and the member moves go red; widen
// it to every row and the person's-reply refusal goes red.
func TestMoveAgentReplyByAnyMember(t *testing.T) {
	g := moveEnv(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	put := func(task, from string, isParent, n int) string {
		t.Helper()
		id, at := uuidV4(), now.Add(time.Duration(10+n)*time.Second)
		m := store.Message{TenantID: g.tid, MsgID: id, TaskID: task, Channel: "devel", IsParent: isParent,
			TS: at, FromBox: "box-1", FromID: from, ToBox: "box-1", ToID: "ALL-0", Kind: "note", Body: "bot " + id,
			Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + id + `"}`),
			ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
		if _, err := g.e.st.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return id
	}
	bot := put(g.T, "c-004", 0, 0)
	legacy := put(g.T, "CLE-07", 0, 1)
	botTask := uuidV4()
	botCard := put(botTask, "c-004", 1, 2)
	to := func(task string) map[string]string { return map[string]string{"to_task": task} }

	// HUM-2 is a plain member: not the author of r3, not an admin.
	if code, out := g.move(t, g.r3, "HUM-2", to(g.U)); code != http.StatusForbidden || out["error"] != "not_allowed" {
		t.Fatalf("a member moved a person's reply: %d %v", code, out)
	}
	if code, out := g.move(t, botCard, "HUM-2", map[string]string{"to_channel": "ops"}); code != http.StatusForbidden {
		t.Fatalf("a member moved an agent's topic: %d %v", code, out)
	}
	if _, v := call(t, g.e, g.tid, http.MethodGet, "/v1/view/messages/"+bot+"/move", "HUM-2", nil); v["can_move"] != true {
		t.Fatalf("view can_move on an agent reply: %v", v)
	}
	if _, v := call(t, g.e, g.tid, http.MethodGet, "/v1/view/messages/"+g.r3+"/move", "HUM-2", nil); v["can_move"] != false {
		t.Fatalf("view can_move on a person's reply: %v", v)
	}
	if _, v := call(t, g.e, g.tid, http.MethodGet, "/v1/view/messages/"+botCard+"/move", "HUM-2", nil); v["can_move"] != false {
		t.Fatalf("view can_move on an agent's topic: %v", v)
	}

	// The member moves the agent's reply into U, and undoes it.
	code, out := g.move(t, bot, "HUM-2", to(g.U))
	if code != http.StatusOK || out["task_id"] != g.U || out["channel"] != "ops" {
		t.Fatalf("member move of an agent reply: %d %v", code, out)
	}
	if m := g.row(t, bot); m.TaskID != g.U || m.Move.FromTask != g.T {
		t.Fatalf("moved row: %+v", m)
	}
	if code, out := g.move(t, bot, "HUM-2", to(g.T)); code != http.StatusOK {
		t.Fatalf("member undo: %d %v", code, out)
	}
	// A legacy agent id counts as an agent too.
	if code, out := g.move(t, legacy, "HUM-9", to(g.U)); code != http.StatusOK {
		t.Fatalf("member move of a legacy agent reply: %d %v", code, out)
	}

	// Promote follows the same gate, and so does its undo.
	code, out = call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+bot+"/promote-topic", "HUM-2", map[string]any{})
	if code != http.StatusOK {
		t.Fatalf("member promote of an agent reply: %d %v", code, out)
	}
	code, out = call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+bot+"/promote-topic", "HUM-2", map[string]any{"undo": out["undo"]})
	if code != http.StatusOK {
		t.Fatalf("member undo of the promote: %d %v", code, out)
	}
	if code, out := call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+g.r3+"/promote-topic", "HUM-2", map[string]any{}); code != http.StatusForbidden {
		t.Fatalf("a member promoted a person's reply: %d %v", code, out)
	}
}
