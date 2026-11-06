package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 164 row B3: the hub honours a channel's box pins. #ops is pinned to
// box-a; box-b hosts a member of it all the same (subscriptions survive a
// pin, section 9). #free has the same members and no pin: it behaves as
// before B3. Each test is a red control of section 8's B3 row: delete the
// check it names and the assertion marked CONTROL fails. The lookup error
// (pinsFlaky) must neither deliver nor allow (3.3, fail closed). These run
// on the memory store and, with SPOOL_TEST_PG_DSN, on PostgreSQL.

// errPinsDown is pinsFlaky's lookup error.
var errPinsDown = errors.New("channel box pins: store down")

// pinsFlaky fails GetChannelBoxPins while fail is set; every other call is
// the real store's (its fallback store too, which the hub type-asserts).
type pinsFlaky struct {
	store.Store
	store.Fallbacks
	fail atomic.Bool
}

func (p *pinsFlaky) GetChannelBoxPins(ctx context.Context, tenant, channel string) ([]string, error) {
	if p.fail.Load() {
		return nil, errPinsDown
	}
	return p.Store.GetChannelBoxPins(ctx, tenant, channel)
}

// pinRig is one tenant: box-a (GRK-03, CLE-07) and box-b (CLE-08), both
// members of #ops (pinned to box-a) and #free (unpinned); box-wui pinned to
// the hub's key, a signed-in human in both channels.
type pinRig struct {
	e     *env
	tid   string
	human string
	a, b  *box
	flaky *pinsFlaky
}

func newPinRig(t *testing.T, fallbackOn bool) *pinRig {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	r := &pinRig{}
	r.e = newEnv(t, func(o *hub.Options) {
		fallbackOpts(o, key, fallbackOn)
		fb, _ := o.Store.(store.Fallbacks)
		r.flaky = &pinsFlaky{Store: o.Store, Fallbacks: fb}
		o.Store = r.flaky
	})
	r.tid, _ = r.e.tenant()
	r.human = "HUM-google-sub-1@" + r.tid
	ctx := context.Background()
	r.a = r.e.box(r.tid, "box-a", "GRK-03", "CLE-07")
	r.b = r.e.box(r.tid, "box-b", "CLE-08")
	r.e.pin(r.tid, r.a)
	r.e.pin(r.tid, r.b)
	r.e.pinKey(r.tid, hub.WUIBox, pub)
	now := time.Now()
	for _, ch := range []string{"ops", "free"} {
		if err := r.e.st.CreateChannel(ctx, store.Channel{TenantID: r.tid, ChannelID: ch, Name: ch, CreatedBy: r.human, CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := r.e.st.AddChannelHumans(ctx, r.tid, ch, []string{r.human}, r.human, now); err != nil {
			t.Fatal(err)
		}
		for _, m := range [][2]string{{"box-a", "GRK-03"}, {"box-a", "CLE-07"}, {"box-b", "CLE-08"}} {
			if err := r.e.st.InviteChannelAgent(ctx, r.tid, ch, m[0], m[1], now); err != nil {
				t.Fatal(err)
			}
		}
	}
	r.pinOps(t, "box-a")
	return r
}

// pinOps sets #ops's pins (none = unpinned) through the B1 store.
func (r *pinRig) pinOps(t *testing.T, boxes ...string) {
	t.Helper()
	if err := r.e.st.SetChannelBoxPins(context.Background(), r.tid, "ops", boxes, r.human); err != nil {
		t.Fatal(err)
	}
}

// cli is a role=cli session of b.
func (r *pinRig) cli(t *testing.T, b *box) *hubclient.Session {
	t.Helper()
	s, err := b.c.Dial(context.Background(), wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeWait(s) })
	return s
}

// boxPost sends one note from b's agent from to (to, toBox) in channel and
// returns its msg_id and the hub's answer.
func (r *pinRig) boxPost(t *testing.T, s *hubclient.Session, b *box, from, to, toBox, channel, body string) (string, error) {
	t.Helper()
	m := chanMsg(uuidV4(), to, "note", body)
	m.From = from
	_, err := s.Send(context.Background(), signedIn(t, b, toBox, channel, "", m))
	return m.MsgID, err
}

// queuedFor reports whether msgID has a deliveries row for box.
func (r *pinRig) queuedFor(t *testing.T, msgID, box string) bool {
	t.Helper()
	_, err := r.e.st.DeliveryState(context.Background(), r.tid, msgID, box)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	return err == nil
}

// stored reports whether msgID is a stored message.
func (r *pinRig) stored(t *testing.T, msgID string) bool {
	t.Helper()
	_, err := r.e.st.GetEditable(context.Background(), r.tid, msgID, time.Now())
	return err == nil
}

// browserSend sends one browser line and returns its ack or error frame.
func browserSend(t *testing.T, c *websocket.Conn, f map[string]any) map[string]any {
	t.Helper()
	f["type"], f["kind"] = "send", "note"
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	return readType(t, c, "ack")
}

// refusedWith fails unless err is a refusal naming token.
func refusedWith(t *testing.T, what string, err error, token string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), token) {
		t.Fatalf("%s: %v, want a %s refusal", what, err, token)
	}
}

