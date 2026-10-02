package hubclient

// specs/030 FP-2 controls. The point of the submit path is that a box reply
// stops paying a cold dial (220.6 ms p50 measured against the live dev hub,
// 2026-09-21, n=20). The point of THESE tests is that it changed nothing else:
// the same bytes reach the hub, a box without a sidecar behaves exactly as it
// did before 030, and no message is lost, duplicated or mis-answered.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// fakeHub is the smallest hub that can answer this client: challenge, welcome,
// then one `sent` per `send`. It records the RAW envelope bytes of every send,
// which is what the byte-identity control reads.
type fakeHub struct {
	srv *httptest.Server

	mu   sync.Mutex
	envs [][]byte
	// typed is each send frame's typed_by (specs/036 FR-009), "" when absent.
	typed []string
	// refuse, when set, answers every send with this error token instead.
	refuse *wire.Frame
	// reorder, when set, answers each send after a delay that ALTERNATES long,
	// short. It makes the concurrency control deterministic without assuming
	// anything about the client: a correct (serialised) client has one request
	// in flight, so the delay only slows it down and the reply it waits for is
	// the only one coming. A client that writes several at once gets them back
	// in a scrambled order, and since replies are matched by msg_id on ONE
	// shared channel, a waiter that takes someone else's frame discards it and
	// both time out.
	reorder bool
	nsend   int
	wmu     sync.Mutex
}

func newFakeHub(t *testing.T) *fakeHub {
	t.Helper()
	h := &fakeHub{}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := context.Background()
		if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}); err != nil {
			return
		}
		var hello wire.Frame
		if err := wsjson.Read(ctx, conn, &hello); err != nil {
			return
		}
		if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID,
			UploadToken: "tok", UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}); err != nil {
			return
		}
		if hello.Role == wire.RoleBox {
			if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TQueueEnd, Count: 0}); err != nil {
				return
			}
		}
		for {
			var f wire.Frame
			if err := wsjson.Read(ctx, conn, &f); err != nil {
				return
			}
			if f.Type != wire.TSend {
				continue
			}
			h.mu.Lock()
			h.envs = append(h.envs, append([]byte(nil), f.Env...))
			h.typed = append(h.typed, f.TypedBy)
			refuse := h.refuse
			h.mu.Unlock()
			id := wire.InnerMsgID(f.Env)
			out := wire.Frame{Type: wire.TSent, MsgID: id, Delivery: wire.DeliverySent}
			if refuse != nil {
				out = *refuse
				out.MsgID = id
			}
			if d := h.replyDelay(); d > 0 {
				go func(out wire.Frame, d time.Duration) {
					time.Sleep(d)
					h.wmu.Lock()
					defer h.wmu.Unlock()
					wsjson.Write(ctx, conn, out) //nolint:errcheck
				}(out, d)
				continue
			}
			h.wmu.Lock()
			err := wsjson.Write(ctx, conn, out)
			h.wmu.Unlock()
			if err != nil {
				return
			}
		}
	})
	// /v1/pins: the role=box hello syncs pins right after welcome.
	mux.HandleFunc("/v1/pins", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(wire.PinList{Pins: []wire.PinEntry{}}) //nolint:errcheck
	})
	h.srv = httptest.NewServer(mux)
	t.Cleanup(h.srv.Close)
	return h
}

// replyDelay is 0 with reorder off, else alternating long/short so concurrent
// replies come back inverted.
func (h *fakeHub) replyDelay() time.Duration {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.reorder {
		return 0
	}
	h.nsend++
	if h.nsend%2 == 1 {
		return 60 * time.Millisecond
	}
	return 5 * time.Millisecond
}

func (h *fakeHub) typedBy() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.typed...)
}

func (h *fakeHub) sent() [][]byte {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([][]byte(nil), h.envs...)
}

// hubClient is testClient wired to a fake hub, with a submit socket path of its
// own (short: a unix socket path is capped near 100 bytes, and t.TempDir under
// a long test name overruns it).
func hubClient(t *testing.T, h *fakeHub) *Client {
	t.Helper()
	c := testClient(t)
	c.Cfg.HubURL = h.srv.URL
	c.Cfg.Tenant = "t1"
	c.Cfg.SubmitSocket = shortSock(t)
	c.ReadyTimeout = 10 * time.Second
	return c
}

func shortSock(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("", "sub")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return d + "/s"
}

