package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-997, specs/038 FR-030..FR-038: no human post goes unheard while an
// agent is online. These run on the memory store and, with
// SPOOL_TEST_PG_DSN, on Postgres (rdb 0067).

// fallbackEnv is backfillEnv's rig (browser posts signed by box-wui, no
// back-fill) with the fallback responder on or off.
func fallbackEnv(t *testing.T, key ed25519.PrivateKey, on bool) *env {
	return newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.WUIKey, o.WUIDispatch = key, true
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
		o.Fallback = on
	})
}

// fallbackRig is one tenant with box-wui pinned, a human who is a member of
// channel ch (no agent in it), and a live fallback-capable box-desk.
type fallbackRig struct {
	e     *env
	tid   string
	human string
	desk  *box
	pokes func() []string
	ws    *websocket.Conn
	deskS *hubclient.Session
}

func newFallbackRig(t *testing.T, on bool, channels ...string) *fallbackRig {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	e := fallbackEnv(t, key, on)
	tid, _ := e.tenant()
	ctx := context.Background()
	d := e.box(tid, "box-desk", "CLE-001", "CLE-35")
	pokes := pokeLog(t, d)
	e.pin(tid, d)
	e.pinKey(tid, hub.WUIBox, pub)
	human := "HUM-google-sub-1@" + tid
	now := time.Now()
	for _, ch := range channels {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch,
			Name: ch, CreatedBy: human, CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := e.st.AddChannelHumans(ctx, tid, ch, []string{human}, human, now); err != nil {
			t.Fatal(err)
		}
	}
	s, err := d.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return &fallbackRig{e: e, tid: tid, human: human, desk: d, pokes: pokes, deskS: s,
		ws: dialMember(t, e, tid, "Owner", human)}
}

// dmFrame sends one browser DM to an agent on a new task.
func dmFrame(t *testing.T, c *websocket.Conn, id, task, to, body string) {
	t.Helper()
	wsjson.Write(context.Background(), c, map[string]any{"type": "send", "msg_id": id, //nolint:errcheck
		"task_id": task, "kind": "note", "to": to, "body": body, "is_parent": 1})
	if ack := readType(t, c, "ack"); ack["type"] != "ack" {
		t.Fatalf("dm %s: %v", id, ack)
	}
}

// fallbackOf is the members answer's `fallback` object.
func fallbackOf(t *testing.T, r *fallbackRig, ch string) map[string]any {
	t.Helper()
	code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/channels/"+ch+"/members", r.human, nil)
	if code != http.StatusOK {
		t.Fatalf("GET members: %d %v", code, out)
	}
	fb, _ := out["fallback"].(map[string]any)
	return fb
}

