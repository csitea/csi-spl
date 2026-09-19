package hub_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Tests for specs/003 contracts/channels-v1.md (US8, FR-024..FR-028).

func newTask() string { return uuidV4() }

func uuidV4() string {
	b := make([]byte, 16)
	rand.Read(b) //nolint:errcheck
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// chanMsg builds a v:1 message from box-a's GRK-03.
func chanMsg(task, to, kind, body string) *msg.Message {
	return &msg.Message{V: 1, MsgID: uuidV4(), TaskID: task, TS: time.Now().UTC().Format(time.RFC3339),
		From: "GRK-03", To: to, Kind: kind, Body: body, Files: []msg.Attachment{}}
}

// signedIn signs m from b with the optional channel / parent tags.
func signedIn(t *testing.T, b *box, toBox, channel, parent string, m *msg.Message) *wire.Envelope {
	t.Helper()
	priv, err := sign.LoadPrivate(b.cfg.KeysDir, b.id)
	if err != nil {
		t.Fatal(err)
	}
	e, err := wire.NewEnvelopeIn(priv, b.id, toBox, channel, parent, m)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

// rawBox holds a hand-driven role=box socket that announces channels.
type rawBox struct {
	t *testing.T
	c *websocket.Conn
}

func (e *env) rawBox(tenant string, b *box, agents, channels []string) *rawBox {
	e.t.Helper()
	c, nonce := e.raw(tenant)
	h := helloFrame(b, nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents, h.Channels = agents, channels
	wsjson.Write(context.Background(), c, h) //nolint:errcheck
	r := &rawBox{t: e.t, c: c}
	r.next(wire.TWelcome)
	r.next(wire.TQueueEnd)
	return r
}

// next returns the next frame of type want (others skipped) or fails.
func (r *rawBox) next(want string) wire.Frame {
	r.t.Helper()
	f, err := r.within(want, 5*time.Second)
	if err != nil {
		r.t.Fatalf("waiting for %s: %v", want, err)
	}
	return f
}

func (r *rawBox) within(want string, d time.Duration) (wire.Frame, error) {
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	for {
		var f wire.Frame
		if err := wsjson.Read(ctx, r.c, &f); err != nil {
			return f, err
		}
		if f.Type == want {
			return f, nil
		}
	}
}

func TestChannelMentionRouting(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07", "CLE-08")
	e.pin(tid, a)
	e.pin(tid, b)
	rb := e.rawBox(tid, b, []string{"CLE-07", "CLE-08"}, []string{"tasks"})
	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	task := uuidV4()
	post := func(channel, to, body string) (*msg.Message, wire.Frame, error) {
		m := chanMsg(task, to, "note", body)
		f, err := cli.Send(ctx, signedIn(t, a, hub.WUIBox, channel, "", m))
		return m, f, err
	}

	// Control: ambient chat in #tasks (no mention, to ALL-0) reaches no box.
	m0, f, err := post("tasks", "ALL-0", "ambient: build is green, @CLE-07x is not a mention")
	if err != nil || f.Delivery != wire.DeliverySent {
		t.Fatalf("ambient send: %v %+v", err, f)
	}
	if _, err := e.st.DeliveryState(ctx, tid, m0.MsgID, "box-b"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("ambient chat queued for box-b: %v", err)
	}
	if fr, err := rb.within(wire.TRecv, 300*time.Millisecond); err == nil {
		t.Fatalf("ambient chat pushed to box-b: %+v", fr)
	}
	rb.c.CloseNow() //nolint:errcheck // a timed-out read killed the socket
	rb = e.rawBox(tid, b, []string{"CLE-07", "CLE-08"}, []string{"tasks"})

	// @CLE-07 → box-b, agents [CLE-07].
	m1, _, err := post("tasks", "ALL-0", "@CLE-07 please run the suite")
	if err != nil {
		t.Fatal(err)
	}
	r := rb.next(wire.TRecv)
	if len(r.Agents) != 1 || r.Agents[0] != "CLE-07" {
		t.Fatalf("mention agents: %+v", r.Agents)
	}
	if got, _ := wire.ParseEnvelope(r.Env); got == nil || got.Channel != "tasks" || got.ToBox != hub.WUIBox {
		t.Fatalf("recv env: %s", r.Env)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, m1.MsgID, "box-b"); st != store.StateSent {
		t.Fatalf("mention delivery state %q", st)
	}

	// @channel → every member of box-b.
	if _, _, err := post("tasks", "ALL-0", "heads up @channel"); err != nil {
		t.Fatal(err)
	}
	if r := rb.next(wire.TRecv); len(r.Agents) != 2 {
		t.Fatalf("@channel agents: %+v", r.Agents)
	}

	// Not subscribed: #alerts mention of CLE-07 is not routed (box-b did not subscribe).
	m3, _, _ := post("alerts", "ALL-0", "@CLE-07 disk full")
	if _, err := e.st.DeliveryState(ctx, tid, m3.MsgID, "box-b"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unsubscribed channel routed: %v", err)
	}
	// ... but #lobby is implicit for every announced agent.
	m4, _, _ := post("general", "ALL-0", "@CLE-08 hi from the lobby alias")
	if r := rb.next(wire.TRecv); len(r.Agents) != 1 || r.Agents[0] != "CLE-08" {
		t.Fatalf("lobby mention: %+v", r.Agents)
	}
	rows, _ := e.st.ViewThreads(ctx, tid, store.ThreadQuery{Now: time.Now(), Channel: "lobby"})
	if len(rows) != 1 {
		t.Fatalf("general alias not stored as lobby: %+v", rows)
	}
	_ = m4

	// Offline: queued, drained on hello with agents recomputed.
	rb.c.CloseNow() //nolint:errcheck
	eventually(t, "box-b offline", func() bool {
		m, _, _ := post("tasks", "ALL-0", "@CLE-08 while you were out")
		st, _ := e.st.DeliveryState(ctx, tid, m.MsgID, "box-b")
		return st == store.StateQueued
	})
	rb = e.rawBoxNoDrain(tid, b, []string{"CLE-07", "CLE-08"}, []string{"tasks"})
	if r := rb.next(wire.TRecv); len(r.Agents) != 1 || r.Agents[0] != "CLE-08" {
		t.Fatalf("drained agents: %+v", r.Agents)
	}

	// Unknown channel and bad parent are refused, nothing stored.
	if _, _, err := post("nosuch", "ALL-0", "x"); err == nil || !strings.Contains(err.Error(), "unknown_channel") {
		t.Fatalf("unknown channel: %v", err)
	}
	bad := chanMsg(task, "ALL-0", "note", "x")
	if _, err := cli.Send(ctx, signedIn(t, a, hub.WUIBox, "tasks", task, bad)); err == nil || !strings.Contains(err.Error(), "bad_json") {
		t.Fatalf("parent == task accepted: %v", err)
	}
}

// rawBoxNoDrain is rawBox without consuming queue_end (queued recv come first).
func (e *env) rawBoxNoDrain(tenant string, b *box, agents, channels []string) *rawBox {
	e.t.Helper()
	c, nonce := e.raw(tenant)
	h := helloFrame(b, nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents, h.Channels = agents, channels
	wsjson.Write(context.Background(), c, h) //nolint:errcheck
	r := &rawBox{t: e.t, c: c}
	r.next(wire.TWelcome)
	return r
}

// A pre-M3 envelope (no tags) and a tagged one are stored with the right
// columns; the child thread lists under /children and not in the root list.
func TestChannelEnvelopeStored(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	root, child := uuidV4(), uuidV4()
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, a.id)
	legacy, _ := wire.NewEnvelope(priv, "box-a", "box-b", chanMsg(root, "CLE-07", "task", "legacy dm"))
	if f, err := cli.Send(ctx, legacy); err != nil || f.Delivery != wire.DeliveryQueued {
		t.Fatalf("legacy send: %v %+v", err, f)
	}
	if _, err := cli.Send(ctx, signedIn(t, a, "box-b", "tasks", root, chanMsg(child, "CLE-07", "task", "sub-task"))); err != nil {
		t.Fatal(err)
	}
	get := func(path string) map[string]any {
		t.Helper()
		resp, err := e.client.Get(e.url(tid) + path)
		if err != nil || resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s: %v %v", path, err, resp)
		}
		defer resp.Body.Close()
		var v map[string]any
		json.NewDecoder(resp.Body).Decode(&v) //nolint:errcheck
		return v
	}
	threads := func(v map[string]any) []map[string]any {
		var out []map[string]any
		for _, x := range v["threads"].([]any) {
			out = append(out, x.(map[string]any))
		}
		return out
	}
	roots := threads(get("/v1/view/threads"))
	if len(roots) != 1 || roots[0]["task_id"] != root || roots[0]["channel"] != nil || roots[0]["parent_task_id"] != nil {
		t.Fatalf("roots: %+v", roots)
	}
	kids := threads(get("/v1/view/threads/" + root + "/children"))
	if len(kids) != 1 || kids[0]["task_id"] != child || kids[0]["parent_task_id"] != root || kids[0]["channel"] != "tasks" {
		t.Fatalf("children: %+v", kids)
	}
	if all := threads(get("/v1/view/threads?roots=false")); len(all) != 2 {
		t.Fatalf("roots=false: %+v", all)
	}
	dms := threads(get("/v1/view/threads?dm=true&peer=CLE-07@box-b"))
	if len(dms) != 1 || dms[0]["task_id"] != root {
		t.Fatalf("dm peer: %+v", dms)
	}
	if dms := threads(get("/v1/view/threads?dm=true&peer=CLE-07@box-a")); len(dms) != 0 {
		t.Fatalf("dm peer wrong box: %+v", dms)
	}
	for _, bad := range []string{"?dm=yes", "?roots=1", "?peer=nobody"} {
		resp, _ := e.client.Get(e.url(tid) + "/v1/view/threads" + bad)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("%s: %d", bad, resp.StatusCode)
		}
		resp.Body.Close()
	}
	// The stored envelope keeps its signed tags byte-for-byte.
	msgs, _ := e.st.ViewThread(ctx, tid, store.ThreadMsgQuery{TaskID: child, Now: time.Now()})
	if len(msgs) != 1 || !bytes.Contains(msgs[0].Env, []byte(`"channel":"tasks"`)) || !bytes.Contains(msgs[0].Env, []byte(`"parent_task_id":"`+root+`"`)) {
		t.Fatalf("stored env: %+v", msgs)
	}
}

func TestChannelsCreateAndList(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	post := func(body string) (int, map[string]any) {
		req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/channels", strings.NewReader(body))
		req.Header.Set("Origin", wuiOrigin)
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.Header.Get("Access-Control-Allow-Origin") != wuiOrigin {
			t.Fatalf("no CORS on POST /v1/channels")
		}
		var v map[string]any
		raw, _ := io.ReadAll(resp.Body)
		json.Unmarshal(raw, &v) //nolint:errcheck
		return resp.StatusCode, v
	}
	if code, v := post(`{"channel":"releases","name":"Releases"}`); code != http.StatusCreated || v["channel"] != "releases" || v["created_by"] != "wui" || v["default"] != false {
		t.Fatalf("create: %d %+v", code, v)
	}
	for body, want := range map[string]string{
		`{"channel":"releases"}`: "channel_exists", `{"channel":"lobby"}`: "channel_exists",
		`{"channel":"general"}`: "channel_exists", `{"channel":"Bad Slug"}`: "bad_channel",
		`{"channel":"x","extra":1}`: "bad_json",
	} {
		if _, v := post(body); v["error"] != want {
			t.Fatalf("%s: %+v, want %s", body, v, want)
		}
	}
	req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+"/v1/channels", nil)
	req.Header.Set("Origin", wuiOrigin)
	resp, _ := e.client.Do(req)
	if resp.StatusCode != http.StatusNoContent || !strings.Contains(resp.Header.Get("Access-Control-Allow-Methods"), "POST") {
		t.Fatalf("preflight: %d %v", resp.StatusCode, resp.Header)
	}

	// Two lobby posts from a browser; list with a read mark after the first.
	w := dialWUI(t, e, tid, "HUM-1")
	w.send(map[string]any{"type": "send", "task_id": "lobby", "body": "one"})
	first := w.read("ack")
	w.send(map[string]any{"type": "send", "task_id": "lobby", "body": "two"})
	w.read("ack")
	w.send(map[string]any{"type": "send", "task_id": newTask(), "channel": "nosuch", "body": "x"})
	if f := w.read("error"); f.Error != "unknown_channel" {
		t.Fatalf("browser unknown channel: %+v", f)
	}

	list := func(q string) map[string]map[string]any {
		resp, err := e.client.Get(e.url(tid) + "/v1/view/channels" + q)
		if err != nil || resp.StatusCode != http.StatusOK {
			t.Fatalf("list: %v %v", err, resp)
		}
		defer resp.Body.Close()
		var v struct {
			Channels []map[string]any `json:"channels"`
		}
		json.NewDecoder(resp.Body).Decode(&v) //nolint:errcheck
		out := map[string]map[string]any{}
		for _, c := range v.Channels {
			out[c["channel"].(string)] = c
		}
		return out
	}
	all := list("")
	if len(all) != 4 || all["alerts"]["retention_days"] != float64(7) || all["tasks"]["retention_days"] != float64(30) ||
		all["releases"]["name"] != "Releases" || all["tasks"]["last_ts"] != nil {
		t.Fatalf("channels: %+v", all)
	}
	if l := all["lobby"]; l["count"] != float64(2) || l["unread"] != float64(2) || l["default"] != true ||
		l["members"].(map[string]any)["posters"] != float64(1) {
		t.Fatalf("lobby: %+v", l)
	}
	marked := list("?read=general~" + url.QueryEscape(first.Cursor))
	if marked["lobby"]["unread"] != float64(1) {
		t.Fatalf("unread after mark: %+v", marked["lobby"])
	}
	resp, _ = e.client.Get(e.url(tid) + "/v1/view/channels?read=lobby~garbage")
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad read cursor: %d", resp.StatusCode)
	}
}