// Fan-out (spec 164 5.1): a pinned channel's post is queued for its listed
// member boxes only; an unpinned channel's for every member box.
func TestRouteChannelBoxPin(t *testing.T) {
	r := newPinRig(t, false)
	s := r.cli(t, r.a)
	ops, err := r.boxPost(t, s, r.a, "GRK-03", hub.BroadcastID, hub.WUIBox, "ops", "pinned post")
	if err != nil {
		t.Fatal(err)
	}
	if !r.queuedFor(t, ops, "box-a") {
		t.Fatal("#ops post not queued for its listed box box-a")
	}
	if r.queuedFor(t, ops, "box-b") { // CONTROL: the fan-out skips an unlisted member box
		t.Fatal("#ops post queued for box-b, which #ops is not pinned to")
	}
	free, err := r.boxPost(t, s, r.a, "GRK-03", hub.BroadcastID, hub.WUIBox, "free", "unpinned post")
	if err != nil {
		t.Fatal(err)
	}
	if !r.queuedFor(t, free, "box-a") || !r.queuedFor(t, free, "box-b") {
		t.Fatal("#free (unpinned) post not queued for every member box, as before B3")
	}
	// A browser post fans out through the same loop; a lookup error drops
	// the fan-out (fail closed) and the post stays stored.
	w := dialMember(t, r.e, r.tid, "Owner", r.human)
	r.flaky.fail.Store(true)
	id := uuidV4()
	if ack := browserSend(t, w, map[string]any{"msg_id": id, "task_id": uuidV4(), "channel": "ops", "is_parent": 1, "body": "while pins are down"}); ack["type"] != "ack" {
		t.Fatalf("browser post: %v", ack)
	}
	if r.queuedFor(t, id, "box-a") || r.queuedFor(t, id, "box-b") { // CONTROL: fail closed
		t.Fatal("a pins lookup error fanned the post out")
	}
	if !r.stored(t, id) {
		t.Fatal("the post was not stored")
	}
}

