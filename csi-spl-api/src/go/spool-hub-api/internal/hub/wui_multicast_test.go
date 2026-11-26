package hub_test

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 186 row M2 (7.1.1, 7.1.3): a send frame with mc_id is one multicast
// copy. Its checks (is_parent 0, an existing channel topic the author may
// read, an mc_id of this author), then the whole send chain unchanged, and
// the row stores mc_id. Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full).

func mcFrame(msgID, task, channel, mc, body string) map[string]any {
	return map[string]any{"type": "send", "msg_id": msgID, "task_id": task, "kind": "note", "body": body,
		"files": []any{}, "channel": channel, "is_parent": 0, "mc_id": mc}
}

// mcSend writes f and returns its ack or error frame.
func mcSend(t *testing.T, c *websocket.Conn, f map[string]any) map[string]any {
	t.Helper()
	if err := wsjson.Write(context.Background(), c, f); err != nil {
		t.Fatal(err)
	}
	return readType(t, c, "ack")
}

func isStored(t *testing.T, e *env, tid, id string) bool {
	t.Helper()
	_, _, err := e.st.MessageTimes(context.Background(), tid, id)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	return err == nil
}

func copiesOf(t *testing.T, e *env, tid, mc string) []string {
	t.Helper()
	ids, err := e.st.MulticastCopies(context.Background(), tid, mc)
	if err != nil {
		t.Fatal(err)
	}
	return ids
}

// N frames with one mc_id into N readable topics of different channels (a
// public one, a members-only one the author is in, the lobby) store N rows
// with that mc_id. A frame without mc_id stores none. RED CONTROL: drop
// withMcID in wuiSend and no row carries the id.
func TestMulticastSendStoresCopies(t *testing.T) {
	r := newSelectRig(t)
	c := r.dial(t, r.author)
	mc := uuidV4()
	var want []string
	for _, x := range [][2]string{{r.pub, "feedback"}, {r.mine, "mine"}, {r.lob, store.ChannelLobby}} {
		id := uuidV4()
		if f := mcSend(t, c, mcFrame(id, x[0], x[1], mc, "release at noon")); f["type"] != "ack" {
			t.Fatalf("copy into %s: %v, want ack", x[1], f)
		}
		want = append(want, id)
	}
	plain := mcFrame(uuidV4(), r.pub, "feedback", "", "an ordinary reply")
	delete(plain, "mc_id")
	if f := mcSend(t, c, plain); f["type"] != "ack" {
		t.Fatalf("plain send: %v", f)
	}
	slices.Sort(want)
	if got := copiesOf(t, r.e, r.tid, mc); !slices.Equal(got, want) {
		t.Fatalf("copies of %s: %v, want %v", mc, got, want)
	}
}

// Of 3 targets where the middle one is an existing topic of a members-only
// channel the author is not in, a DM topic (the author is an end of it), a
// box-locked topic or an unknown task_id, the first and third are stored and
// the middle answers multicast_no_topic 404 with the unknown id's detail,
// naming only its own msg_id. RED CONTROLS: drop the check and the unknown
// id opens a topic; answer forbidden for an unreadable topic and the
// members-only case fails (it must not say the topic exists).
func TestMulticastNoTopic(t *testing.T) {
	r := newSelectRig(t)
	c := r.dial(t, r.author)
	unknown := uuidV4()
	var detail string
	for _, mid := range [][2]string{{unknown, "feedback"}, {r.theirs, "theirs"}, {r.dm, ""}, {r.locked, "feedback"}} {
		mc, ids := uuidV4(), []string{uuidV4(), uuidV4(), uuidV4()}
		a := mcSend(t, c, mcFrame(ids[0], r.pub, "feedback", mc, "hello all"))
		b := mcSend(t, c, mcFrame(ids[1], mid[0], mid[1], mc, "hello all"))
		z := mcSend(t, c, mcFrame(ids[2], r.mine, "mine", mc, "hello all"))
		if a["type"] != "ack" || z["type"] != "ack" {
			t.Fatalf("middle %s: first %v third %v, want both acked", mid[1], a, z)
		}
		if b["type"] != "error" || b["error"] != "multicast_no_topic" || b["status"] != float64(404) || b["msg_id"] != ids[1] {
			t.Fatalf("middle %q: %v, want multicast_no_topic 404 naming %s", mid[1], b, ids[1])
		}
		if detail == "" {
			detail, _ = b["detail"].(string)
		}
		if b["detail"] != detail {
			t.Errorf("middle %q detail %q, want the unknown id's %q", mid[1], b["detail"], detail)
		}
		if isStored(t, r.e, r.tid, ids[1]) || len(copiesOf(t, r.e, r.tid, mc)) != 2 {
			t.Errorf("middle %q: the refused copy was stored", mid[1])
		}
	}
	if strings.Contains(detail, unknown) {
		t.Errorf("detail %q names the task id", detail)
	}
}

