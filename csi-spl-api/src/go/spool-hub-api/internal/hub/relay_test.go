package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-1004: a person's post must reach the channel's online member agents
// even when the hub process that stored it is not the one holding their box
// socket - the shape of a Cloud Run deploy, where the boxes redial onto the
// new revision and a browser stays on the old one (prd, 2026-09-27 11:52Z:
// boxes on 00093, the poster's browser on 00092).

// relayPeer is a second hub process on the rig's store (the new revision),
// with its own clock offset, and an http client that reaches only it.
type relayPeer struct {
	srv    *hub.Server
	client *http.Client
	skew   atomic.Int64 // ns added to the peer's clock
}

func newRelayPeer(t *testing.T, e *env, key ed25519.PrivateKey) *relayPeer {
	t.Helper()
	p := &relayPeer{}
	o := hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-next",
		Now: func() time.Time { return time.Now().Add(time.Duration(p.skew.Load())) },
	}
	relayOpts(key)(&o)
	srv, err := hub.New(o)
	if err != nil {
		t.Fatal(err)
	}
	p.srv = srv
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() { srv.Shutdown(); ts.Close() })
	addr := ts.Listener.Addr().String()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	p.client = &http.Client{Transport: tr}
	return p
}

// relayOpts is fallbackEnv's option set with the fallback on.
func relayOpts(key ed25519.PrivateKey) func(*hub.Options) {
	return func(o *hub.Options) {
		fallbackOpts(o, key, true)
	}
}

// relayRig: box-wui pinned, two people in #development (the opener, and the
// one who answers), box-desk seated on the PEER process only.
type relayRig struct {
	e       *env
	peer    *relayPeer
	tid     string
	opener  string
	replier string
	desk    *box
}

func newRelayRig(t *testing.T, deskAgents ...string) *relayRig {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	e := fallbackEnv(t, key, true)
	tid, _ := e.tenant()
	e.pinKey(tid, hub.WUIBox, pub)
	ctx := context.Background()
	r := &relayRig{e: e, tid: tid, opener: "HUM-google-sub-10@" + tid, replier: "HUM-google-sub-27@" + tid}
	now := time.Now()
	for _, ch := range []string{"development", "mobile"} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch,
			Name: ch, CreatedBy: r.opener, CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := e.st.AddChannelHumans(ctx, tid, ch, []string{r.opener, r.replier}, r.opener, now); err != nil {
			t.Fatal(err)
		}
	}
	r.desk = e.box(tid, "box-desk", deskAgents...)
	e.pin(tid, r.desk)
	r.peer = newRelayPeer(t, e, key)
	r.desk.c.HTTP = r.peer.client
	s, err := r.desk.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return r
}

// openTo sends a new topic addressed to one person, as the 11:37:10 opening.
func openTo(t *testing.T, r *relayRig, as, id, task, channel, to, body string) {
	t.Helper()
	c := dialMember(t, r.e, r.tid, "Owner", as)
	wsjson.Write(context.Background(), c, map[string]any{"type": "send", "msg_id": id, "task_id": task, //nolint:errcheck
		"kind": "note", "to": to, "channel": channel, "body": body, "is_parent": 1})
	if ack := readType(t, c, "ack"); ack["type"] != "ack" {
		t.Fatalf("open %s: %v", id, ack)
	}
}

func notWithin(t *testing.T, d time.Duration, what string, ok func() bool) {
	t.Helper()
	for deadline := time.Now().Add(d); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if ok() {
			t.Fatalf("%s happened without the relay", what)
		}
	}
}

