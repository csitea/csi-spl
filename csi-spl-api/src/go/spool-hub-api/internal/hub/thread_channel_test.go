package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// CLE-34977: a thread reply lives on its topic's task and the WUI reply pane
// sends no channel tag, so a #lobby reply was stored with channel NULL while
// its topic said lobby. A reply now inherits its topic root's channel; the
// #feedback and DM rows are the controls (tagged stays tagged, a DM stays a DM).
func TestThreadReplyInheritsTopicChannel(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	w := dialWUI(t, e, tid, "HUM-1")

	stored := func(msgID string) string {
		t.Helper()
		m, err := e.st.GetEditable(ctx, tid, msgID, time.Now())
		if err != nil {
			t.Fatalf("stored %s: %v", msgID, err)
		}
		return m.Channel
	}
	post := func(task, channel, body string, isParent int) string {
		t.Helper()
		f := map[string]any{"type": "send", "task_id": task, "body": body, "is_parent": isParent}
		if channel != "" {
			f["channel"] = channel
		}
		w.send(f)
		ack := w.read("ack")
		if ack.MsgID == "" {
			t.Fatalf("ack %+v", ack)
		}
		return ack.MsgID
	}

	cases := []struct {
		name, task, topicTag, want string
	}{
		{"lobby", "22222222-2222-4222-8222-222222222201", "lobby", "lobby"},
		{"feedback control", "22222222-2222-4222-8222-222222222202", "feedback", "feedback"},
		{"dm control", "22222222-2222-4222-8222-222222222203", "", ""},
	}
	for _, c := range cases {
		topic := post(c.task, c.topicTag, "L1 "+c.name, 1)
		reply := post(c.task, "", "L2 "+c.name, 0)
		if got := stored(topic); got != c.want {
			t.Errorf("%s: topic channel %q, want %q", c.name, got, c.want)
		}
		if got := stored(reply); got != c.want {
			t.Errorf("%s: untagged reply channel %q, want %q", c.name, got, c.want)
		}
	}

	// CLE-35057: a reply TAGGED with another channel (the page the reader had
	// on screen) is still stored in its topic's channel. This asserted the
	// opposite until prd 2026-09-27, when the owner's reply into a
	// #spool-hub-devel topic was stored under #spool-hub-ops.
	if got := stored(post(cases[0].task, "feedback", "L2 tagged", 0)); got != "lobby" {
		t.Errorf("tagged reply channel %q, want lobby (the topic's channel)", got)
	}
	// A DM topic has no channel to inherit: the tag still decides.
	if got := stored(post(cases[2].task, "feedback", "L2 dm tagged", 0)); got != "feedback" {
		t.Errorf("tagged reply in a DM topic: channel %q, want feedback", got)
	}

	// A box agent's untagged reply under the lobby topic inherits it too.
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	out, err := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "GRK-03", To: hub.BroadcastID, ToBox: hub.WUIBox,
		TaskID: cases[0].task, Kind: "note", Body: "L2 from a box", Hub: a.c})
	if err != nil {
		t.Fatalf("box reply: %v", err)
	}
	if got := stored(out.MsgID); got != "lobby" {
		t.Errorf("box reply channel %q, want lobby", got)
	}
}