func fallbackCount(t *testing.T, r *fallbackRig, ch string) int {
	t.Helper()
	sum, err := r.e.st.(store.Fallbacks).ChannelFallbacks(context.Background(), r.tid, ch, time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	return sum.Count
}

// The owner's case: a human posts into a channel with no agent member. The
// tenant's responder (CLE-001) gets the post in its inbox and ONE
// "unanswered post" poke; nobody else on the box does; the post now has an
// agent delivery; Properties names the responder.
func TestFallbackChannelWithNoAgentReachesResponder(t *testing.T) {
	r := newFallbackRig(t, true, "mobile")
	ctx := context.Background()
	if err := r.e.st.(store.Fallbacks).SetTenantResponders(ctx, r.tid, []string{"CLE-001"}); err != nil {
		t.Fatal(err)
	}
	m1, task := "3b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e", "1a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
	threadFrame(t, r.ws, m1, task, "mobile", 1, "why are no agents\nconnected to this one")
	eventually(t, "CLE-001 got the post", func() bool { return strings.Join(inboxIDs(t, r.desk, "CLE-001"), ",") == m1 })
	eventually(t, "one poke", func() bool { return len(r.pokes()) == 1 })
	p := r.pokes()[0]
	if !strings.Contains(p, "--to CLE-001 --from HUM-") || !strings.Contains(p, "--task "+task+" --msg-id "+m1) ||
		!strings.HasSuffix(p, "| unanswered post in #mobile (no member agent online): why are no agents connected to this one") {
		t.Fatalf("poke: %q", p)
	}
	if n := len(inbox(t, r.desk, "CLE-35")); n != 0 {
		t.Fatalf("CLE-35 is not the responder, reads %d", n)
	}
	// The hub writes the frame first and records it after, so the inbox can
	// be ahead of the store (CI Postgres, 2026-09-27): wait for the records.
	eventually(t, "box-desk delivery sent", func() bool {
		st, _ := r.e.st.DeliveryState(ctx, r.tid, m1, "box-desk")
		return st == store.StateSent
	})
	eventually(t, "one fallback record", func() bool { return fallbackCount(t, r, "mobile") == 1 })
	fb := fallbackOf(t, r, "mobile")
	rec, _ := fb["recent"].(map[string]any)
	if fb["id"] != "CLE-001" || fb["box"] != "box-desk" || fb["active"] != true || rec["count"] != float64(1) || rec["id"] != "CLE-001" {
		t.Fatalf("members fallback: %v", fb)
	}
	// A resend of the same msg_id is not a new post: nothing more.
	threadFrame(t, r.ws, m1, task, "mobile", 1, "why are no agents\nconnected to this one")
	time.Sleep(200 * time.Millisecond)
	if n := len(r.pokes()); n != 1 {
		t.Fatalf("resend poked again: %v", r.pokes())
	}
	if errs := r.deskS.RecvErrors(); len(errs) != 0 {
		t.Fatalf("box-desk recv errors: %v", errs)
	}
}

// The control: a member agent of the channel is online, so the post is heard
// the ordinary way and no fallback is sent.
func TestFallbackNotSentWhenAMemberIsOnline(t *testing.T) {
	r := newFallbackRig(t, true, "staffed")
	ctx := context.Background()
	if err := r.e.st.(store.Fallbacks).SetTenantResponders(ctx, r.tid, []string{"CLE-001"}); err != nil {
		t.Fatal(err)
	}
	b := r.e.box(r.tid, "box-b", "GRK-36")
	r.e.pin(r.tid, b)
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/channels/staffed/agents", r.human,
		map[string]string{"id": "GRK-36", "box": "box-b"}); code != http.StatusCreated {
		t.Fatalf("invite: %d %v", code, out)
	}
	m1 := "4c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
	threadFrame(t, r.ws, m1, "2a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d", "staffed", 1, "someone is here")
	eventually(t, "GRK-36 got it", func() bool { return strings.Join(inboxIDs(t, b, "GRK-36"), ",") == m1 })
	time.Sleep(200 * time.Millisecond)
	if n := len(inbox(t, r.desk, "CLE-001")); n != 0 || len(r.pokes()) != 0 {
		t.Fatalf("fallback sent although GRK-36 is online: inbox %d pokes %v", n, r.pokes())
	}
	if n := fallbackCount(t, r, "staffed"); n != 0 {
		t.Fatalf("fallback records %d, want 0", n)
	}
	if fb := fallbackOf(t, r, "staffed"); fb["active"] != false {
		t.Fatalf("members fallback active with a member online: %v", fb)
	}
}

// With the fallback switched off, the owner's case reaches nobody (the
// control for the first test: the delivery is this feature's doing).
func TestFallbackOffReachesNobody(t *testing.T) {
	r := newFallbackRig(t, false, "mobile")
	threadFrame(t, r.ws, "3b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e", "1a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d", "mobile", 1, "hello?")
	time.Sleep(300 * time.Millisecond)
	if n := len(inbox(t, r.desk, "CLE-001")) + len(inbox(t, r.desk, "CLE-35")); n != 0 || len(r.pokes()) != 0 {
		t.Fatalf("fallback off, yet inbox %d pokes %v", n, r.pokes())
	}
	if fb := fallbackOf(t, r, "mobile"); fb != nil {
		t.Fatalf("members fallback with the feature off: %v", fb)
	}
}

// No responder online (or none set): the agent on the longest-online box
// takes it, lowest id first. A box on an old client (no "fallback" in its
// hello) is never picked, even when it has been online longest.
func TestFallbackLongestOnlineAndOldClientSkipped(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	e := fallbackEnv(t, key, true)
	tid, _ := e.tenant()
	ctx := context.Background()
	e.pinKey(tid, hub.WUIBox, pub)
	human := "HUM-google-sub-1@" + tid
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "mobile",
		Name: "mobile", CreatedBy: human, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "mobile", []string{human}, human, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := e.st.(store.Fallbacks).SetTenantResponders(ctx, tid, []string{"CLE-404"}); err != nil {
		t.Fatal(err)
	}
	old := e.box(tid, "box-old", "AAA-1")
	e.pin(tid, old)
	rb := e.rawBox(tid, old, []string{"AAA-1"}, nil) // no features: an old client
	defer rb.c.CloseNow()                            //nolint:errcheck
	time.Sleep(20 * time.Millisecond)
	first := e.box(tid, "box-z", "GRK-9", "AGY-2")
	firstPokes := pokeLog(t, first)
	e.pin(tid, first)
	s1, err := first.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s1.Close()
	time.Sleep(20 * time.Millisecond)
	second := e.box(tid, "box-a", "BBB-1")
	e.pin(tid, second)
	s2, err := second.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	w := dialMember(t, e, tid, "Owner", human)
	m1 := "5c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
	threadFrame(t, w, m1, "1a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d", "mobile", 1, "anyone?")
	eventually(t, "AGY-2 on the longest-online box got it", func() bool { return strings.Join(inboxIDs(t, first, "AGY-2"), ",") == m1 })
	eventually(t, "one poke", func() bool { return len(firstPokes()) == 1 })
	if n := len(inbox(t, first, "GRK-9")) + len(inbox(t, second, "BBB-1")); n != 0 {
		t.Fatalf("more than one agent got the fallback: %d", n)
	}
	if f, err := rb.within(wire.TRecv, 200*time.Millisecond); err == nil {
		t.Fatalf("the old client was sent a frame: %+v", f)
	}
}