// The box door (spec 164 5.1, onSend before commitRow): an agent on a listed
// box sends to_box = an unlisted box, or names @<id>@<unlisted box>, on a
// pinned channel: 403 channel_box_mismatch, nothing stored or queued.
func TestSendChannelBoxPin(t *testing.T) {
	r := newPinRig(t, false)
	s := r.cli(t, r.a)
	id, err := r.boxPost(t, s, r.a, "GRK-03", "CLE-08", "box-b", "ops", "direct leg off the list")
	refusedWith(t, "to_box box-b on #ops", err, hub.CodeChannelBoxMismatch) // CONTROL
	if r.stored(t, id) || r.queuedFor(t, id, "box-b") {
		t.Fatal("the refused direct leg was stored or queued")
	}
	id, err = r.boxPost(t, s, r.a, "GRK-03", hub.BroadcastID, hub.WUIBox, "ops", "ask @CLE-08@box-b about it")
	refusedWith(t, "@CLE-08@box-b on #ops", err, hub.CodeChannelBoxMismatch) // CONTROL: the cross-box mention
	if r.stored(t, id) {
		t.Fatal("the refused mention was stored")
	}
	// An untagged reply into an #ops topic goes to its to_box all the same.
	topic := uuidV4()
	opsRoot := chanMsg(topic, hub.BroadcastID, "note", "an #ops topic")
	if _, err := s.Send(context.Background(), signedIn(t, r.a, hub.WUIBox, "ops", "", opsRoot)); err != nil {
		t.Fatal(err)
	}
	reply := chanMsg(topic, "CLE-08", "note", "untagged reply off the list")
	_, err = s.Send(context.Background(), signedIn(t, r.a, "box-b", "", "", reply))
	refusedWith(t, "untagged reply to box-b in an #ops topic", err, hub.CodeChannelBoxMismatch) // CONTROL
	if r.queuedFor(t, reply.MsgID, "box-b") {
		t.Fatal("the refused untagged reply was queued for box-b")
	}
	if _, err := r.boxPost(t, s, r.a, "GRK-03", "CLE-07", "box-a", "ops", "listed box, @CLE-07@box-a"); err != nil {
		t.Fatalf("to_box box-a (listed) on #ops: %v", err)
	}
	if id, err := r.boxPost(t, s, r.a, "GRK-03", "CLE-08", "box-b", "free", "unpinned"); err != nil || !r.queuedFor(t, id, "box-b") {
		t.Fatalf("to_box box-b on #free (unpinned): %v", err)
	}
	r.flaky.fail.Store(true)
	// A tagged post meets the lookup error first in agentInChannel (500
	// internal), an untagged direct leg in the door itself (503).
	id, err = r.boxPost(t, s, r.a, "GRK-03", "CLE-07", "box-a", "ops", "pins down")
	refusedWith(t, "lookup error, tagged", err, "internal") // CONTROL: fail closed
	if r.stored(t, id) {
		t.Fatal("a pins lookup error let the send through")
	}
	leg := chanMsg(topic, "CLE-07", "note", "untagged leg, pins down")
	_, err = s.Send(context.Background(), signedIn(t, r.a, "box-b", "", "", leg))
	refusedWith(t, "lookup error, untagged", err, hub.CodeChannelPinsUnavailable) // CONTROL: fail closed
	if r.stored(t, leg.MsgID) {
		t.Fatal("a pins lookup error let the untagged leg through")
	}
}