// The csi-rel rows of 2026-09-27: HUM-10 opens a #development topic TO a
// person (HUM-27), HUM-27 answers ALL-0 from the reply pane (is_parent 0, no
// channel tag). The member agent's box sits on the other process. Without a
// relay the answer stays queued (the control); one relay tick of the process
// that holds the box delivers it - the opening's addressee does not matter.
func TestRelayDeliversReplyStoredOnAnotherProcess(t *testing.T) {
	r := newRelayRig(t, "CLE-35036")
	ctx := context.Background()
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/channels/development/agents", r.opener,
		map[string]string{"id": "CLE-35036", "box": "box-desk"}); code != http.StatusCreated {
		t.Fatalf("invite: %d %v", code, out)
	}
	task := "51f638f3-1d92-49a3-9f79-4418f5546f2a"
	open, reply := "96306d8c-b1d2-4ca7-baf3-16b90d63f15a", "bcfa2fff-2eed-4384-8a54-aeede1b5fa1b"
	openTo(t, r, r.opener, open, task, "development", "HUM-27", "please check the release")
	threadFrame(t, dialMember(t, r.e, r.tid, "Kristina", r.replier), reply, task, "", 0, "done - over to the agents")

	got := func() bool { return slices.Contains(inboxIDs(t, r.desk, "CLE-35036"), reply) }
	notWithin(t, 400*time.Millisecond, "the reply reached CLE-35036", got) // CONTROL
	if st, _ := r.e.st.DeliveryState(ctx, r.tid, reply, "box-desk"); st != store.StateQueued {
		t.Fatalf("the reply's box-desk row is %q before the relay, want queued", st)
	}
	r.peer.srv.Relay(ctx)
	eventually(t, "CLE-35036 got the reply after one relay tick", got)
	eventually(t, "the box-desk row is sent", func() bool {
		st, _ := r.e.st.DeliveryState(ctx, r.tid, reply, "box-desk")
		return st == store.StateSent
	})
	if !slices.Contains(inboxIDs(t, r.desk, "CLE-35036"), open) {
		t.Fatal("the opening (to a person) did not reach the member agent either")
	}
	// A second tick sends nothing twice.
	r.peer.srv.Relay(ctx)
	time.Sleep(100 * time.Millisecond)
	if n := strings.Count(strings.Join(inboxIDs(t, r.desk, "CLE-35036"), ","), reply); n != 1 {
		t.Fatalf("the reply is in the inbox %d times", n)
	}
}

// No member agent of the channel is online anywhere, and the only box that
// could take a fallback sits on the other process: the process that stored
// the post saw no box and handed it to nobody (the control). The peer's
// sweep, once the post is older than the grace, hands it to the responder -
// once, however many ticks run.
func TestRelaySweepFallsBackAcrossProcesses(t *testing.T) {
	r := newRelayRig(t, "CLE-001", "CLE-35")
	ctx := context.Background()
	if err := r.e.st.(store.Fallbacks).SetTenantResponders(ctx, r.tid, []string{"CLE-001"}); err != nil {
		t.Fatal(err)
	}
	m1 := "5ec59cd6-5b3b-42cf-99c5-b2fbf34a44fa"
	threadFrame(t, dialMember(t, r.e, r.tid, "Kristina", r.replier), m1, "1a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d",
		"mobile", 1, "is anyone there?")
	got := func() bool { return slices.Contains(inboxIDs(t, r.desk, "CLE-001"), m1) }
	notWithin(t, 300*time.Millisecond, "the fallback", got) // CONTROL
	r.peer.srv.Relay(ctx)                                   // inside the grace: still nobody
	notWithin(t, 200*time.Millisecond, "a fallback inside the grace", got)

	r.peer.skew.Store(int64(20 * time.Second))
	r.peer.srv.Relay(ctx)
	eventually(t, "CLE-001 got the fallback", got)
	r.peer.srv.Relay(ctx)
	time.Sleep(100 * time.Millisecond)
	if n := len(inbox(t, r.desk, "CLE-001")); n != 1 {
		t.Fatalf("CLE-001 inbox %d, want 1", n)
	}
	if n := len(inbox(t, r.desk, "CLE-35")); n != 0 {
		t.Fatalf("CLE-35 is not the responder, reads %d", n)
	}
	if n := fallbackCount(t, &fallbackRig{e: r.e, tid: r.tid}, "mobile"); n != 1 {
		t.Fatalf("fallback records %d, want 1", n)
	}
}

// P5-03: the unanswered sweep runs at a quarter of UnansweredGrace, not every
// tick. A sweep that ran just before the post crossed the grace holds the next
// one off for grace/4 (CONTROL: before P5-03 the tick right after the grace
// escalated), and the escalation still comes within grace + grace/4.
func TestRelayEscalatesAtAQuarterOfTheGrace(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	const grace = 8 * time.Second // the cadence is 2 s
	var clock atomic.Int64
	e := newEnv(t, func(o *hub.Options) {
		fallbackOpts(o, key, true)
		o.UnansweredGrace = grace
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
	defer closeWait(sd)
	// an ONLINE member agent keeps the immediate fallback off, so only the
	// unanswered sweep can reach the responder.
	human := "HUM-google-sub-1@" + tid
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "staffed",
		Name: "staffed", CreatedBy: human, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "staffed", []string{human}, human, time.Now()); err != nil {
		t.Fatal(err)
	}
	b := e.box(tid, "box-b", "GRK-36")
	e.pin(tid, b)
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sb)
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/staffed/agents", human,
		map[string]string{"id": "GRK-36", "box": "box-b"}); code != http.StatusCreated {
		t.Fatalf("invite: %d %v", code, out)
	}
	ws := dialMember(t, e, tid, "Owner", human)
	m1, task := "7d1e2f3a-4b5c-4d6e-8f70-8192a3b4c5d6", "8e2f3a4b-5c6d-4e7f-8091-a2b3c4d5e6f7"
	threadFrame(t, ws, m1, task, "staffed", 1, "please pick this up")
	eventually(t, "GRK-36 got it the ordinary way", func() bool { return strings.Join(inboxIDs(t, b, "GRK-36"), ",") == m1 })
	got := func() bool { return slices.Contains(inboxIDs(t, desk, "CLE-001"), m1) }

	clock.Store(int64(grace - time.Second)) // a sweep inside the grace: nothing
	e.srv.Relay(ctx)
	notWithin(t, 200*time.Millisecond, "an escalation inside the grace", got)
	clock.Store(int64(grace + 500*time.Millisecond)) // past the grace, 1.5 s after that sweep
	e.srv.Relay(ctx)
	notWithin(t, 300*time.Millisecond, "an escalation inside the cadence", got)
	clock.Store(int64(grace + grace/4 - time.Second + 100*time.Millisecond)) // the cadence is up
	e.srv.Relay(ctx)
	eventually(t, "CLE-001 got the escalation within grace + grace/4", got)
}

