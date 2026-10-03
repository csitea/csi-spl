package hub_test

// Spec 067 L4 to the browser: a DM's ref_task_id and its channel copy's
// mirror_of reach the WUI beside the envelope, on the live `message` frame
// (wui.go fanoutWUI) and on the history view (view.go viewMsgsIn). Never in
// a box's envelope: TestDMRefOldBoxEnvelope. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// refFields is a frame's or a view row's two spec 067 keys; nil = absent.
type refFields struct {
	RefTaskID *string `json:"ref_task_id"`
	MirrorOf  *string `json:"mirror_of"`
}

func (f refFields) String() string {
	s := func(p *string) string {
		if p == nil {
			return "<absent>"
		}
		return *p
	}
	return "ref_task_id=" + s(f.RefTaskID) + " mirror_of=" + s(f.MirrorOf)
}

func (f refFields) is(ref, mirror string) bool {
	eq := func(p *string, want string) bool {
		if want == "" {
			return p == nil // omitempty: unset is no key at all
		}
		return p != nil && *p == want
	}
	return eq(f.RefTaskID, ref) && eq(f.MirrorOf, mirror)
}

// sendLive sends a person's DM to CLE-07 on task through w and answers the
// live `message` frames w then receives, by msg_id, until the ack and n of
// them have arrived.
func (r *dmRefRig) sendLive(w *websocket.Conn, task, ref string, n int) (string, map[string]refFields) {
	r.t.Helper()
	id := uuidV4()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": task, "kind": "note", "body": "live", "to": "CLE-07"}
	if ref != "" {
		f["ref_task_id"] = ref
	}
	wsjson.Write(context.Background(), w, f) //nolint:errcheck
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	got, acked := map[string]refFields{}, false
	for !acked || len(got) < n {
		var raw json.RawMessage
		if err := wsjson.Read(ctx, w, &raw); err != nil {
			r.t.Fatalf("waiting for the ack and %d frames (have %d): %v", n, len(got), err)
		}
		var fr struct {
			Type string `json:"type"`
			Env  struct {
				Msg struct {
					MsgID string `json:"msg_id"`
				} `json:"msg"`
			} `json:"env"`
			refFields
		}
		if err := json.Unmarshal(raw, &fr); err != nil {
			r.t.Fatal(err)
		}
		switch fr.Type {
		case "ack":
			acked = true
		case "error":
			r.t.Fatalf("send on %s: %s", task, raw)
		case "message":
			got[fr.Env.Msg.MsgID] = fr.refFields
		}
	}
	return id, got
}

// viewRefs is the history view of task as HUM-1 reads it, by msg_id.
func (r *dmRefRig) viewRefs(task string) map[string]refFields {
	r.t.Helper()
	code, _, body := viewGet(r.t, r.e, r.tid, "/v1/view/topics/"+task, memberHeader, "HUM-1")
	if code != 200 {
		r.t.Fatalf("view %s: %d %s", task, code, body)
	}
	var v struct {
		Messages []struct {
			Env struct {
				Msg struct {
					MsgID string `json:"msg_id"`
				} `json:"msg"`
			} `json:"env"`
			refFields
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &v); err != nil {
		r.t.Fatalf("view %s: %v %s", task, err, body)
	}
	out := map[string]refFields{}
	for _, m := range v.Messages {
		out[m.Env.Msg.MsgID] = m.refFields
	}
	return out
}

// The DM carries ref_task_id and its channel copy mirror_of, live and on
// reload. CONTROLS: a plain DM claiming nothing carries neither key in
// either place, nor do the topic's own rows (its opener, an unrelated reply).
func TestDMRefFieldsReachTheBrowser(t *testing.T) {
	r := newDMRefRig(t)
	d, plain := uuidV4(), uuidV4()
	for _, task := range []string{d, plain, r.topic} {
		wsjson.Write(context.Background(), r.w1, map[string]string{"type": "subscribe", "task_id": task}) //nolint:errcheck
		readType(t, r.w1, "subscribed")
	}

	id, live := r.sendLive(r.w1, d, r.topic, 2) // the DM and its copy
	cp := r.copies()[id].MsgID
	if cp == "" {
		t.Fatal("no copy: the claim did not take, so this test proves nothing")
	}
	if f := live[id]; !f.is(r.topic, "") {
		t.Errorf("live DM frame: %v, want ref_task_id=%s and no mirror_of", f, r.topic)
	}
	if f, ok := live[cp]; !ok || !f.is("", id) {
		t.Errorf("live copy frame (seen %v): %v, want mirror_of=%s and no ref_task_id", ok, f, id)
	}
	if f := r.viewRefs(d)[id]; !f.is(r.topic, "") {
		t.Errorf("view DM row: %v, want ref_task_id=%s", f, r.topic)
	}
	topic := r.viewRefs(r.topic)
	if f, ok := topic[cp]; !ok || !f.is("", id) {
		t.Errorf("view copy row (seen %v): %v, want mirror_of=%s", ok, f, id)
	}

	if len(topic) != 3 {
		t.Errorf("CONTROL: %d rows in the topic view, want the opener, the unrelated reply and the copy", len(topic))
	}
	for mid, f := range topic {
		if mid != cp && !f.is("", "") {
			t.Errorf("CONTROL: the topic's own row %s: %v, want neither key", mid, f)
		}
	}
	pid, plive := r.sendLive(r.w1, plain, "", 1)
	if f, ok := plive[pid]; !ok || !f.is("", "") {
		t.Errorf("CONTROL: live plain DM frame (seen %v): %v, want neither key", ok, f)
	}
	if f, ok := r.viewRefs(plain)[pid]; !ok || !f.is("", "") {
		t.Errorf("CONTROL: view plain DM row (seen %v): %v, want neither key", ok, f)
	}
}