type presence struct {
	Type   string `json:"type"`
	Peer   string `json:"peer"`
	Status string `json:"status"`
}

func (w *wuiClient) presence(peer, status string) {
	w.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var f presence
		if err := wsjson.Read(ctx, w.c, &f); err != nil {
			w.t.Fatalf("waiting for presence %s %s: %v", peer, status, err)
		}
		if f.Type == "presence" && f.Peer == peer && f.Status == status {
			return
		}
	}
}

func TestWUIPresence(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)

	w := dialWUI(t, e, tid, "HUM-1")
	x := dialWUI(t, e, other, "HUM-9") // another tenant sees nothing of tid

	rb := e.rawBox(tid, a, []string{"GRK-03"}, nil)
	w.presence("GRK-03@box-a", "online")

	// A second browser gets the snapshot (box agent + HUM-1) after welcome.
	v := dialWUI(t, e, tid, "HUM-2")
	v.presence("GRK-03@box-a", "online")
	w.presence("HUM-2@box-wui", "online")

	// announce diff: GRK-04 joins, GRK-03 leaves.
	wsjson.Write(context.Background(), rb.c, wire.Frame{Type: wire.TAnnounce, Agents: []string{"GRK-04"}}) //nolint:errcheck
	w.presence("GRK-04@box-a", "online")
	w.presence("GRK-03@box-a", "offline")

	// Box closes → offline; last HUM-2 socket closes → offline.
	rb.c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	w.presence("GRK-04@box-a", "offline")
	v.c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	w.presence("HUM-2@box-wui", "offline")

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	for {
		var f presence
		if err := wsjson.Read(ctx, x.c, &f); err != nil {
			break
		}
		if f.Type == "presence" && f.Peer != "HUM-9@box-wui" {
			t.Fatalf("cross-tenant presence: %+v", f)
		}
	}
}