// P5-03: an unacked row goes out again at a quarter of the acquisition lock
// (ackTimeout 60 s: every 15 s), not every tick. CONTROL: before P5-03 the
// first tick past the lock re-pushed it.
func TestRelayRepushesUnackedAtAQuarterOfTheLock(t *testing.T) {
	var skew atomic.Int64
	e := newEnv(t, func(o *hub.Options) {
		o.Now = func() time.Time { return time.Now().Add(time.Duration(skew.Load())) }
	})
	tid, _ := e.tenant()
	s := e.box(tid, "box-s", "GRK-03")
	c := e.box(tid, "box-c", "CLE-13")
	e.pin(tid, s)
	e.pin(tid, c)
	raw := e.commitBox(tid, c, "CLE-13", true)
	send(t, s, "GRK-03", "CLE-13", "note", "dropped", "box-c")
	recvMsgID(t, raw.next(wire.TRecv)) // never committed
	nextBody := func() string {
		id, body := recvMsgID(t, raw.next(wire.TRecv))
		wsjson.Write(context.Background(), raw.c, wire.Frame{Type: wire.TCommit, MsgID: id}) //nolint:errcheck
		return body
	}
	skew.Store(int64(50 * time.Second))
	e.srv.Relay(context.Background()) // the unacked sweep runs, inside the lock
	skew.Store(int64(61 * time.Second))
	e.srv.Relay(context.Background()) // past the lock, 11 s after that sweep: not yet
	send(t, s, "GRK-03", "CLE-13", "note", "sentinel", "box-c")
	if b := nextBody(); b != "sentinel" {
		t.Fatalf("got %q 11 s after the last unacked sweep, want the sentinel", b)
	}
	time.Sleep(100 * time.Millisecond)
	skew.Store(int64(66 * time.Second))
	e.srv.Relay(context.Background())
	if b := nextBody(); b != "dropped" {
		t.Fatalf("re-pushed %q at the cadence, want the uncommitted one", b)
	}
}

// flakyStore is the memory store with every relay-loop read failing while
// down is set: a Cloud SQL restart as the relay tick sees it.
type flakyStore struct {
	*store.Memory
	down atomic.Bool
}

var errDBDown = errors.New("dial tcp 10.0.0.3:5432: connect: connection refused")

func (f *flakyStore) QueuedFor(ctx context.Context, tenant, box string, now time.Time) ([]store.Queued, error) {
	if f.down.Load() {
		return nil, errDBDown
	}
	return f.Memory.QueuedFor(ctx, tenant, box, now)
}

func (f *flakyStore) UnheardPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]store.Queued, error) {
	if f.down.Load() {
		return nil, errDBDown
	}
	return f.Memory.UnheardPosts(ctx, tenant, since, until, limit)
}

func (f *flakyStore) UnansweredPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]store.Queued, error) {
	if f.down.Load() {
		return nil, errDBDown
	}
	return f.Memory.UnansweredPosts(ctx, tenant, since, until, limit)
}

func (f *flakyStore) ReescalatablePosts(ctx context.Context, tenant string, since, escalatedBefore, until time.Time, maxAttempts, limit int) ([]store.Queued, error) {
	if f.down.Load() {
		return nil, errDBDown
	}
	return f.Memory.ReescalatablePosts(ctx, tenant, since, escalatedBefore, until, maxAttempts, limit)
}

func (f *flakyStore) UnackedFor(ctx context.Context, tenant, box string, now, sentBefore time.Time) ([]store.Queued, error) {
	if f.down.Load() {
		return nil, errDBDown
	}
	return f.Memory.UnackedFor(ctx, tenant, box, now, sentBefore)
}