func compose(t *testing.T, c *Client, body string) *msg.Message {
	t.Helper()
	m, err := spool.New(c.Cfg).Compose("GRK-03", "CLE-07", "", "task", body, nil)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// sidecarUp starts a role=box session plus its submit listener, exactly as
// hold() does, and returns a stop func.
func sidecarUp(t *testing.T, c *Client) func() {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	sess, err := c.Dial(ctx, wire.RoleBox)
	if err != nil {
		cancel()
		t.Fatalf("sidecar dial: %v", err)
	}
	srv, err := c.Listen()
	if err != nil {
		cancel()
		t.Fatalf("listen: %v", err)
	}
	go srv.Serve(ctx, sess)
	waitSock(t, c.Cfg.SubmitPath())
	return func() {
		cancel()
		srv.Close()
		sess.Close()
	}
}

func waitSock(t *testing.T, path string) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("submit socket never appeared at %s", path)
}

// FR-006, the control that matters most: a message sent over the submit path
// must reach the hub as the SAME BYTES as one sent over the dial path. If the
// sidecar re-encoded, re-signed or re-stamped anything, the signature would
// still verify on one path and the two envelopes would differ here.
func TestSubmitAndDialSendIdenticalBytes(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)

	// Build ONE envelope and push the same bytes down both paths.
	priv, err := sign.LoadPrivate(c.Cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	m := compose(t, c, "same bytes either way")
	env, err := wire.NewEnvelope(priv, "box-a", "box-b", m)
	if err != nil {
		t.Fatal(err)
	}

	// (a) the dial path: no sidecar listening.
	p1, err := c.writePending(m, env, "")
	if err != nil {
		t.Fatal(err)
	}
	if d, err := c.sendNow(context.Background(), env, m, p1, ""); err != nil || d != wire.DeliverySent {
		t.Fatalf("dial path: delivery=%q err=%v", d, err)
	}

	// (b) the submit path: the sidecar holds the warm session.
	stop := sidecarUp(t, c)
	defer stop()
	p2, err := c.writePending(m, env, "")
	if err != nil {
		t.Fatal(err)
	}
	if d, err := c.sendNow(context.Background(), env, m, p2, ""); err != nil || d != wire.DeliverySent {
		t.Fatalf("submit path: delivery=%q err=%v", d, err)
	}

	got := h.sent()
	if len(got) != 2 {
		t.Fatalf("hub saw %d sends, want 2", len(got))
	}
	if string(got[0]) != string(got[1]) {
		t.Fatalf("the two paths put different bytes on the wire:\n dial:   %s\n submit: %s", got[0], got[1])
	}
}

// A box with no sidecar must behave exactly as it did before 030: the submit
// attempt costs it a refused local connect and it dials.
func TestSendFallsBackWhenNoSidecarListens(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	if _, err := os.Stat(c.Cfg.SubmitPath()); err == nil {
		t.Fatal("no socket should exist yet")
	}
	d, err := c.SendMessage(context.Background(), compose(t, c, "no sidecar here"), "box-b")
	if err != nil || d != wire.DeliverySent {
		t.Fatalf("delivery=%q err=%v", d, err)
	}
	if n := len(h.sent()); n != 1 {
		t.Fatalf("hub saw %d sends, want 1", n)
	}
	left, _ := c.Pending()
	if len(left) != 0 {
		t.Fatalf("pending not settled: %v", left)
	}
}

// The rollback (spec FR-007): SPOOL_SUBMIT_SOCKET=off means the CLI never even
// looks for a listener - even when one is running.
func TestSubmitOffAlwaysDials(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	stop := sidecarUp(t, c)
	defer stop()

	off := *c.Cfg
	off.SubmitSocket = "off"
	cli := New(&off)
	cli.ReadyTimeout = 10 * time.Second
	if p := cli.Cfg.SubmitPath(); p != "" {
		t.Fatalf("SubmitPath with submit off = %q, want empty", p)
	}
	d, err := cli.SendMessage(context.Background(), compose(t, cli, "dial me"), "box-b")
	if err != nil || d != wire.DeliverySent {
		t.Fatalf("delivery=%q err=%v", d, err)
	}
}

