package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// memberHeader stands in for a 010 member session cookie through the
// hub.Options.SessionID seam (a real session needs the IdP round trip).
const memberHeader = "X-Test-Member"

func dispatchEnv(t *testing.T, on bool, key ed25519.PrivateKey) *env {
	return newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.WUIKey, o.WUIDispatch = key, on
		o.Authorizer = rbac.Fixed(rbac.Developer) // 025: seam humans hold the developer role
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
}

// dialMember opens a browser socket; member "" = no session.
func dialMember(t *testing.T, e *env, tenant, as, member string) *websocket.Conn {
	t.Helper()
	h := http.Header{}
	if member != "" {
		h.Set(memberHeader, member)
	}
	c, _, err := websocket.Dial(context.Background(), "ws://"+tenant+domain+"/v1/wui/ws",
		&websocket.DialOptions{HTTPClient: e.client, HTTPHeader: h})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { c.CloseNow() })                                                  //nolint:errcheck
	wsjson.Write(context.Background(), c, map[string]string{"type": "hello", "as": as}) //nolint:errcheck
	readType(t, c, "welcome")
	return c
}

// readType returns the next frame of type want, or of type error.
func readType(t *testing.T, c *websocket.Conn, want string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var f map[string]any
		if err := wsjson.Read(ctx, c, &f); err != nil {
			t.Fatalf("waiting for %s: %v", want, err)
		}
		if f["type"] == want || f["type"] == "error" {
			return f
		}
	}
}

func sendFrame(t *testing.T, c *websocket.Conn, id, kind, body, to string) map[string]any {
	t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": "lobby", "kind": kind, "body": body}
	if to != "" {
		f["to"] = to
	}
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	return readType(t, c, "ack")
}

func b64(p ed25519.PublicKey) string { return base64.StdEncoding.EncodeToString(p) }

