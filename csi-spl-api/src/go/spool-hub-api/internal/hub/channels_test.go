package hub_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

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
	t     *testing.T
	c     *websocket.Conn
	trace func(format string, args ...any) // nil = off
}

func (r *rawBox) tracef(format string, args ...any) {
	if r.trace != nil {
		r.trace(format, args...)
	}
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
		r.tracef("frame %s count=%d agents=%v (want %s)", f.Type, f.Count, f.Agents, want)
		if f.Type == want {
			return f, nil
		}
	}
}

// traceOnFailure collects timestamped steps and the hub log, printed only when
// the test fails (H6: the CI-only timeouts left nothing to read), or always
// with SPOOL_TEST_TRACE=1.
func traceOnFailure(t *testing.T) (func(string, ...any), func(*hub.Options)) {
	var mu sync.Mutex
	var lines []string
	var hubLog bytes.Buffer
	t0 := time.Now()
	add := func(format string, args ...any) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, fmt.Sprintf("%8.3fms ", float64(time.Since(t0).Microseconds())/1000)+fmt.Sprintf(format, args...))
	}
	t.Cleanup(func() {
		if !t.Failed() && os.Getenv("SPOOL_TEST_TRACE") == "" {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		for _, l := range lines {
			t.Log(l)
		}
		t.Log("hub log:\n" + hubLog.String())
	})
	return add, func(o *hub.Options) { o.Log = zerolog.New(&syncWriter{w: &hubLog}).With().Timestamp().Logger() }
}

type syncWriter struct {
	mu sync.Mutex
	w  *bytes.Buffer
}

func (s *syncWriter) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.w.Write(p)
}