// A hub refusal over the submit path must settle the pending file exactly as it
// does over the dial path: a 4xx is permanent, so the envelope moves to
// rejected/ instead of being retried forever.
func TestSubmitRefusalRejectsPendingLikeDial(t *testing.T) {
	h := newFakeHub(t)
	h.mu.Lock()
	h.refuse = &wire.Frame{Type: wire.TError, Error: "bad_sig", Status: http.StatusBadRequest, Detail: "nope"}
	h.mu.Unlock()
	c := hubClient(t, h)
	stop := sidecarUp(t, c)
	defer stop()

	_, err := c.SendMessage(context.Background(), compose(t, c, "refuse me"), "box-b")
	if err == nil {
		t.Fatal("want the hub refusal surfaced to the caller")
	}
	var he *HubError
	if !asHubError(err, &he) || he.Token != "bad_sig" {
		t.Fatalf("want a bad_sig HubError through the socket, got %v", err)
	}
	left, _ := c.Pending()
	if len(left) != 0 {
		t.Fatalf("a permanently refused envelope stayed pending: %v", left)
	}
	envs, _ := filepath.Glob(filepath.Join(c.rejectedDir(), "*.json"))
	if len(envs) != 1 {
		t.Fatalf("rejected/ holds %d envelopes, want 1", len(envs))
	}
	// The move says why (prd 2026-10-02: two rejected/ files with no trace).
	raw, err := os.ReadFile(envs[0] + reasonSuffix)
	if err != nil {
		t.Fatalf("no reason beside the rejected envelope: %v", err)
	}
	var r rejectReason
	if err := json.Unmarshal(raw, &r); err != nil || r.Status != http.StatusBadRequest || r.Token != "bad_sig" || r.Detail != "nope" {
		t.Fatalf("reason = %s (%v), want status 400 token bad_sig detail nope", raw, err)
	}
}

// No message may be lost when the sidecar dies mid-submit: the pending file was
// written before the submit, so the send reports pending and a later flush
// delivers it. The hub dedups on msg_id, so this can never duplicate either.
func TestSubmitLossFreeWhenSidecarDies(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)

	// A listener that accepts and then hangs up without answering.
	srv, err := c.Listen()
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	go func() {
		for {
			conn, err := srv.ln.Accept()
			if err != nil {
				return
			}
			conn.Close()
		}
	}()
	waitSock(t, c.Cfg.SubmitPath())

	d, err := c.SendMessage(context.Background(), compose(t, c, "sidecar dies"), "box-b")
	if err != nil {
		t.Fatalf("a dead sidecar must not fail the send: %v", err)
	}
	if d != wire.DeliveryPending {
		t.Fatalf("delivery=%q, want %q", d, wire.DeliveryPending)
	}
	left, _ := c.Pending()
	if len(left) != 1 {
		t.Fatalf("the envelope must still be pending, got %v", left)
	}
	if n := len(h.sent()); n != 0 {
		t.Fatalf("hub saw %d sends, want 0", n)
	}
}

