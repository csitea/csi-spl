package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// spec 053 S1 (SPL-1239, rdb 0186): a box whose hello carries live_ack reports
// each poke's outcome; the hub records it. S3 (SPL-1241): a human post that
// was nacked and that no agent acked shown goes to the tenant's responder at
// the next relay tick, not after the 120 s reply timeout. Memory store, and
// Postgres with SPOOL_TEST_PG_DSN.

// liveRig is a tenant with a responder (CLE-001 on a live box-desk) and a
// channel "staffed" whose one agent member is GRK-36 on box-b, a hand-driven
// socket that announces the live_ack feature when liveAck is true.
type liveRig struct {
	e     *env
	tid   string
	desk  *box
	b     *rawBox
	ws    func(id, task, body string)
	clock *atomic.Int64
}

func newLiveRig(t *testing.T, liveAck bool) *liveRig {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	clock := &atomic.Int64{}
	e := newEnv(t, func(o *hub.Options) {
		fallbackOpts(o, key, true)
		o.Now = func() time.Time { return time.Now().Add(time.Duration(clock.Load())) }
	})
	tid, _ := e.tenant()
	ctx := context.Background()
	e.pinKey(tid, hub.WUIBox, pub)
	if err := e.st.(store.Fallbacks).SetTenantResponders(ctx, tid, []string{"CLE-001"}); err != nil {
		t.Fatal(err)
	}
	desk := e.box(tid, "box-desk", "CLE-001")
	e.pin(tid, desk)
	sd, err := desk.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeWait(sd) })
	human := "HUM-google-sub-1@" + tid
	now := time.Now()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "staffed",
		Name: "staffed", CreatedBy: human, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "staffed", []string{human}, human, now); err != nil {
		t.Fatal(err)
	}
	bb := e.box(tid, "box-b", "GRK-36")
	e.pin(tid, bb)
	c, nonce := e.raw(tid)
	h := helloFrame(bb, nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents = []string{"GRK-36"}
	if liveAck {
		h.Features = []string{wire.FeatureLiveAck}
	}
	wsjson.Write(ctx, c, h) //nolint:errcheck
	b := &rawBox{t: t, c: c}
	b.next(wire.TWelcome)
	b.next(wire.TQueueEnd)
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/staffed/agents", human,
		map[string]string{"id": "GRK-36", "box": "box-b"}); code != http.StatusCreated {
		t.Fatalf("invite: %d %v", code, out)
	}
	ws := dialMember(t, e, tid, "Owner", human)
	post := func(id, task, body string) { threadFrame(t, ws, id, task, "staffed", 1, body) }
	return &liveRig{e: e, tid: tid, desk: desk, b: b, ws: post, clock: clock}
}

// postAndAck posts m into "staffed", reads GRK-36's recv on box-b and acks it
// with outcome for agent; it waits until the hub has read the frame.
func (r *liveRig) postAndAck(t *testing.T, m, task, agent, outcome string) {
	t.Helper()
	r.ws(m, task, "please pick this up")
	f := r.b.next(wire.TRecv)
	if id, _ := recvMsgID(t, f); id != m {
		t.Fatalf("box-b got %s, want %s", id, m)
	}
	wsjson.Write(context.Background(), r.b.c, wire.Frame{Type: wire.TAck, MsgID: m, Agent: agent, Outcome: outcome}) //nolint:errcheck
	time.Sleep(150 * time.Millisecond)                                                                               // the hub reads the ack frame
}