// 014 T014 positive: a member's "@CLE-07 run tests" becomes a deliveries row
// for box-a whose sig verifies against the tenant's box-wui pin with the box
// verify code (sign.LoadPin + wire.Envelope.Verify); the box, once online,
// writes it to CLE-07's inbox.
func TestWUIDispatchSignedDeliveryVerifiesAgainstPin(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	e := dispatchEnv(t, true, key)
	tid, root := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	if err := e.st.SetRoster(ctx, tid, "box-a", []string{"CLE-07"}, time.Now()); err != nil {
		t.Fatal(err)
	}

	// The operator reads the hub key and pins it with the tenant root key.
	code, _, body := viewGet(t, e, tid, "/v1/wui/pubkey")
	var pk struct {
		BoxID    string `json:"box_id"`
		PubKey   string `json:"pubkey"`
		Dispatch bool   `json:"dispatch"`
	}
	json.Unmarshal(body, &pk) //nolint:errcheck
	if code != http.StatusOK || pk.BoxID != hub.WUIBox || pk.PubKey != b64(pub) || !pk.Dispatch {
		t.Fatalf("pubkey: %d %s", code, body)
	}
	if code, eb := e.postPin(tid, root, hub.WUIBox, pk.PubKey); code != http.StatusOK {
		t.Fatalf("pin box-wui: %d %+v", code, eb)
	}

	w := dialMember(t, e, tid, "Alice", "HUM-google-sub-1@"+tid)
	id := "5a1c0d2e-3f4b-4c5d-8e6f-7a8b9c0d1e2f"
	ack := sendFrame(t, w, id, "task", "@CLE-07 run tests", "")
	if ack["type"] != "ack" || ack["to_box"] != "box-a" || ack["delivery"] != wire.DeliveryQueued {
		t.Fatalf("ack %v", ack)
	}

	// The deliveries row for box-a carries the signed envelope.
	q, err := e.st.QueuedFor(ctx, tid, "box-a", time.Now())
	if err != nil || len(q) != 1 || q[0].MsgID != id {
		t.Fatalf("queued for box-a: %v %+v", err, q)
	}
	envl, err := wire.ParseEnvelope(q[0].Env)
	if err != nil {
		t.Fatal(err)
	}
	if envl.FromBox != hub.WUIBox || envl.ToBox != "box-a" || envl.Sig == "" {
		t.Fatalf("envelope %+v", envl)
	}
	m, err := envl.Inner()
	if err != nil {
		t.Fatal(err)
	}
	if m.To != "CLE-07" || m.Kind != "task" || m.From == "Alice" || m.From == "HUM-google-sub-1@"+tid || m.From[:4] != "HUM-" {
		t.Fatalf("inner v:1 %+v (from must be the session's HUM id, never hello.as)", m)
	}

	// Verify exactly as a box does: the pin as GET /v1/pins publishes it,
	// installed in a pins dir, loaded with sign.LoadPin, checked with Verify.
	pins, _ := e.st.ListPins(ctx, tid)
	dir := filepath.Join(t.TempDir(), "pins")
	for _, p := range pins {
		if err := sign.Pin(dir, p.BoxID, b64(p.PubKey), false); err != nil {
			t.Fatal(err)
		}
	}
	boxPin, err := sign.LoadPin(dir, hub.WUIBox)
	if err != nil {
		t.Fatalf("box-wui pin not published: %v", err)
	}
	if err := envl.Verify(boxPin); err != nil {
		t.Fatalf("dispatched envelope does not verify against the box-wui pin: %v", err)
	}

	// CONTROL: the same verify refuses a tampered envelope and a foreign key.
	tampered := *envl
	tampered.ToBox = "box-b"
	if err := tampered.Verify(boxPin); !errors.Is(err, sign.ErrVerify) {
		t.Fatalf("tampered to_box verified: %v", err)
	}
	tampered = *envl
	tampered.Msg = json.RawMessage(string(envl.Msg[:len(envl.Msg)-1]) + `,"x":1}`)
	if err := tampered.Verify(boxPin); !errors.Is(err, sign.ErrVerify) {
		t.Fatalf("tampered msg verified: %v", err)
	}
	other, _, _ := ed25519.GenerateKey(nil)
	if err := envl.Verify(other); !errors.Is(err, sign.ErrVerify) {
		t.Fatalf("verified against a key that is not the pin: %v", err)
	}

	// End to end: box-a comes online, syncs the box-wui pin, drains the queue.
	s, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	eventually(t, "CLE-07 inbox on box-a", func() bool { return len(inbox(t, a, "CLE-07")) == 1 })
	if got := inbox(t, a, "CLE-07")[0]; got.MsgID != id || got.Body != "@CLE-07 run tests" || got.From != m.From {
		t.Fatalf("inbox %+v", got)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, id, "box-a"); st != store.StateSent {
		t.Fatalf("delivery state %q", st)
	}
}

