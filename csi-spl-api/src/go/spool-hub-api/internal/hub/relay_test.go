package hub_test

import (
	"context"
	"crypto/ed25519"
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