func (f *flakyStore) NackedPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]store.Queued, error) {
	if f.down.Load() {
		return nil, errDBDown
	}
	return f.Memory.NackedPosts(ctx, tenant, since, until, limit)
}

// relayLoopSites is every relay-loop call that logs a failing store read.
var relayLoopSites = []string{"relay queue", "unacked rows", "relay unheard posts",
	"relay unanswered posts", "relay reescalatable posts", "relay nacked posts"}

// flakyRelay is one hub on a flakyStore, its log in a buffer, one committing
// box seated (so every relay sweep has a tenant and a box to read), and a
// tick that moves the hub clock by step and runs one relay tick.
type flakyRelay struct {
	st   *flakyStore
	log  *syncWriter
	tick func(n int, step time.Duration)
}

func newFlakyRelay(t *testing.T) *flakyRelay {
	t.Helper()
	_, key, _ := ed25519.GenerateKey(nil)
	f := &flakyRelay{st: &flakyStore{Memory: store.NewMemory()}, log: &syncWriter{w: &bytes.Buffer{}}}
	var clock atomic.Int64
	e := newEnv(t, func(o *hub.Options) {
		fallbackOpts(o, key, true)
		o.Store, o.Log = f.st, zerolog.New(f.log)
		o.UnansweredGrace, o.ReescalateEvery, o.ReescalateMax = 8*time.Second, 8*time.Second, 3
		o.Now = func() time.Time { return time.Now().Add(time.Duration(clock.Load())) }
	})
	e.st = f.st
	tid, _ := e.tenant()
	b := e.box(tid, "box-c", "CLE-13")
	e.pin(tid, b)
	e.commitBox(tid, b, "CLE-13", true)
	f.tick = func(n int, step time.Duration) {
		for range n {
			clock.Add(int64(step))
			e.srv.Relay(context.Background())
		}
	}
	return f
}

// levels counts the log lines of each relay-loop site by level.
func (f *flakyRelay) levels(t *testing.T) map[string]map[string]int {
	t.Helper()
	f.log.mu.Lock()
	defer f.log.mu.Unlock()
	out := map[string]map[string]int{}
	for _, line := range strings.Split(strings.TrimSpace(f.log.w.String()), "\n") {
		var l struct {
			Level     string `json:"level"`
			Message   string `json:"message"`
			Recovered bool   `json:"recovered"`
		}
		if json.Unmarshal([]byte(line), &l) != nil || !slices.Contains(relayLoopSites, l.Message) {
			continue
		}
		if out[l.Message] == nil {
			out[l.Message] = map[string]int{}
		}
		if l.Level == "info" && !l.Recovered {
			continue
		}
		out[l.Message][l.Level]++
	}
	return out
}

// SPL-3194 (alerts fix round row 02): a DB restart of a minute is 12 relay
// ticks; each failing site logs ERROR once, then WARN. CONTROL: before the
// fix every site logged ERROR on every tick it ran (12, the unacked sweep 4),
// so the error_logs policy (> 9 in 5 min) paged a planned apply.
func TestRelayLoopFailingStoreLogsErrorOnce(t *testing.T) {
	f := newFlakyRelay(t)
	f.st.down.Store(true)
	f.tick(12, 5*time.Second)
	got := f.levels(t)
	for _, site := range relayLoopSites {
		if n := got[site]["error"]; n != 1 {
			t.Errorf("%q: %d ERROR lines in 12 failing ticks, want 1 (%v)", site, n, got[site])
		}
		if got[site]["warn"] == 0 {
			t.Errorf("%q: no WARN line for the repeats (%v)", site, got[site])
		}
	}
}

// The recovery: a store that fails one tick and then works logs one ERROR and
// one INFO (recovered) per site, and a second outage is an ERROR again.
func TestRelayLoopRecoveryLogsInfoOnce(t *testing.T) {
	f := newFlakyRelay(t)
	f.st.down.Store(true)
	f.tick(1, 16*time.Second)
	f.st.down.Store(false)
	f.tick(3, 16*time.Second)
	got := f.levels(t)
	for _, site := range relayLoopSites {
		if got[site]["error"] != 1 || got[site]["info"] != 1 || got[site]["warn"] != 0 {
			t.Errorf("%q: %v, want 1 error and 1 recovered info", site, got[site])
		}
	}
	f.st.down.Store(true)
	f.tick(1, 16*time.Second)
	if n := f.levels(t)["relay queue"]["error"]; n != 2 {
		t.Errorf("a second outage logged %d ERROR lines in all, want 2", n)
	}
}