// 014 T014 controls: each refusal answers its token and stores nothing.
func TestWUIDispatchRefusals(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(nil)
	e := dispatchEnv(t, true, key)
	tid, root := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	now := time.Now()
	e.st.SetRoster(ctx, tid, "box-a", []string{"CLE-07", "GRK-2"}, now) //nolint:errcheck
	e.st.SetRoster(ctx, tid, "box-b", []string{"GRK-2"}, now)           //nolint:errcheck
	e.st.SetRoster(ctx, tid, "box-c", []string{"AGY-3"}, now)           //nolint:errcheck
	member := "HUM-google-sub-1@" + tid
	n := 0
	refused := func(c *websocket.Conn, kind, body, to, want string) {
		t.Helper()
		n++
		id := "00000000-0000-4000-8000-0000000001" + string(rune('0'+n/10)) + string(rune('0'+n%10))
		f := sendFrame(t, c, id, kind, body, to)
		if f["type"] != "error" || f["error"] != want {
			t.Fatalf("%s: got %v", want, f)
		}
		if has, _ := e.st.HasMessage(ctx, tid, id); has {
			t.Fatalf("%s: message was stored", want)
		}
	}

	// A pin for box-wui with any key but the hub's is refused.
	otherPub, _, _ := ed25519.GenerateKey(nil)
	if code, eb := e.postPin(tid, root, hub.WUIBox, b64(otherPub)); code != http.StatusBadRequest || eb.Error != "wui_key_mismatch" {
		t.Fatalf("foreign box-wui pin: %d %+v", code, eb)
	}

	m := dialMember(t, e, tid, "Alice", member)
	refused(m, "task", "@CLE-07 run tests", "", "wui_unpinned") // tenant never pinned box-wui

	// A box-wui pin that is not the hub's current key (rotation window) is
	// refused too; the store is written directly, bypassing the REST guard.
	e.pinKey(tid, hub.WUIBox, otherPub)
	refused(m, "task", "@CLE-07 run tests", "", "wui_unpinned")
	if err := e.st.PutPin(ctx, tid, hub.WUIBox, key.Public().(ed25519.PublicKey), true, time.Now().Add(time.Second), time.Now()); err != nil {
		t.Fatal(err)
	}

	anon := dialMember(t, e, tid, "HUM-9", "")
	refused(anon, "task", "@CLE-07 run tests", "", "dispatch_unauthenticated")
	refused(anon, "task", "run tests", "CLE-07", "dispatch_unauthenticated")
	refused(m, "result", "@CLE-07 done", "", "dispatch_kind")
	refused(m, "task", "@ZZZ-404 hello", "", "unknown_agent")
	refused(m, "task", "@GRK-2 hello", "", "ambiguous_to_box")
	refused(m, "task", "@AGY-3 hello", "", "unpinned_box")

	// A hello as box-wui is refused even when signed with the hub's own key.
	c, nonce := e.raw(tid)
	ts := time.Now().UTC().Format(time.RFC3339)
	p, _ := wire.HelloPayload(hub.WUIBox, nonce, ts)
	wsjson.Write(ctx, c, wire.Frame{Type: wire.THello, BoxID: hub.WUIBox, TS: ts, Nonce: nonce, Role: wire.RoleBox, //nolint:errcheck
		Agents: []string{"CLE-99"}, Sig: sign.Sign(key, p)})
	if code, reason := closeReason(t, c); code != wire.CloseUnauthorized || reason != "unauthorized" {
		t.Fatalf("box-wui hello: %d %s", code, reason)
	}

	// Browser-only sends are unchanged with the flag on: no mention, a lobby
	// broadcast, a mention that is not leading, a HUM-* recipient.
	for i, body := range []string{"hello all", "thanks @CLE-07"} {
		id := "00000000-0000-4000-8000-00000000020" + string(rune('0'+i))
		if f := sendFrame(t, anon, id, "note", body, ""); f["type"] != "ack" || f["to_box"] != nil {
			t.Fatalf("browser-only %q: %v", body, f)
		}
		if _, err := e.st.DeliveryState(ctx, tid, id, "box-a"); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("browser-only %q reached box-a: %v", body, err)
		}
	}
}

// 014 FR-010 CONTROL: with SPOOL_HUB_WUI_DISPATCH off, a member's
// "@CLE-07 ..." stays browser-only (box-wui -> box-wui, empty sig), and a
// box-wui pin is still refused when the hub has no key.
func TestWUIDispatchFlagOff(t *testing.T) {
	e := dispatchEnv(t, false, nil)
	tid, root := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	e.st.SetRoster(ctx, tid, "box-a", []string{"CLE-07"}, time.Now()) //nolint:errcheck
	pub, _, _ := ed25519.GenerateKey(nil)
	if code, eb := e.postPin(tid, root, hub.WUIBox, b64(pub)); code != http.StatusBadRequest || eb.Error != "bad_json" {
		t.Fatalf("box-wui pin without a hub key: %d %+v", code, eb)
	}
	if code, _, _ := viewGet(t, e, tid, "/v1/wui/pubkey"); code != http.StatusNotFound {
		t.Fatalf("pubkey without a key: %d", code)
	}
	w := dialMember(t, e, tid, "Alice", "HUM-google-sub-1@"+tid)
	id := "6b2d1e3f-4a5c-4d6e-9f70-8a9b0c1d2e3f"
	if f := sendFrame(t, w, id, "task", "@CLE-07 run tests", ""); f["type"] != "ack" || f["to_box"] != nil {
		t.Fatalf("flag off: %v", f)
	}
	envs, _ := e.st.TaskEnvelopes(ctx, tid, lobby)
	if len(envs) != 1 {
		t.Fatalf("stored %d", len(envs))
	}
	envl, _ := wire.ParseEnvelope(envs[0])
	if envl.FromBox != hub.WUIBox || envl.ToBox != hub.WUIBox || envl.Sig != "" {
		t.Fatalf("flag off envelope %+v", envl)
	}
	if _, err := e.st.DeliveryState(ctx, tid, id, "box-a"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("flag off reached box-a: %v", err)
	}
}