func TestChannelMembershipRouting(t *testing.T) {
	trace, withLog := traceOnFailure(t)
	e := newEnv(t, withLog)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07", "CLE-08")
	e.pin(tid, a)
	e.pin(tid, b)
	rb := e.rawBox(tid, b, []string{"CLE-07", "CLE-08"}, []string{"tasks"})
	// Owner decision 2026-09-25: announcing a default channel joins nobody;
	// a member picks its agents (POST /v1/channels/tasks/agents).
	if m, _ := e.st.ChannelMembers(ctx, tid, "tasks"); len(m) != 0 {
		t.Fatalf("announce put agents in #tasks: %+v", m)
	}
	for _, id := range []string{"CLE-07", "CLE-08"} {
		if err := e.st.InviteChannelAgent(ctx, tid, "tasks", "box-b", id, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	// specs/038 FR-004: only a member agent posts into a channel, so the
	// poster is seated in every channel it writes to below.
	for _, ch := range []string{"tasks", "alerts", "lobby"} {
		if err := e.st.InviteChannelAgent(ctx, tid, ch, "box-a", "GRK-03", time.Now()); err != nil {
			t.Fatal(err)
		}
	}
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

	// THE control for the owner rule (2026-09-22): a plain line in #tasks,
	// no mention and a broadcast `to`, reaches BOTH members of box-b. Delete
	// the membership routing and this is the assertion that goes red - the
	// pre-rule hub answered "no deliveries row, no recv" here.
	m0, f, err := post("tasks", "ALL-0", "build is green, @CLE-07x is not a mention")
	if err != nil || f.Delivery != wire.DeliverySent {
		t.Fatalf("plain send: %v %+v", err, f)
	}
	if r := rb.next(wire.TRecv); len(r.Agents) != 2 || r.Agents[0] != "CLE-07" || r.Agents[1] != "CLE-08" {
		t.Fatalf("plain post agents: %+v (a channel post addresses every member)", r.Agents)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, m0.MsgID, "box-b"); st != store.StateSent {
		t.Fatalf("plain post delivery state %q", st)
	}

	// A mention neither narrows nor widens it: still every member.
	m1, _, err := post("tasks", "ALL-0", "@CLE-07 please run the suite")
	if err != nil {
		t.Fatal(err)
	}
	r := rb.next(wire.TRecv)
	if len(r.Agents) != 2 {
		t.Fatalf("mention agents: %+v", r.Agents)
	}
	if got, _ := wire.ParseEnvelope(r.Env); got == nil || got.Channel != "tasks" || got.ToBox != hub.WUIBox {
		t.Fatalf("recv env: %s", r.Env)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, m1.MsgID, "box-b"); st != store.StateSent {
		t.Fatalf("mention delivery state %q", st)
	}
	if _, _, err := post("tasks", "ALL-0", "heads up @channel"); err != nil {
		t.Fatal(err)
	}
	if r := rb.next(wire.TRecv); len(r.Agents) != 2 {
		t.Fatalf("@channel agents: %+v", r.Agents)
	}

	// CONTROL: membership is what routes, not the body. #alerts is a channel
	// box-b did not join, so even a mention of CLE-07 reaches no box.
	m3, _, _ := post("alerts", "ALL-0", "@CLE-07 disk full")
	if _, err := e.st.DeliveryState(ctx, tid, m3.MsgID, "box-b"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unsubscribed channel routed: %v", err)
	}
	// CONTROL: a DM (no channel tag, not the lobby task) is not fanned out
	// either - the owner rule is about channels, and DM routing is untouched.
	dm := chanMsg(uuidV4(), "CLE-07", "note", "just for you")
	if _, err := cli.Send(ctx, signedIn(t, a, hub.WUIBox, "", "", dm)); err != nil {
		t.Fatal(err)
	}
	if _, err := e.st.DeliveryState(ctx, tid, dm.MsgID, "box-b"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("DM channel-routed to box-b: %v", err)
	}

	// CONTROL (owner decision 2026-09-25): #lobby is no longer implicit for
	// every announced agent. Nobody picked one, so a lobby post reaches no box.
	m5, _, _ := post("lobby", "ALL-0", "nobody picked an agent yet")
	if _, err := e.st.DeliveryState(ctx, tid, m5.MsgID, "box-b"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("lobby post reached an agent nobody added: %v", err)
	}
	// Once a member adds them, #lobby routes like any channel, under the
	// general alias too.
	for _, id := range []string{"CLE-07", "CLE-08"} {
		if err := e.st.InviteChannelAgent(ctx, tid, "lobby", "box-b", id, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	m4, _, _ := post("general", "ALL-0", "hi from the lobby alias")
	if r := rb.next(wire.TRecv); len(r.Agents) != 2 {
		t.Fatalf("lobby post: %+v", r.Agents)
	}
	rows, _ := e.st.ViewTopics(ctx, tid, store.TopicQuery{Now: time.Now(), Channel: "lobby"})
	if len(rows) != 1 || rows[0].Count != 2 {
		t.Fatalf("general alias not stored as lobby: %+v", rows)
	}
	_ = m4

	// Offline: queued, drained on hello with the member list recomputed.
	trace("body done up to offline")
	trace("offline: CloseNow box-b")
	rb.c.CloseNow() //nolint:errcheck
	eventually(t, "box-b offline", func() bool {
		m, f, err := post("tasks", "ALL-0", "while you were out")
		st, serr := e.st.DeliveryState(ctx, tid, m.MsgID, "box-b")
		trace("offline post %s: send err=%v delivery=%q; box-b row %q (%v)", m.MsgID, err, f.Delivery, st, serr)
		return st == store.StateQueued
	})
	trace("reconnect box-b (no drain)")
	rb = e.rawBoxNoDrain(tid, b, []string{"CLE-07", "CLE-08"}, []string{"tasks"})
	rb.trace = trace
	trace("welcome read; waiting for the drained recv")
	if r := rb.next(wire.TRecv); len(r.Agents) != 2 {
		t.Fatalf("drained agents: %+v", r.Agents)
	}

	trace("drained recv read")
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
// columns; the child topic lists under /children and not in the root list.
func TestChannelEnvelopeStored(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	if err := e.st.InviteChannelAgent(ctx, tid, "tasks", "box-a", "GRK-03", time.Now()); err != nil { // specs/038
		t.Fatal(err)
	}
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
	topics := func(v map[string]any) []map[string]any {
		var out []map[string]any
		for _, x := range v["topics"].([]any) {
			out = append(out, x.(map[string]any))
		}
		return out
	}
	roots := topics(get("/v1/view/topics"))
	if len(roots) != 1 || roots[0]["task_id"] != root || roots[0]["channel"] != nil || roots[0]["parent_task_id"] != nil {
		t.Fatalf("roots: %+v", roots)
	}
	kids := topics(get("/v1/view/topics/" + root + "/children"))
	if len(kids) != 1 || kids[0]["task_id"] != child || kids[0]["parent_task_id"] != root || kids[0]["channel"] != "tasks" {
		t.Fatalf("children: %+v", kids)
	}
	if all := topics(get("/v1/view/topics?roots=false")); len(all) != 2 {
		t.Fatalf("roots=false: %+v", all)
	}
	dms := topics(get("/v1/view/topics?dm=true&peer=CLE-07@box-b"))
	if len(dms) != 1 || dms[0]["task_id"] != root {
		t.Fatalf("dm peer: %+v", dms)
	}
	if dms := topics(get("/v1/view/topics?dm=true&peer=CLE-07@box-a")); len(dms) != 0 {
		t.Fatalf("dm peer wrong box: %+v", dms)
	}
	for _, bad := range []string{"?dm=yes", "?roots=1", "?peer=nobody"} {
		resp, _ := e.client.Get(e.url(tid) + "/v1/view/topics" + bad)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("%s: %d", bad, resp.StatusCode)
		}
		resp.Body.Close()
	}
	// The stored envelope keeps its signed tags byte-for-byte.
	msgs, _ := e.st.ViewTopic(ctx, tid, store.TopicMsgQuery{TaskID: child, Now: time.Now()})
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
	/* the description the WUI dialog collects next to the title (rdb 0027):
	   trimmed, echoed by the 201, and readable again from §5.2 below */
	if code, v := post(`{"channel":"releases","name":"Releases","description":"  what ships, and when  "}`); code != http.StatusCreated ||
		v["channel"] != "releases" || v["created_by"] != "wui" || v["default"] != false ||
		v["description"] != "what ships, and when" {
		t.Fatalf("create: %d %+v", code, v)
	}
	/* omitted description is "", never null: one shape for every client */
	if code, v := post(`{"channel":"quiet"}`); code != http.StatusCreated || v["description"] != "" {
		t.Fatalf("create without description: %d %+v", code, v)
	}
	for body, want := range map[string]string{
		`{"channel":"releases"}`: "channel_exists", `{"channel":"lobby"}`: "channel_exists",
		`{"channel":"general"}`: "channel_exists", `{"channel":"Bad Slug"}`: "bad_channel",
		`{"channel":"x","extra":1}`: "bad_json",
		`{"channel":"toolong","description":"` + strings.Repeat("d", 501) + `"}`: "bad_channel",
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
	if len(all) != 6 || all["feedback"]["default"] != true || all["alerts"]["retention_days"] != float64(7) || all["tasks"]["retention_days"] != float64(30) ||
		all["releases"]["name"] != "Releases" || all["tasks"]["last_ts"] != nil {
		t.Fatalf("channels: %+v", all)
	}
	/* §5.2 carries the description back; a default channel and a channel made
	   without one both read "" rather than a missing key */
	if all["releases"]["description"] != "what ships, and when" || all["quiet"]["description"] != "" ||
		all["lobby"]["description"] != "" {
		t.Fatalf("descriptions: %+v", all)
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

// The real box client: SPOOL_CHANNELS reaches the hub in hello, and a post in
// #releases lands in the inbox of EVERY member the box hosts (owner rule
// 2026-09-22), v:1 unchanged. Control: a channel this box did not join
// reaches nobody - the fan-out follows membership, not the body. A default
// channel in SPOOL_CHANNELS joins nothing (owner decision 2026-09-25).
func TestHubclientChannelRecv(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07", "CLE-08")
	b.cfg.Channels = " Tasks , Releases,"
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "releases", Name: "releases", CreatedBy: "wui", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	e.pin(tid, a)
	e.pin(tid, b)
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()
	if m, _ := e.st.ChannelMembers(ctx, tid, "releases"); len(m["box-b"]) != 2 {
		t.Fatalf("SPOOL_CHANNELS not announced: %+v", m)
	}
	if m, _ := e.st.ChannelMembers(ctx, tid, "tasks"); len(m) != 0 {
		t.Fatalf("SPOOL_CHANNELS put agents in #tasks: %+v", m)
	}
	for _, ch := range []string{"releases", "alerts"} { // specs/038: the poster is a member
		if err := e.st.InviteChannelAgent(ctx, tid, ch, "box-a", "GRK-03", time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	plain := chanMsg(uuidV4(), "ALL-0", "note", "nothing for anyone in particular")
	if _, err := cli.Send(ctx, signedIn(t, a, hub.WUIBox, "releases", "", plain)); err != nil {
		t.Fatal(err)
	}
	// CONTROL: #alerts is not one of the channels box-b joined, and this one
	// even mentions CLE-07. It must reach neither inbox - so the assertions
	// below are about membership, not "everything is delivered".
	off := chanMsg(uuidV4(), "ALL-0", "task", "@CLE-07 disk full")
	if _, err := cli.Send(ctx, signedIn(t, a, hub.WUIBox, "alerts", "", off)); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"CLE-07", "CLE-08"} {
		eventually(t, id+" inbox", func() bool { return len(inbox(t, b, id)) == 1 })
		got := inbox(t, b, id)[0]
		if got.MsgID != plain.MsgID || got.To != "ALL-0" || got.Body != plain.Body {
			t.Fatalf("%s inbox copy: %+v", id, got)
		}
	}
	if errs := sb.RecvErrors(); len(errs) != 0 {
		t.Fatalf("recv errors: %v", errs)
	}
}