// A DM to an agent whose box is offline falls back (FR-030, "DM to"); a DM
// to another human never does.
func TestFallbackDMToOfflineAgent(t *testing.T) {
	r := newFallbackRig(t, true)
	ctx := context.Background()
	off := r.e.box(r.tid, "box-off", "CLE-77")
	r.e.pin(r.tid, off)
	so, err := off.c.Dial(ctx, wire.RoleBox) // announce CLE-77, then go away
	if err != nil {
		t.Fatal(err)
	}
	so.Close()
	eventually(t, "box-off offline", func() bool {
		<-so.Done()
		return true
	})
	time.Sleep(100 * time.Millisecond)
	m1, task := "6d9e0f1a-2b3c-4d4e-9f5a-6b7c8d9e0f1a", "7d9e0f1a-2b3c-4d4e-9f5a-6b7c8d9e0f1a"
	dmFrame(t, r.ws, m1, task, "CLE-77", "please look at the build")
	eventually(t, "the fallback got the DM", func() bool { return strings.Join(inboxIDs(t, r.desk, "CLE-001"), ",") == m1 })
	eventually(t, "one poke", func() bool { return len(r.pokes()) == 1 })
	if p := r.pokes()[0]; !strings.HasSuffix(p, "| unanswered post in DM to CLE-77 (agent offline): please look at the build") {
		t.Fatalf("poke: %q", p)
	}
	eventually(t, "one DM fallback record", func() bool { return fallbackCount(t, r, "") == 1 })

	// A DM to a person is between people.
	dmFrame(t, r.ws, "8e0f1a2b-3c4d-4e5f-8a6b-7c8d9e0f1a2b", "9e0f1a2b-3c4d-4e5f-8a6b-7c8d9e0f1a2b",
		"HUM-2", "just us")
	time.Sleep(200 * time.Millisecond)
	if n := len(r.pokes()); n != 1 {
		t.Fatalf("a DM to a human fell back: %v", r.pokes())
	}
}

// The poke line carries one line of the post, cut at 160 characters.
func TestFallbackPokeLine(t *testing.T) {
	m := &msg.Message{V: msg.V1, MsgID: "m", TaskID: "t", From: "HUM-1", To: "ALL-0", Kind: "note",
		Body: strings.Repeat("x", 100) + "\n\n" + strings.Repeat("y", 100)}
	got := hubclient.FallbackPoke(m, "#c", "CLE-1").Body
	head := "unanswered post in #c (no member agent online): "
	if !strings.HasPrefix(got, head+strings.Repeat("x", 100)+" y") || !strings.HasSuffix(got, "…") ||
		len([]rune(got)) != len(head)+160+1 {
		t.Fatalf("poke line: %q", got)
	}
}

// FR-039 (CLE-001, after go-live): a proof / test channel that opted out
// keeps the old behaviour - the unheard post reaches nobody - while a
// channel that did not opt out still falls back.
func TestFallbackChannelOptOut(t *testing.T) {
	r := newFallbackRig(t, true, "live-proof", "people")
	ctx := context.Background()
	fb := r.e.st.(store.Fallbacks)
	if err := fb.SetTenantResponders(ctx, r.tid, []string{"CLE-001"}); err != nil {
		t.Fatal(err)
	}
	if err := fb.SetChannelNoFallback(ctx, r.tid, "live-proof", true); err != nil {
		t.Fatal(err)
	}
	if err := fb.SetChannelNoFallback(ctx, r.tid, "no-such-channel", true); err != store.ErrNotFound {
		t.Fatalf("unknown channel: %v, want ErrNotFound", err)
	}
	threadFrame(t, r.ws, "3b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e", "1a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d", "live-proof", 1, "proof run")
	time.Sleep(300 * time.Millisecond)
	if n := len(inbox(t, r.desk, "CLE-001")); n != 0 || len(r.pokes()) != 0 {
		t.Fatalf("opted-out channel fell back: inbox %d pokes %v", n, r.pokes())
	}
	if f := fallbackOf(t, r, "live-proof"); f["off"] != true || f["active"] != false {
		t.Fatalf("members fallback of an opted-out channel: %v", f)
	}
	m2 := "4c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
	threadFrame(t, r.ws, m2, "2a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d", "people", 1, "hello?")
	eventually(t, "people still falls back", func() bool { return strings.Join(inboxIDs(t, r.desk, "CLE-001"), ",") == m2 })
	if f := fallbackOf(t, r, "people"); f["off"] != false {
		t.Fatalf("members fallback of a normal channel: %v", f)
	}
}