// channelFrame sends a browser post tagged with a channel (the WUI sets
// `channel` whenever a channel page is open, stores/channel.ts).
func channelFrame(t *testing.T, c *websocket.Conn, id, task, channel, body string) map[string]any {
	t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": task, "kind": "note",
		"body": body, "channel": channel}
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	return readType(t, c, "ack")
}

// Owner rule 2026-09-22 ("if we are in a channel - all of the participants in
// the channel will receive the msg"), the browser half: a plain line a member
// types into a channel - no @mention, no `to` - is signed with the box-wui key
// and box-routed to EVERY box that hosts a member, and lands in the inbox of
// every member on that box.
//
// This is the case the hub answered with nothing at all before: the send was
// unsigned, and routeChannel drops unsigned envelopes.
func TestWUIChannelPostReachesEveryMemberBox(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	e := dispatchEnv(t, true, key)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07", "CLE-08")
	b := e.box(tid, "box-b", "GRK-03")
	c := e.box(tid, "box-c", "AGY-09") // pinned, announced, NOT in the channel
	a.cfg.Channels, b.cfg.Channels = "releases", "releases"
	e.pin(tid, a)
	e.pin(tid, b)
	e.pin(tid, c)
	e.pinKey(tid, hub.WUIBox, pub)
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "releases",
		Name: "releases", CreatedBy: "hub", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for _, x := range []struct {
		box    string
		agents []string
		chans  []string
	}{{"box-a", []string{"CLE-07", "CLE-08"}, []string{"releases"}},
		{"box-b", []string{"GRK-03"}, []string{"releases"}},
		{"box-c", []string{"AGY-09"}, nil}} {
		if err := e.st.SetRoster(ctx, tid, x.box, x.agents, now); err != nil {
			t.Fatal(err)
		}
		if err := e.st.SetSubscriptions(ctx, tid, x.box, x.agents, x.chans, now); err != nil {
			t.Fatal(err)
		}
	}

	// rdb 0028: a human posts into a channel they are IN. Before the read
	// door this was implicit - every member of the tenant was in every
	// channel - and the post is refused without it.
	if err := e.st.AddChannelHumans(ctx, tid, "releases", []string{"HUM-google-sub-1@" + tid}, "hub", now); err != nil {
		t.Fatal(err)
	}
	w := dialMember(t, e, tid, "Alice", "HUM-google-sub-1@"+tid)
	task := "9e5a4b62-7d8f-4a91-8bc3-2d3e4f5a6b7c"
	id := "1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9"
	if ack := channelFrame(t, w, id, task, "releases", "standup in five"); ack["type"] != "ack" {
		t.Fatalf("channel post: %v", ack)
	}

	// One signed envelope, to_box box-wui: no single box owns a channel post.
	envs, _ := e.st.TaskEnvelopes(ctx, tid, task)
	if len(envs) != 1 {
		t.Fatalf("stored %d envelopes", len(envs))
	}
	envl, err := wire.ParseEnvelope(envs[0])
	if err != nil {
		t.Fatal(err)
	}
	if envl.FromBox != hub.WUIBox || envl.ToBox != hub.WUIBox || envl.Channel != "releases" || envl.Sig == "" {
		t.Fatalf("channel envelope %+v", envl)
	}
	if err := envl.Verify(pub); err != nil {
		t.Fatalf("channel post does not verify against the box-wui pin: %v", err)
	}

	// A deliveries row per member box - and none for the box that did not join.
	for _, box := range []string{"box-a", "box-b"} {
		q, err := e.st.QueuedFor(ctx, tid, box, time.Now())
		if err != nil || len(q) != 1 || q[0].MsgID != id {
			t.Fatalf("queued for %s: %v %+v", box, err, q)
		}
	}
	if _, err := e.st.DeliveryState(ctx, tid, id, "box-c"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("a box that is not in the channel was enqueued: %v", err)
	}

	// End to end: both boxes come online and every member reads it.
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sa.Close()
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()
	for _, x := range []struct {
		b  *box
		as string
	}{{a, "CLE-07"}, {a, "CLE-08"}, {b, "GRK-03"}} {
		eventually(t, x.as+" inbox", func() bool { return len(inbox(t, x.b, x.as)) == 1 })
		if got := inbox(t, x.b, x.as)[0]; got.MsgID != id || got.Body != "standup in five" {
			t.Fatalf("%s inbox %+v", x.as, got)
		}
	}
	if errs := sa.RecvErrors(); len(errs) != 0 {
		t.Fatalf("box-a recv errors: %v", errs)
	}
	if errs := sb.RecvErrors(); len(errs) != 0 {
		t.Fatalf("box-b recv errors: %v", errs)
	}
}

