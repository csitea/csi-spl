package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// CLE-34978: a box frame carries no level, so every agent line was stored as
// is_parent 1 - an agent's answer in a channel thread showed up in the channel
// feed as a new post. A box line on a task whose topic root is in a channel is
// now a reply (0). Controls: a box line opening a new task, a box reply under
// a DM topic and a box line on the lobby task all stay 1.
func TestBoxReplyLevel(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	w := dialWUI(t, e, tid, "HUM-1")
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	topic := func(task, channel string) {
		t.Helper()
		f := map[string]any{"type": "send", "task_id": task, "body": "L1", "is_parent": 1}
		if channel != "" {
			f["channel"] = channel
		}
		w.send(f)
		if ack := w.read("ack"); ack.MsgID == "" {
			t.Fatalf("ack %+v", ack)
		}
	}
	boxSend := func(task string) string {
		t.Helper()
		out, err := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "GRK-03", To: hub.BroadcastID, ToBox: hub.WUIBox,
			TaskID: task, Kind: "note", Body: "from a box", Hub: a.c})
		if err != nil {
			t.Fatalf("box send on %s: %v", task, err)
		}
		return out.MsgID
	}
	level := func(task, msgID string) int {
		t.Helper()
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+task, "HUM-1", nil)
		if code != http.StatusOK {
			t.Fatalf("topic %s: %d %v", task, code, out)
		}
		msgs, _ := out["messages"].([]any)
		for _, r := range msgs {
			m, _ := r.(map[string]any)
			env, _ := json.Marshal(m["env"])
			if strings.Contains(string(env), msgID) {
				n, _ := m["is_parent"].(float64)
				return int(n)
			}
		}
		t.Fatalf("topic %s: %s not found", task, msgID)
		return -1
	}

	const (
		lobbyTopic    = "33333333-3333-4333-8333-333333333301"
		feedbackTopic = "33333333-3333-4333-8333-333333333302"
		dmTopic       = "33333333-3333-4333-8333-333333333303"
		fresh         = "33333333-3333-4333-8333-333333333304"
	)
	topic(lobbyTopic, "lobby")
	topic(feedbackTopic, "feedback")
	topic(dmTopic, "")

	for _, c := range []struct {
		name, task string
		want       int
	}{
		{"reply under a #lobby topic", lobbyTopic, 0},
		{"reply under a #feedback topic", feedbackTopic, 0},
		{"reply under a DM topic (control)", dmTopic, 1},
		{"a new task (control)", fresh, 1},
		{"the lobby task (control)", lobby, 1},
	} {
		if got := level(c.task, boxSend(c.task)); got != c.want {
			t.Errorf("%s: is_parent %d, want %d", c.name, got, c.want)
		}
	}
}