func (r *liveRig) acks(t *testing.T, m string) []store.LiveAck {
	t.Helper()
	got, err := r.e.st.(store.LiveAcks).LiveAcksOf(context.Background(), r.tid, m)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestLiveAckIsRecorded(t *testing.T) {
	r := newLiveRig(t, true)
	m := "5d9e0f1a-2b3c-4d4e-9f5a-6b7c8d9e0f1a"
	r.postAndAck(t, m, "3b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e", "GRK-36", wire.AckShown)
	got := r.acks(t, m)
	if len(got) != 1 || got[0].Agent != "GRK-36" || got[0].Box != "box-b" || got[0].Outcome != wire.AckShown {
		t.Fatalf("acks %+v, want one shown ack of GRK-36 on box-b", got)
	}
	// a later poke of the same (message, agent) replaces the outcome
	wsjson.Write(context.Background(), r.b.c, wire.Frame{Type: wire.TAck, MsgID: m, Agent: "GRK-36", Outcome: wire.AckRefused}) //nolint:errcheck
	eventually(t, "the second ack replaced the first", func() bool {
		got := r.acks(t, m)
		return len(got) == 1 && got[0].Outcome == wire.AckRefused
	})
}

// CONTROL for S1: an ack for an agent the box did not announce, an unknown
// outcome, and a message the hub never sent the box are all dropped.
func TestLiveAckRefusesWhatTheBoxCannotClaim(t *testing.T) {
	r := newLiveRig(t, true)
	m := "6e0f1a2b-3c4d-4e5f-8a6b-7c8d9e0f1a2b"
	r.postAndAck(t, m, "4c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e1f", "CLE-001", wire.AckShown)
	for _, f := range []wire.Frame{
		{Type: wire.TAck, MsgID: m, Agent: "GRK-36", Outcome: "maybe"},
		{Type: wire.TAck, MsgID: "7f1a2b3c-4d5e-4f6a-9b7c-8d9e0f1a2b3c", Agent: "GRK-36", Outcome: wire.AckShown},
	} {
		wsjson.Write(context.Background(), r.b.c, f) //nolint:errcheck
	}
	time.Sleep(150 * time.Millisecond)
	if got := r.acks(t, m); len(got) != 0 {
		t.Fatalf("acks %+v, want none (CLE-001 is not box-b's, 'maybe' is no outcome)", got)
	}
	if got := r.acks(t, "7f1a2b3c-4d5e-4f6a-9b7c-8d9e0f1a2b3c"); len(got) != 0 {
		t.Fatalf("acks %+v for a message box-b never got, want none", got)
	}
}

// CONTROL for S1: a box that did not announce live_ack (every sidecar before
// S2) gets its ack frame ignored, and still works as before.
func TestLiveAckOffForABoxWithoutTheFeature(t *testing.T) {
	r := newLiveRig(t, false)
	m := "8a2b3c4d-5e6f-4a7b-8c8d-9e0f1a2b3c4d"
	r.postAndAck(t, m, "5d9e0f1a-2b3c-4d4e-9f5a-6b7c8d9e0f2b", "GRK-36", wire.AckShown)
	if got := r.acks(t, m); len(got) != 0 {
		t.Fatalf("acks %+v from a box without live_ack, want none", got)
	}
}

// S3: GRK-36's pane is gone (no_window). Once the nack settles, the next tick
// hands the post to the responder, claimed once; the 120 s reply timeout is
// off in this rig, so only the nack can have escalated it.
func TestNackEscalatesToTheResponderAtTheNextTick(t *testing.T) {
	r := newLiveRig(t, true)
	ctx := context.Background()
	m := "9b3c4d5e-6f7a-4b8c-9d9e-0f1a2b3c4d5e"
	r.postAndAck(t, m, "6e0f1a2b-3c4d-4e5f-8a6b-7c8d9e0f1a3c", "GRK-36", wire.AckNoWindow)
	// CONTROL: inside the settle window nothing escalates yet.
	r.e.srv.Relay(ctx)
	if n := len(inbox(t, r.desk, "CLE-001")); n != 0 {
		t.Fatalf("escalated inside the settle: CLE-001 inbox %d", n)
	}
	r.clock.Store(int64(4 * time.Second))
	r.e.srv.Relay(ctx)
	eventually(t, "CLE-001 got the nacked post", func() bool { return strings.Join(inboxIDs(t, r.desk, "CLE-001"), ",") == m })
	r.e.srv.Relay(ctx)
	if n := len(inbox(t, r.desk, "CLE-001")); n != 1 {
		t.Fatalf("CLE-001 inbox %d, want exactly 1 (claimed once)", n)
	}
}

// CONTROL for S3: a live member (shown) means no escalation.
func TestShownAckDoesNotEscalate(t *testing.T) {
	r := newLiveRig(t, true)
	ctx := context.Background()
	m := "0c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"
	r.postAndAck(t, m, "7f1a2b3c-4d5e-4f6a-9b7c-8d9e0f1a2b4d", "GRK-36", wire.AckShown)
	r.clock.Store(int64(4 * time.Second))
	r.e.srv.Relay(ctx)
	time.Sleep(200 * time.Millisecond)
	if n := len(inbox(t, r.desk, "CLE-001")); n != 0 {
		t.Fatalf("a shown post escalated: CLE-001 inbox %d", n)
	}
}