// mc_id must be a UUID and an mc_id another author already used is bad_json
// (a fresh one is fine); a copy with is_parent 1 answers multicast_no_topic
// 404 (7.1.1). RED CONTROL: drop the author check and the second author's
// copy is stored.
func TestMulticastBadFrames(t *testing.T) {
	r := newSelectRig(t)
	c := r.dial(t, r.author)
	mc := uuidV4()
	if f := mcSend(t, c, mcFrame(uuidV4(), r.pub, "feedback", "not-a-uuid", "x")); f["error"] != "bad_json" {
		t.Errorf("mc_id not a UUID: %v, want bad_json", f)
	}
	top := mcFrame(uuidV4(), r.pub, "feedback", mc, "x")
	top["is_parent"] = 1
	if f := mcSend(t, c, top); f["error"] != "multicast_no_topic" || f["status"] != float64(404) {
		t.Errorf("is_parent 1: %v, want multicast_no_topic 404", f)
	}
	if f := mcSend(t, c, mcFrame(uuidV4(), r.pub, "feedback", mc, "mine")); f["type"] != "ack" {
		t.Fatalf("author's copy: %v", f)
	}
	oc := r.dial(t, r.other)
	theirs := uuidV4()
	if f := mcSend(t, oc, mcFrame(theirs, r.pub, "feedback", mc, "hijack")); f["error"] != "bad_json" || f["msg_id"] != theirs {
		t.Errorf("second author's mc_id: %v, want bad_json", f)
	}
	if isStored(t, r.e, r.tid, theirs) {
		t.Error("the second author's copy was stored")
	}
	if f := mcSend(t, oc, mcFrame(uuidV4(), r.pub, "feedback", uuidV4(), "own")); f["type"] != "ack" {
		t.Errorf("second author's own mc_id: %v, want ack", f)
	}
}

// 1200 copies of one mc_id with an unlimited quota are all stored: no count
// of the copies (R2 QTA). RED CONTROL: cap the copies of one mc_id and this
// test fails.
func TestMulticastSendNoCap(t *testing.T) {
	r := newSelectRig(t)
	c := r.dial(t, r.author)
	mc := uuidV4()
	targets := [][2]string{{r.pub, "feedback"}, {r.mine, "mine"}, {r.lob, store.ChannelLobby}}
	for i := range 1200 {
		x := targets[i%3]
		if f := mcSend(t, c, mcFrame(uuidV4(), x[0], x[1], mc, "all hands")); f["type"] != "ack" {
			t.Fatalf("copy %d: %v, want ack", i+1, f)
		}
	}
	if n := len(copiesOf(t, r.e, r.tid, mc)); n != 1200 {
		t.Fatalf("%d copies stored, want 1200", n)
	}
}