// The browser door (spec 164 5.1, dispatchCheck): @<agent>@<unlisted box>
// on a pinned channel, a new topic or a reply into one, is 403
// channel_box_mismatch. The root post's channel comes from the frame
// (wui.go passes it, dispatch holder msg d276deef).
func TestDispatchChannelBoxPin(t *testing.T) {
	r := newPinRig(t, false)
	w := dialMember(t, r.e, r.tid, "Owner", r.human)
	root := uuidV4()
	f := browserSend(t, w, map[string]any{"msg_id": uuidV4(), "task_id": root, "channel": "ops", "is_parent": 1, "body": "@CLE-08@box-b run it"})
	if f["type"] != "error" || f["error"] != hub.CodeChannelBoxMismatch { // CONTROL: the new topic
		t.Fatalf("root post @CLE-08@box-b on #ops: %v", f)
	}
	if f := browserSend(t, w, map[string]any{"msg_id": uuidV4(), "task_id": root, "channel": "ops", "is_parent": 1, "body": "@CLE-07@box-a run it"}); f["type"] != "ack" || f["to_box"] != "box-a" {
		t.Fatalf("root post @CLE-07@box-a (listed) on #ops: %v", f)
	}
	id := uuidV4()
	f = browserSend(t, w, map[string]any{"msg_id": id, "task_id": root, "channel": "ops", "is_parent": 0, "body": "@CLE-08@box-b and you"})
	if f["type"] != "error" || f["error"] != hub.CodeChannelBoxMismatch { // CONTROL: a reply in the topic
		t.Fatalf("reply @CLE-08@box-b in an #ops topic: %v", f)
	}
	if r.stored(t, id) || r.queuedFor(t, id, "box-b") {
		t.Fatal("the refused dispatch was stored or queued")
	}
	if f := browserSend(t, w, map[string]any{"msg_id": uuidV4(), "task_id": uuidV4(), "channel": "free", "is_parent": 1, "body": "@CLE-08@box-b run it"}); f["type"] != "ack" || f["to_box"] != "box-b" {
		t.Fatalf("root post @CLE-08@box-b on #free (unpinned): %v", f)
	}
	r.flaky.fail.Store(true)
	f = browserSend(t, w, map[string]any{"msg_id": uuidV4(), "task_id": uuidV4(), "channel": "ops", "is_parent": 1, "body": "@CLE-07@box-a pins down"})
	if f["type"] != "error" || f["error"] != hub.CodeChannelPinsUnavailable { // CONTROL: fail closed
		t.Fatalf("dispatch with a pins lookup error: %v", f)
	}
}

// drained connects b as a role=box socket and returns the recv frames of
// its queue drain (up to queue_end).
func drained(t *testing.T, r *pinRig, b *box, agents ...string) []wire.Frame {
	t.Helper()
	rb := r.e.rawBoxNoDrain(r.tid, b, agents, nil)
	defer rb.c.CloseNow() //nolint:errcheck
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var out []wire.Frame
	for {
		var f wire.Frame
		if err := wsjson.Read(ctx, rb.c, &f); err != nil {
			t.Fatalf("drain of %s: %v", b.id, err)
		}
		switch f.Type {
		case wire.TRecv:
			out = append(out, f)
		case wire.TQueueEnd:
			return out
		}
	}
}

// Receive (spec 164 5.1, recvAgents): a row of #ops queued for box-b before
// the pin, its to_box box-b, never reaches box-b once #ops is pinned to
// box-a; the same row of an unpinned channel does.
func TestRecvChannelBoxPin(t *testing.T) {
	r := newPinRig(t, false)
	r.pinOps(t) // unpinned while the row is queued
	s := r.cli(t, r.a)
	ops, err := r.boxPost(t, s, r.a, "GRK-03", "CLE-08", "box-b", "ops", "queued before the pin")
	if err != nil || !r.queuedFor(t, ops, "box-b") {
		t.Fatalf("queue the #ops row: %v", err)
	}
	free, err := r.boxPost(t, s, r.a, "GRK-03", "CLE-08", "box-b", "free", "unpinned row")
	if err != nil {
		t.Fatal(err)
	}
	r.pinOps(t, "box-a")
	var got []string
	for _, f := range drained(t, r, r.b, "CLE-08") {
		id, _ := recvMsgID(t, f)
		got = append(got, id)
	}
	if len(got) != 1 || got[0] != free { // CONTROL: the #ops row is dropped, its own to_box leg too
		t.Fatalf("box-b received %v, want only the #free row %s (not #ops %s)", got, free, ops)
	}
	// A lookup error drops the row too: unpin, fail the lookup, reconnect.
	r.pinOps(t)
	r.flaky.fail.Store(true)
	if f := drained(t, r, r.b, "CLE-08"); len(f) != 0 { // CONTROL: fail closed
		t.Fatalf("a pins lookup error delivered %d rows", len(f))
	}
	r.flaky.fail.Store(false)
	if f := drained(t, r, r.b, "CLE-08"); len(f) != 1 {
		t.Fatalf("the #ops row after the pin was cleared: %d frames, want 1 (it stayed queued)", len(f))
	}
}

