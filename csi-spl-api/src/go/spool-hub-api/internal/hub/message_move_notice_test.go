package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// prd t1 645f9e3e (bug topic 226a8209): a person's post was made a topic of
// its own six seconds after the dispatcher got it. The row moved; the
// dispatcher's inbox copy and hub-tail still said the old topic, so the
// answer went there and the new topic looked unanswered. Run on today's code
// (before message_move_notice.go) the notice, the hub-tail task and the
// queued copy each go red. CONTROL: the unmoved card keeps its topic and its
// stored bytes; an agent that never held the post gets no notice.

// promotedAfterDelivery is the incident: card c0 and reply m1 in topic A of
// #mobile, both fallen back to CLE-001, then m1 promoted to a new topic N.
func promotedAfterDelivery(t *testing.T) (r *fallbackRig, c0, m1, a, n string) {
	t.Helper()
	r = newFallbackRig(t, true, "mobile")
	ctx := context.Background()
	if err := r.e.st.(store.Fallbacks).SetTenantResponders(ctx, r.tid, []string{"CLE-001"}); err != nil {
		t.Fatal(err)
	}
	c0, m1, a = "5b1d2e3f-4a5b-4c6d-8e7f-8091a2b3c4d5", "645f9e3e-5dc1-4e21-aab2-12235aad2c9b", "5901e226-01b9-4d6f-a13e-f714897c3ffd"
	threadFrame(t, r.ws, c0, a, "mobile", 1, "spec 099 topic")
	threadFrame(t, r.ws, m1, a, "mobile", 0, "this deserves its own topic")
	eventually(t, "CLE-001 holds both posts", func() bool { return len(inbox(t, r.desk, "CLE-001")) == 2 })
	eventually(t, "m1 recorded as delivered", func() bool {
		_, err := r.e.st.(store.Fallbacks).FallbackOf(ctx, r.tid, m1)
		st, _ := r.e.st.DeliveryState(ctx, r.tid, m1, "box-desk")
		return err == nil && st == store.StateSent
	})
	code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/messages/"+m1+"/promote-topic", r.human, map[string]any{})
	n, _ = out["task_id"].(string)
	if code != http.StatusOK || n == "" || n == a {
		t.Fatalf("promote: %d %v", code, out)
	}
	return r, c0, m1, a, n
}