// With the month quota at the stored count + 2, 4 copies store 2 and the
// other 2 answer the quota token 429; a resend of a stored copy then still
// re-acks (messageQuota exempts a stored msg_id) and stores nothing.
func TestMulticastSendQuota(t *testing.T) {
	r := newSelectRig(t)
	e2 := rbacEnvSharing(t, r.e, messageCount(t, r.e, r.tid)+2)
	c := dialMember(t, e2, r.tid, "x", r.author)
	mc := uuidV4()
	var frames []map[string]any
	acks := 0
	for _, x := range [][2]string{{r.pub, "feedback"}, {r.mine, "mine"}, {r.lob, store.ChannelLobby}, {r.pub, "feedback"}} {
		f := mcFrame(uuidV4(), x[0], x[1], mc, "quota day")
		frames = append(frames, f)
		switch a := mcSend(t, c, f); {
		case a["type"] == "ack":
			acks++
		case a["error"] != billing.TokenQuota || a["status"] != float64(billing.HTTPQuota):
			t.Errorf("copy %s: %v, want %s %d", f["msg_id"], a, billing.TokenQuota, billing.HTTPQuota)
		}
	}
	if acks != 2 || len(copiesOf(t, r.e, r.tid, mc)) != 2 {
		t.Fatalf("%d acked, %d stored, want 2 and 2", acks, len(copiesOf(t, r.e, r.tid, mc)))
	}
	before := messageCount(t, r.e, r.tid)
	if a := mcSend(t, c, frames[0]); a["type"] != "ack" {
		t.Fatalf("resend of a stored copy with the quota spent: %v, want ack", a)
	}
	if after := messageCount(t, r.e, r.tid); after != before {
		t.Errorf("messages %d -> %d on a resend", before, after)
	}
}

// An unpaid tenant answers 402 on every copy and stores none.
func TestMulticastSendUnpaid(t *testing.T) {
	r := newSelectRig(t)
	if err := r.e.st.SetBillingStatus(context.Background(), r.tid, billing.StatusUnpaid); err != nil {
		t.Fatal(err)
	}
	c := r.dial(t, r.author)
	mc := uuidV4()
	for _, x := range [][2]string{{r.pub, "feedback"}, {r.mine, "mine"}, {r.lob, store.ChannelLobby}} {
		if a := mcSend(t, c, mcFrame(uuidV4(), x[0], x[1], mc, "pay day")); a["error"] != billing.TokenUnpaid || a["status"] != float64(billing.HTTPUnpaid) {
			t.Errorf("copy into %s: %v, want %s %d", x[1], a, billing.TokenUnpaid, billing.HTTPUnpaid)
		}
	}
	if n := len(copiesOf(t, r.e, r.tid, mc)); n != 0 {
		t.Errorf("%d copies stored by an unpaid tenant", n)
	}
}

// Q5 NRM: each copy routes as any post of its author: the channel's agent
// gets a copy in each of two topics; once the channel is humans-only, an
// @agent copy is a plain post that reaches no agent.
func TestMulticastRoutesAsAPost(t *testing.T) {
	r, b := aiRig(t)
	has := func(id string) bool { return slices.Contains(inboxIDs(t, b, "GRK-36"), id) }
	t1, t2 := uuidV4(), uuidV4()
	threadFrame(t, r.ws, uuidV4(), t1, "drivers", 1, "car 7")
	threadFrame(t, r.ws, uuidV4(), t2, "drivers", 1, "car 9")
	mc, c1, c2 := uuidV4(), uuidV4(), uuidV4()
	for _, x := range [][2]string{{c1, t1}, {c2, t2}} {
		if a := mcSend(t, r.ws, mcFrame(x[0], x[1], "drivers", mc, "tyres today")); a["type"] != "ack" {
			t.Fatalf("copy into %s: %v", x[1], a)
		}
	}
	eventually(t, "GRK-36 got both copies", func() bool { return has(c1) && has(c2) })
	removeAgent(t, r, "drivers", "box-b", "GRK-36")
	c3 := uuidV4()
	if a := mcSend(t, r.ws, mcFrame(c3, t1, "drivers", uuidV4(), "@GRK-36 check car 7")); a["type"] != "ack" {
		t.Fatalf("@agent copy into a humans-only channel: %v, want ack (a plain post)", a)
	}
	watch(400*time.Millisecond, func() bool { return has(c3) })
	if has(c3) {
		t.Fatal("an @agent copy in a humans-only channel reached the agent")
	}
}