// Fallback (spec 164 5.1): on a pinned channel only a listed box falls back;
// with no listed box online no fallback runs, though the responder's box is
// online. An unpinned channel falls back to the responder as before.
func TestFallbackChannelBoxPin(t *testing.T) {
	r := newPinRig(t, true)
	ctx := context.Background()
	desk := r.e.box(r.tid, "box-desk", "CLE-001")
	r.e.pin(r.tid, desk)
	if err := r.e.st.(store.Fallbacks).SetTenantResponders(ctx, r.tid, []string{"CLE-001"}); err != nil {
		t.Fatal(err)
	}
	// #quiet: pinned to box-a, no agent members, so every post falls back.
	r.quiet(t)
	sd, err := desk.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sd)
	w := dialMember(t, r.e, r.tid, "Owner", r.human)
	m1 := uuidV4()
	threadFrame(t, w, m1, uuidV4(), "quiet", 1, "box-a is offline")
	watch(300*time.Millisecond, func() bool { return len(inbox(t, desk, "CLE-001")) != 0 })
	if n := len(inbox(t, desk, "CLE-001")); n != 0 { // CONTROL: no fallback off the list
		t.Fatalf("the responder on unlisted box-desk got %d posts of #quiet", n)
	}
	sa, err := r.a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	m2 := uuidV4()
	threadFrame(t, w, m2, uuidV4(), "quiet", 1, "box-a is online")
	eventually(t, "the listed box-a takes the fallback", func() bool {
		return len(inbox(t, r.a, "CLE-07"))+len(inbox(t, r.a, "GRK-03")) == 1
	})
	if n := len(inbox(t, desk, "CLE-001")); n != 0 { // CONTROL: the responder list does not override the pin
		t.Fatalf("the responder on unlisted box-desk got %d posts of #quiet", n)
	}
	if fb := r.fallbackOf(t, "quiet"); fb["box"] != "box-a" {
		t.Fatalf("#quiet members fallback: %v, want box-a", fb)
	}
	r.flaky.fail.Store(true)
	// fallbackInfo (the members answer): a lookup error names no fallback,
	// never one on the unlisted box-desk (fail closed).
	if fb := r.fallbackOf(t, "quiet"); fb["box"] != "" || fb["id"] != "" { // CONTROL: fail closed
		t.Fatalf("a pins lookup error named a fallback: %v", fb)
	}
	m3 := uuidV4()
	threadFrame(t, w, m3, uuidV4(), "quiet", 1, "pins down")
	watch(300*time.Millisecond, func() bool { return len(inbox(t, r.a, "CLE-07"))+len(inbox(t, r.a, "GRK-03")) > 1 })
	if n := len(inbox(t, r.a, "CLE-07")) + len(inbox(t, r.a, "GRK-03")) + len(inbox(t, desk, "CLE-001")); n != 1 { // CONTROL: fail closed
		t.Fatalf("a pins lookup error ran a fallback: %d posts in all, want 1", n)
	}
	r.flaky.fail.Store(false)
	closeWait(sa)
	// Unpinned: the responder on box-desk falls back as before B3.
	if err := r.e.st.SetChannelBoxPins(ctx, r.tid, "quiet", nil, r.human); err != nil {
		t.Fatal(err)
	}
	m4 := uuidV4()
	threadFrame(t, w, m4, uuidV4(), "quiet", 1, "unpinned now")
	eventually(t, "the responder takes the unpinned post", func() bool { return len(inbox(t, desk, "CLE-001")) == 1 })
}