// The real box client: SPOOL_CHANNELS reaches the hub in hello, a mention in
// #tasks lands in the addressed agent's inbox only, v:1 unchanged.
func TestHubclientChannelRecv(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07", "CLE-08")
	b.cfg.Channels = " Tasks , releases,"
	e.pin(tid, a)
	e.pin(tid, b)
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()
	if m, _ := e.st.ChannelMembers(ctx, tid, "tasks"); len(m["box-b"]) != 2 {
		t.Fatalf("SPOOL_CHANNELS not announced: %+v", m)
	}
	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	ambient := chanMsg(uuidV4(), "ALL-0", "note", "nothing for anyone")
	if _, err := cli.Send(ctx, signedIn(t, a, hub.WUIBox, "tasks", "", ambient)); err != nil {
		t.Fatal(err)
	}
	m := chanMsg(uuidV4(), "ALL-0", "task", "@CLE-07 run the suite")
	if _, err := cli.Send(ctx, signedIn(t, a, hub.WUIBox, "tasks", "", m)); err != nil {
		t.Fatal(err)
	}
	eventually(t, "CLE-07 inbox", func() bool { return len(inbox(t, b, "CLE-07")) == 1 })
	got := inbox(t, b, "CLE-07")[0]
	if got.MsgID != m.MsgID || got.To != "ALL-0" || got.Body != m.Body {
		t.Fatalf("inbox copy: %+v", got)
	}
	if n := len(inbox(t, b, "CLE-08")); n != 0 {
		t.Fatalf("CLE-08 got %d messages", n)
	}
	if errs := sb.RecvErrors(); len(errs) != 0 {
		t.Fatalf("recv errors: %v", errs)
	}
}