// Concurrent submits must each get their OWN reply. The Session matches replies
// by msg_id on ONE shared channel and DISCARDS frames that do not match, so two
// requests in flight at once can consume each other's reply and both then wait
// out their deadline.
//
// The hub here answers with ALTERNATING long/short delays, which makes that
// deterministic rather than a race that usually does not happen: measured while
// writing this test, the same 8 concurrent sends against an in-order hub passed
// with the send mutex REMOVED, because a fast loopback hub replies before the
// next request is even written. A control that cannot go red is decoration.
//
// A serialised client is unaffected - one request in flight, one reply coming -
// so this stays a control on the client, not on the hub's timing.
func TestConcurrentSubmitsEachGetTheirOwnReply(t *testing.T) {
	h := newFakeHub(t)
	h.mu.Lock()
	h.reorder = true
	h.mu.Unlock()
	c := hubClient(t, h)
	c.ReadyTimeout = 3 * time.Second // a red run must fail fast, not in 30 s
	stop := sidecarUp(t, c)
	defer stop()

	const n = 6
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			d, err := c.SendMessage(context.Background(), compose(t, c, fmt.Sprintf("concurrent %d", i)), "box-b")
			if err != nil {
				errs <- fmt.Errorf("send %d: %w", i, err)
				return
			}
			if d != wire.DeliverySent {
				errs <- fmt.Errorf("send %d: delivery=%q", i, d)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
	if got := len(h.sent()); got != n {
		t.Fatalf("hub saw %d sends, want %d", got, n)
	}
	// Every msg_id distinct: nothing was sent twice under the mutex.
	seen := map[string]bool{}
	for _, raw := range h.sent() {
		id := wire.InnerMsgID(raw)
		if seen[id] {
			t.Fatalf("msg_id %s reached the hub twice", id)
		}
		seen[id] = true
	}
	left, _ := c.Pending()
	if len(left) != 0 {
		t.Fatalf("pending not settled: %v", left)
	}
}

// A second sidecar on the same box root must not steal the first one's callers.
func TestSecondListenerRefusedWhileFirstServes(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	stop := sidecarUp(t, c)
	defer stop()
	if _, err := c.Listen(); err == nil {
		t.Fatal("a second Listen on a served socket must refuse")
	} else if !strings.Contains(err.Error(), "already listening") {
		t.Fatalf("want an 'already listening' refusal, got %v", err)
	}
}

func asHubError(err error, target **HubError) bool {
	for err != nil {
		if he, ok := err.(*HubError); ok {
			*target = he
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

// specs/030: a box socket that black-holes must END, not hang. The hub has
// pinged since 017 FR-SEC-004; the client never did, so a session the box
// believed was up could stop delivering silently and stay that way until
// something restarted it. Observed on the dev desk 2026-09-21: no session line
// between 16:10:51 and a 16:30:01 restart, no delivery after 16:19, and then
// the hub's whole queue arriving at once - nothing lost, 11 minutes silent.
//
// The hub here completes the hello and then STOPS READING. coder/websocket
// answers pings from its read loop, so a peer that never reads never pongs:
// that is a black hole without needing to drop packets. Without the client
// keepalive this test hangs until its deadline; with it, Done closes.
func TestBoxSessionEndsWhenTheHubStopsAnswering(t *testing.T) {
	mux := http.NewServeMux()
	// A role=box dial syncs pins over REST right after welcome; without this
	// route the dial fails before the socket is ever tested.
	mux.HandleFunc("/v1/pins", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(wire.PinList{Pins: []wire.PinEntry{}}) //nolint:errcheck
	})
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		ctx := context.Background()
		if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}); err != nil {
			return
		}
		var hello wire.Frame
		if err := wsjson.Read(ctx, conn, &hello); err != nil {
			return
		}
		if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID,
			UploadToken: "tok", UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}); err != nil {
			return
		}
		wsjson.Write(ctx, conn, wire.Frame{Type: wire.TQueueEnd, Count: 0}) //nolint:errcheck
		// From here the socket is open and utterly unresponsive: no reads, so
		// no pongs. Hold it until the test is done with it.
		time.Sleep(20 * time.Second)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	c := testClient(t)
	c.Cfg.HubURL = srv.URL
	c.Cfg.Tenant = "t1"
	c.Cfg.SubmitSocket = "off" // this control is about the socket, not submit
	c.ReadyTimeout = 5 * time.Second
	c.KeepAlive = 200 * time.Millisecond
	c.KeepAliveTimeout = 400 * time.Millisecond

	sess, err := c.Dial(context.Background(), wire.RoleBox)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer sess.Close()
	select {
	case <-sess.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("the session never noticed a hub that stopped answering: it would stay silently up, which is the defect")
	}
}

// Keepalive must not end a HEALTHY session: a hub that answers pings keeps its
// box. Without this, "close on any ping trouble" would look identical to the
// fix above while cutting every live socket.
func TestKeepAliveLeavesAHealthySessionAlone(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	c.KeepAlive = 100 * time.Millisecond
	c.KeepAliveTimeout = 2 * time.Second

	sess, err := c.Dial(context.Background(), wire.RoleBox)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer sess.Close()
	select {
	case <-sess.Done():
		t.Fatal("keepalive closed a session whose hub was answering")
	case <-time.After(1500 * time.Millisecond): // ~15 ping rounds
	}
	if _, err := sess.Send(context.Background(), mustEnv(t, c, "still alive")); err != nil {
		t.Fatalf("the session should still carry a send: %v", err)
	}
}

func mustEnv(t *testing.T, c *Client, body string) *wire.Envelope {
	t.Helper()
	priv, err := sign.LoadPrivate(c.Cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	env, err := wire.NewEnvelope(priv, "box-a", "box-b", compose(t, c, body))
	if err != nil {
		t.Fatal(err)
	}
	return env
}