// author is the spool id of the person who wrote msgID (the rig's member
// session resolves to a HUM-n id, not the session name).
func author(t *testing.T, r *fallbackRig, msgID string) string {
	t.Helper()
	m, err := r.e.st.GetEditable(context.Background(), r.tid, msgID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m.FromID
}

// tailOf is what `spool hub-tail --task <task>` prints for box b: each
// envelope's inner message.
func tailOf(t *testing.T, b *box, task string) []*msg.Message {
	t.Helper()
	ctx := context.Background()
	sess, err := b.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	var got []*msg.Message
	if _, err := sess.Tail(ctx, task, false, func(e *wire.Envelope) {
		if m, err := e.Inner(); err == nil {
			got = append(got, m)
		}
	}); err != nil {
		t.Fatalf("tail %s: %v", task, err)
	}
	return got
}

func TestPromoteAfterDeliveryTellsTheHolderAndTailReadsTheNewTopic(t *testing.T) {
	r, c0, m1, a, n := promotedAfterDelivery(t)

	// 1. The agent that holds m1 is told, in the new topic, by the mover (its author here).
	var note *msg.Message
	eventually(t, "CLE-001 got the move notice", func() bool {
		for _, m := range inbox(t, r.desk, "CLE-001") {
			if m.MsgID != m1 && m.MsgID != c0 {
				note = m
				return true
			}
		}
		return false
	})
	if note.TaskID != n || note.From != author(t, r, m1) || note.Kind != "note" ||
		!strings.Contains(note.Body, m1) || !strings.Contains(note.Body, a) || !strings.Contains(note.Body, "this deserves its own topic") {
		t.Fatalf("move notice: %+v", note)
	}
	// CONTROL: CLE-35 on the same box never held m1 and is not told.
	watch(200*time.Millisecond, func() bool { return len(inbox(t, r.desk, "CLE-35")) != 0 })
	if got := inbox(t, r.desk, "CLE-35"); len(got) != 0 {
		t.Fatalf("CLE-35 never held m1 but reads %d message(s)", len(got))
	}

	// 2. hub-tail on the new topic reports the topic m1 lives in now.
	got := tailOf(t, r.desk, n)
	if len(got) != 1 || got[0].MsgID != m1 || got[0].TaskID != n {
		t.Fatalf("hub-tail %s: %+v", n, got)
	}
	// CONTROL: the old topic keeps the unmoved card, on its own topic.
	got = tailOf(t, r.desk, a)
	if len(got) != 1 || got[0].MsgID != c0 || got[0].TaskID != a {
		t.Fatalf("hub-tail %s (control): %+v", a, got)
	}
	// The stored row stays the historical record: the envelope keeps A.
	row, err := r.e.st.GetEditable(context.Background(), r.tid, m1, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	env, _ := wire.ParseEnvelope(row.Env)
	if inner, err := env.Inner(); err != nil || row.TaskID != n || inner.TaskID != a {
		t.Fatalf("stored row task %q envelope task %q (err %v), want %q and %q", row.TaskID, inner.TaskID, err, n, a)
	}
	if errs := r.deskS.RecvErrors(); len(errs) != 0 {
		t.Fatalf("box-desk refused a frame: %v", errs)
	}
}

// An answer in the OLD topic does not close the new one: the hub's
// re-escalation reads the row's topic, so m1 is still owed an answer in N
// after CLE-001 answers in A. CONTROL: c0, answered in A, is not.
func TestPromotedPostStaysUnansweredUntilAnsweredInItsNewTopic(t *testing.T) {
	r, c0, m1, a, n := promotedAfterDelivery(t)
	ctx := context.Background()
	hum := author(t, r, m1)
	if _, err := action.SendCtx(ctx, r.desk.cfg, action.SendArgs{From: "CLE-001", To: hum, TaskID: a,
		Kind: "note", Body: "answered in the old topic", ToBox: hub.WUIBox, Hub: r.desk.c}); err != nil {
		t.Fatal(err)
	}
	owed := func() map[string]string {
		t.Helper()
		ps, err := r.e.st.(store.Fallbacks).ReescalatablePosts(ctx, r.tid, time.Now().Add(-time.Hour),
			time.Now().Add(time.Hour), time.Now().Add(time.Hour), 9, 20)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]string{}
		for _, p := range ps {
			out[p.MsgID] = p.TaskID
		}
		return out
	}
	eventually(t, "the old-topic answer is stored", func() bool { _, ok := owed()[c0]; return !ok })
	if got := owed(); got[m1] != n {
		t.Fatalf("m1 must still be owed an answer in %s: %v", n, got)
	}
	// Answered in N, it is closed.
	if _, err := action.SendCtx(ctx, r.desk.cfg, action.SendArgs{From: "CLE-001", To: hum, TaskID: n,
		Kind: "note", Body: "answered in the new topic", ToBox: hub.WUIBox, Hub: r.desk.c}); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the new-topic answer closes m1", func() bool { _, ok := owed()[m1]; return !ok })
}

// A box that was offline when the post was promoted gets its queued copy on
// the topic the row lives in now, not the one the envelope was signed in.
func TestQueuedCopyOfAPromotedPostCarriesTheNewTopic(t *testing.T) {
	r := newFallbackRig(t, true, "staffed")
	ctx := context.Background()
	b := r.e.box(r.tid, "box-b", "GRK-36")
	r.e.pin(r.tid, b)
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/channels/staffed/agents", r.human,
		map[string]string{"id": "GRK-36", "box": "box-b"}); code != http.StatusCreated {
		t.Fatalf("invite: %d %v", code, out)
	}
	c0, m1, a := "6c2e3f4a-5b6c-4d7e-8f80-91a2b3c4d5e6", "7d3f4a5b-6c7d-4e8f-9091-a2b3c4d5e6f7", "8e4a5b6c-7d8e-4f90-a1b2-c3d4e5f6a7b8"
	threadFrame(t, r.ws, c0, a, "staffed", 1, "card")
	threadFrame(t, r.ws, m1, a, "staffed", 0, "queued while box-b is away")
	eventually(t, "m1 queued for box-b", func() bool {
		st, _ := r.e.st.DeliveryState(ctx, r.tid, m1, "box-b")
		return st == store.StateQueued
	})
	code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/messages/"+m1+"/promote-topic", r.human, map[string]any{})
	n, _ := out["task_id"].(string)
	if code != http.StatusOK || n == "" {
		t.Fatalf("promote: %d %v", code, out)
	}
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()
	eventually(t, "box-b drained both", func() bool { return len(inbox(t, b, "GRK-36")) == 2 })
	for _, m := range inbox(t, b, "GRK-36") {
		want := a // CONTROL: the unmoved card keeps its topic
		if m.MsgID == m1 {
			want = n
		}
		if m.TaskID != want {
			t.Fatalf("GRK-36 got %s on topic %s, want %s", m.MsgID, m.TaskID, want)
		}
	}
	if errs := sb.RecvErrors(); len(errs) != 0 {
		t.Fatalf("box-b refused a frame: %v", errs)
	}
}