// 025 CONTROL: the fan-out is what agents.command buys. A tester (notes.send,
// no agents.command) still posts - the message is stored and reaches every
// browser - but the post stays browser-only: unsigned, no box delivery. The
// post itself is NOT raised to agents.command, because #lobby has every
// announced agent as a member and that would silence the role altogether.
func TestWUIChannelPostWithoutAgentsCommandStaysBrowserOnly(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.WUIKey, o.WUIDispatch = key, true
		o.Authorizer = rbac.Fixed(rbac.Tester)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	e.pinKey(tid, hub.WUIBox, pub)
	now := time.Now()
	e.st.SetRoster(ctx, tid, "box-a", []string{"CLE-07"}, now)                           //nolint:errcheck
	e.st.SetSubscriptions(ctx, tid, "box-a", []string{"CLE-07"}, []string{"tasks"}, now) //nolint:errcheck

	w := dialMember(t, e, tid, "Alice", "HUM-google-sub-1@"+tid)
	task := "3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e7f"
	id := "4d5e6f7a-8b9c-4d1e-9f20-3b4c5d6e7f80"
	if ack := channelFrame(t, w, id, task, "tasks", "a tester says hello"); ack["type"] != "ack" {
		t.Fatalf("tester post: %v", ack)
	}
	envs, _ := e.st.TaskEnvelopes(ctx, tid, task)
	if len(envs) != 1 {
		t.Fatalf("tester post not stored: %d", len(envs))
	}
	if envl, _ := wire.ParseEnvelope(envs[0]); envl == nil || envl.Sig != "" {
		t.Fatalf("a role without agents.command signed a post: %+v", envl)
	}
	if _, err := e.st.DeliveryState(ctx, tid, id, "box-a"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("a role without agents.command reached a box: %v", err)
	}
}

// 014 FR-009: a box accepts a box-wui envelope only for kind task|note. The
// hub never builds another kind; Deliver (the hub-originated path) is used to
// push one anyway, followed by a note that must arrive — so the result's
// absence is the refusal, not a slow push.
func TestBoxRefusesBoxWUIResult(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	e := dispatchEnv(t, true, key)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	e.pinKey(tid, hub.WUIBox, pub)
	s, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for i, kind := range []string{"result", "note"} {
		m := testMsg(t, "HUM-1", "CLE-07", kind, "k="+kind, "7c3e2f40-5b6d-4e7f-8a91-0b1c2d3e4f5"+string(rune('0'+i)))
		envl, err := wire.NewEnvelope(key, hub.WUIBox, "box-a", m)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := e.srv.Deliver(ctx, tid, envl); err != nil {
			t.Fatalf("deliver %s: %v", kind, err)
		}
	}
	eventually(t, "the note in CLE-07's inbox", func() bool { return len(inbox(t, a, "CLE-07")) >= 1 })
	got := inbox(t, a, "CLE-07")
	if len(got) != 1 || got[0].Kind != "note" {
		t.Fatalf("box accepted a box-wui kind=result: %+v", got)
	}
}

func testMsg(t *testing.T, from, to, kind, body, id string) *msg.Message {
	t.Helper()
	m := &msg.Message{V: msg.Version, MsgID: id, TaskID: "8d4f3a51-6c7e-4f80-9ba2-1c2d3e4f5a6b",
		TS: time.Now().UTC().Format(time.RFC3339), From: from, To: to, Kind: kind, Body: body, Files: []msg.Attachment{}}
	if err := m.Validate(); err != nil {
		t.Fatal(err)
	}
	return m
}
