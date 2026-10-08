package hub_test

// Spec 068 L8: the responsible seat (rdb 0110 messages.responsible, set at
// insert for a message to one agent) reaches the browser on the live
// `message` frame and on the view read, as `responsible` beside the
// envelope. A message to nobody in particular (a lobby post) carries no key.

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

func TestResponsibleOnTheFrameAndTheView(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "c-001")
	b := e.box(tid, "box-b", "c-007")
	e.pin(tid, a)
	e.pin(tid, b)
	for _, x := range []*box{a, b} {
		s, err := x.c.Dial(ctx, wire.RoleBox)
		if err != nil {
			t.Fatal(err)
		}
		defer closeWait(s)
	}
	eventually(t, "c-007@box-b known on box-a", func() bool {
		tb, err := a.c.ResolveToBox("c-007", "")
		return err == nil && tb == "box-b"
	})

	task := "6c1d0b2e-3f4a-4b5c-8d6e-7f8091a2b3c4"
	w := dialWUI(t, e, tid, "HUM-2")
	w.send(map[string]string{"type": "subscribe", "task_id": task})
	w.read("subscribed")
	w.send(map[string]string{"type": "subscribe", "task_id": lobby})
	w.read("subscribed")

	out, err := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "c-001", To: "c-007", Kind: "note", Body: "to one agent",
		TaskID: task, ToBox: "box-b", Hub: a.c})
	if err != nil || out.Delivery != wire.DeliverySent {
		t.Fatalf("send: %+v %v", out, err)
	}
	if f := w.read("message"); f.Responsible != "c-007@box-b" {
		t.Fatalf("live frame responsible=%q, want c-007@box-b", f.Responsible)
	}
	// CONTROL: a lobby post is to ALL-0, nobody is responsible, no key.
	w.send(map[string]any{"type": "send", "task_id": "lobby", "body": "to the room"})
	if f := w.read("message"); f.Responsible != "" {
		t.Fatalf("a lobby post carried responsible=%q", f.Responsible)
	}

	got := func(path string) *string {
		t.Helper()
		code, _, body := viewGet(t, e, tid, path)
		if code != 200 {
			t.Fatalf("%s: %d %s", path, code, body)
		}
		var v struct {
			Messages []struct {
				Responsible *string `json:"responsible"`
			} `json:"messages"`
		}
		if err := json.Unmarshal(body, &v); err != nil || len(v.Messages) != 1 {
			t.Fatalf("%s: %v %s", path, err, body)
		}
		return v.Messages[0].Responsible
	}
	if r := got("/v1/view/topics/" + task); r == nil || *r != "c-007@box-b" {
		t.Fatalf("view responsible = %v, want c-007@box-b", r)
	}
	if r := got("/v1/view/topics/" + lobby); r != nil {
		t.Fatalf("the lobby post's view carried responsible=%q", *r)
	}
}