// quiet creates #quiet, pinned to box-a, with the human and the given
// agent members ({box, agent}).
func (r *pinRig) quiet(t *testing.T, agents ...[2]string) {
	t.Helper()
	ctx, now := context.Background(), time.Now()
	if err := r.e.st.CreateChannel(ctx, store.Channel{TenantID: r.tid, ChannelID: "quiet", Name: "quiet", CreatedBy: r.human, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := r.e.st.AddChannelHumans(ctx, r.tid, "quiet", []string{r.human}, r.human, now); err != nil {
		t.Fatal(err)
	}
	for _, m := range agents {
		if err := r.e.st.InviteChannelAgent(ctx, r.tid, "quiet", m[0], m[1], now); err != nil {
			t.Fatal(err)
		}
	}
	if err := r.e.st.SetChannelBoxPins(ctx, r.tid, "quiet", []string{"box-a"}, r.human); err != nil {
		t.Fatal(err)
	}
}

// fallbackOf is the members answer's `fallback` object for ch.
func (r *pinRig) fallbackOf(t *testing.T, ch string) map[string]any {
	t.Helper()
	code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/channels/"+ch+"/members", r.human, nil)
	if code != http.StatusOK {
		t.Fatalf("GET members: %d %v", code, out)
	}
	fb, _ := out["fallback"].(map[string]any)
	return fb
}

// Fallback's "is anyone online" gate (spec 164 5.1, recipientOnline): a
// member online on an unlisted box never gets the post, so it does not hold
// the fallback; the listed box-a takes it.
func TestFallbackUnlistedOnlineChannelBoxPin(t *testing.T) {
	r := newPinRig(t, true)
	ctx := context.Background()
	r.quiet(t, [2]string{"box-b", "CLE-08"})
	sb, err := r.b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sb)
	sa, err := r.a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	w := dialMember(t, r.e, r.tid, "Owner", r.human)
	threadFrame(t, w, uuidV4(), uuidV4(), "quiet", 1, "only an unlisted member is online")
	eventually(t, "the listed box-a takes the fallback though CLE-08 on unlisted box-b is online", func() bool { // CONTROL
		return len(inbox(t, r.a, "CLE-07"))+len(inbox(t, r.a, "GRK-03")) == 1
	})
	if n := len(inbox(t, r.b, "CLE-08")); n != 0 {
		t.Fatalf("CLE-08 on unlisted box-b got %d posts of #quiet", n)
	}
}

// Posting (spec 164 5.3, agentInChannel): an agent on an unlisted box is
// answered like a channel that does not exist, 404 unknown_channel; on an
// unpinned channel it posts as before.
func TestAgentInChannelBoxPin(t *testing.T) {
	r := newPinRig(t, false)
	s := r.cli(t, r.b)
	id, err := r.boxPost(t, s, r.b, "CLE-08", hub.BroadcastID, hub.WUIBox, "ops", "from an unlisted box")
	refusedWith(t, "CLE-08 on box-b posts to #ops", err, "unknown_channel") // CONTROL
	if r.stored(t, id) {
		t.Fatal("the refused post was stored")
	}
	if _, err := r.boxPost(t, s, r.b, "CLE-08", hub.BroadcastID, hub.WUIBox, "free", "unpinned"); err != nil {
		t.Fatalf("CLE-08 on box-b posts to #free (unpinned): %v", err)
	}
	if _, err := r.boxPost(t, r.cli(t, r.a), r.a, "CLE-07", hub.BroadcastID, hub.WUIBox, "ops", "listed"); err != nil {
		t.Fatalf("CLE-07 on box-a (listed) posts to #ops: %v", err)
	}
	r.flaky.fail.Store(true)
	id, err = r.boxPost(t, s, r.b, "CLE-08", hub.BroadcastID, hub.WUIBox, "free", "pins down")
	if err == nil || r.stored(t, id) { // CONTROL: fail closed, never allowed
		t.Fatalf("a pins lookup error let CLE-08 post: %v", err)
	}
}
