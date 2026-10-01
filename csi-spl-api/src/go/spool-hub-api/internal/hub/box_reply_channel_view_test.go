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

// CLE-77845 (prd csitea 2026-10-01, "the counter on the agent has values, but
// the DM is empty"): a box reply into a channel topic is STORED in that
// channel (channelOf), but its signed envelope names no channel, and the view
// exposed only the envelope's. The WUI then read every desk answer in
// #spool-hub-biz as a DM and raised the agent's DM badge on a DM holding
// nothing. The view element now carries the row's channel beside the
// envelope; a row whose envelope already names it, and a DM, carry none.
func TestViewBoxReplyCarriesItsChannel(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	w := dialWUI(t, e, tid, "HUM-1")
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	topic := func(task, channel string) string {
		t.Helper()
		f := map[string]any{"type": "send", "task_id": task, "body": "L1", "is_parent": 1}
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
	boxSend := func(task, to string) string {
		t.Helper()
		out, err := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "GRK-03", To: to, ToBox: hub.WUIBox,
			TaskID: task, Kind: "note", Body: "from a box", Hub: a.c})
		if err != nil {
			t.Fatalf("box send on %s: %v", task, err)
		}
		return out.MsgID
	}
	// element finds msgID among a §4.4 message list.
	element := func(msgs []any, msgID string) map[string]any {
		t.Helper()
		for _, r := range msgs {
			m, _ := r.(map[string]any)
			env, _ := json.Marshal(m["env"])
			if strings.Contains(string(env), msgID) {
				return m
			}
		}
		t.Fatalf("%s not in %v", msgID, msgs)
		return nil
	}

	const (
		chanTopic = "33333333-3333-4333-8333-333333333311"
		dmTopic   = "33333333-3333-4333-8333-333333333312"
	)
	root := topic(chanTopic, "feedback")
	topic(dmTopic, "")
	chanReply := boxSend(chanTopic, "HUM-1") // addressed to the human, as a desk answer is
	dmReply := boxSend(dmTopic, "HUM-1")

	code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+chanTopic, "HUM-1", nil)
	if code != http.StatusOK {
		t.Fatalf("topic: %d %v", code, out)
	}
	msgs, _ := out["messages"].([]any)
	if got := element(msgs, chanReply)["channel"]; got != "feedback" {
		t.Errorf("box reply in #feedback: channel %v, want feedback", got)
	}
	if got, ok := element(msgs, root)["channel"]; ok {
		t.Errorf("a root whose envelope names its channel carries an override: %v", got)
	}

	code, out = call(t, e, tid, http.MethodGet, "/v1/view/topics/"+dmTopic, "HUM-1", nil)
	if code != http.StatusOK {
		t.Fatalf("dm topic: %d %v", code, out)
	}
	msgs, _ = out["messages"].([]any)
	if got, ok := element(msgs, dmReply)["channel"]; ok {
		t.Errorf("box reply in a DM carries a channel: %v", got)
	}

	// The inlined page the WUI channel feed reads (per_topic) says the same.
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/topics?channel=feedback&per_topic=5", "HUM-1", nil)
	if code != http.StatusOK {
		t.Fatalf("topics: %d %v", code, out)
	}
	rows, _ := out["topics"].([]any)
	var inline []any
	for _, r := range rows {
		if row, _ := r.(map[string]any); row["task_id"] == chanTopic {
			inline, _ = row["messages"].([]any)
		}
	}
	if got := element(inline, chanReply)["channel"]; got != "feedback" {
		t.Errorf("per_topic: box reply channel %v, want feedback", got)
	}
}
