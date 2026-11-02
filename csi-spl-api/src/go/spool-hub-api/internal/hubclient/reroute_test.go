package hubclient

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 169 T7b: the box client's answer to a topic_moved refusal, on every send
// path. SRC refuses as T7 does (internal/hub/channel_move.go); the desk answers
// as its reply says. Each hub is a scripted one, so a count of its frames is
// the proof of what was and was not sent.

const (
	movedDst  = "t2"
	movedLink = "https://t2.example.com/t/abc"
)

func hubRefuses(status int, token, detail string) func(wire.Frame) []wire.Frame {
	return func(f wire.Frame) []wire.Frame {
		if f.Type != wire.TSend {
			return opsReply(f)
		}
		return []wire.Frame{{Type: wire.TError, MsgID: wire.InnerMsgID(f.Env), Error: token, Status: status, Detail: detail}}
	}
}

func hubTakes(f wire.Frame) []wire.Frame {
	if f.Type != wire.TSend {
		return opsReply(f)
	}
	return []wire.Frame{{Type: wire.TSent, MsgID: wire.InnerMsgID(f.Env), Delivery: wire.DeliverySent}}
}

func liveMoved() func(wire.Frame) []wire.Frame {
	return hubRefuses(http.StatusConflict, wire.TokenTopicMoved, wire.MovedDetail(movedDst, movedLink))
}

func (h *opsHub) sends() []wire.Frame {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []wire.Frame
	for _, f := range h.got {
		if f.Type == wire.TSend {
			out = append(out, f)
		}
	}
	return out
}

// deskOf is one desk: its own root, key and hub, seated for c-007.
func deskOf(t *testing.T, tenant string, reply func(wire.Frame) []wire.Frame) (*config.Config, *opsHub) {
	t.Helper()
	h := &opsHub{reply: reply}
	root := t.TempDir()
	cfg := &config.Config{SpoolRoot: filepath.Join(root, "spool"), KeysDir: filepath.Join(root, "keys"),
		PinsDir: filepath.Join(root, "spool", "pins"), BoxID: "box-a", Tenant: tenant, SubmitSocket: "off", HubURL: h.start(t)}
	if _, err := sign.GenerateKey(cfg.KeysDir, cfg.BoxID, false); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(cfg.SpoolRoot, "c-007", "inbox"), 0o775); err != nil {
		t.Fatal(err)
	}
	return cfg, h
}

type moveFix struct {
	src    *Client
	srcHub *opsHub
	desk   *config.Config
	dstHub *opsHub
}

func newMoveFix(t *testing.T, srcReply func(wire.Frame) []wire.Frame) *moveFix {
	t.Helper()
	srcHub := &opsHub{reply: srcReply}
	src := opsClient(t, srcHub)
	desk, dstHub := deskOf(t, movedDst, hubTakes)
	src.MovedDesk = func(tenant string) (*config.Config, error) {
		if tenant != movedDst {
			return nil, fmt.Errorf("no desk in %s", tenant)
		}
		return desk, nil
	}
	return &moveFix{src: src, srcHub: srcHub, desk: desk, dstHub: dstHub}
}

func (x *moveFix) post(t *testing.T, to string) *msg.Message {
	t.Helper()
	m, err := spool.New(x.src.Cfg).Compose("c-007", to, "", "note", "into the moved topic", nil)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// queue writes m pending, as a post queued before the move.
func queue(t *testing.T, c *Client, m *msg.Message, toBox string, cl Claims) string {
	t.Helper()
	own, priv, err := c.box()
	if err != nil {
		t.Fatal(err)
	}
	env, err := wire.NewEnvelope(priv, own, toBox, m)
	if err != nil {
		t.Fatal(err)
	}
	p, err := c.writePending(m, env, cl)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func flushOnce(t *testing.T, c *Client) (int, error) {
	t.Helper()
	s, err := c.Dial(context.Background(), wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	return s.Flush(context.Background())
}

func count(t *testing.T, dir string) int {
	t.Helper()
	l, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	return len(l)
}

// told is the reject bodies in c-007's inbox on cfg's root.
func told(t *testing.T, cfg *config.Config) string {
	t.Helper()
	l, err := filepath.Glob(filepath.Join(cfg.SpoolRoot, "c-007", "inbox", "*"))
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	for _, p := range l {
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(raw)
	}
	return b.String()
}

// assertRefused: nothing reached the desk, the post is in rejected/ with the
// token as its reason, and the agent and the caller both have token and words.
func assertRefused(t *testing.T, x *moveFix, err error, wants ...string) {
	t.Helper()
	var he *HubError
	if !errors.As(err, &he) || he.Token != wire.TokenTopicMoved {
		t.Fatalf("the caller's error = %v, want the topic_moved refusal", err)
	}
	if n := len(x.dstHub.sends()); n != 0 {
		t.Errorf("the desk's hub got %d sends, want 0", n)
	}
	if n := count(t, x.src.pendingDir()); n != 0 {
		t.Errorf("%d still pending", n)
	}
	if n := count(t, x.src.rejectedDir()); n != 1 {
		t.Errorf("%d in rejected/, want 1", n)
	}
	body := told(t, x.src.Cfg)
	for _, w := range append([]string{wire.TokenTopicMoved}, wants...) {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("the caller's error lacks %q: %v", w, err)
		}
		if !strings.Contains(body, w) {
			t.Errorf("the agent's inbox lacks %q: %s", w, body)
		}
	}
}

// Every send path: refused live, sent once through the desk, same ids, signed
// with the desk's key. CONTROL: <SRC> saw the post first, once.
func TestMovedRerouteEveryPath(t *testing.T) {
	ctx := context.Background()
	paths := []struct {
		name    string
		to      string
		channel string
		run     func(t *testing.T, x *moveFix, m *msg.Message) (string, error)
	}{
		{"send dial", "HUM-3", "", func(t *testing.T, x *moveFix, m *msg.Message) (string, error) {
			return x.src.SendMessageClaims(ctx, m, wuiBox, Claims{})
		}},
		{"send sidecar", "HUM-3", "", func(t *testing.T, x *moveFix, m *msg.Message) (string, error) {
			x.src.Cfg.SubmitSocket = shortSock(t)
			t.Cleanup(sidecarUp(t, x.src))
			return x.src.SendMessageClaims(ctx, m, wuiBox, Claims{})
		}},
		{"channel", "ALL-0", "ops", func(t *testing.T, x *moveFix, m *msg.Message) (string, error) {
			return x.src.SendChannelClaims(ctx, m, "ops", Claims{})
		}},
		{"answer", "HUM-3", "", func(t *testing.T, x *moveFix, m *msg.Message) (string, error) {
			return x.src.SendAnswerMessage(ctx, m, wuiBox, "q-msg", 4)
		}},
		{"queued, flushed after the move", "HUM-3", "", func(t *testing.T, x *moveFix, m *msg.Message) (string, error) {
			queue(t, x.src, m, wuiBox, Claims{})
			n, err := flushOnce(t, x.src)
			if n != 1 {
				t.Errorf("flushed %d, want 1", n)
			}
			return wire.DeliverySent, err
		}},
	}
	for _, p := range paths {
		t.Run(p.name, func(t *testing.T) {
			x := newMoveFix(t, liveMoved())
			m := x.post(t, p.to)
			d, err := p.run(t, x, m)
			if err != nil || d != wire.DeliverySent {
				t.Fatalf("delivery %q err %v", d, err)
			}
			if n := len(x.srcHub.sends()); n != 1 {
				t.Errorf("<SRC> got %d sends, want 1", n)
			}
			sends := x.dstHub.sends()
			if len(sends) != 1 {
				t.Fatalf("the desk's hub got %d sends, want 1", len(sends))
			}
			e, err := wire.ParseEnvelope(sends[0].Env)
			if err != nil {
				t.Fatal(err)
			}
			in, err := e.Inner()
			if err != nil {
				t.Fatal(err)
			}
			if in.MsgID != m.MsgID || in.TaskID != m.TaskID {
				t.Errorf("ids changed: %s %s, want %s %s", in.MsgID, in.TaskID, m.MsgID, m.TaskID)
			}
			if e.Channel != p.channel {
				t.Errorf("channel tag %q, want %q", e.Channel, p.channel)
			}
			priv, err := sign.LoadPrivate(x.desk.KeysDir, x.desk.BoxID)
			if err != nil {
				t.Fatal(err)
			}
			if err := e.Verify(priv.Public().(ed25519.PublicKey)); err != nil {
				t.Errorf("not signed with the desk's key: %v", err)
			}
			for _, c := range []*Client{x.src, New(x.desk)} {
				if n := count(t, c.pendingDir()) + count(t, c.rejectedDir()); n != 0 {
					t.Errorf("%s: %d left in pending/ or rejected/", c.Cfg.TenantID(), n)
				}
			}
			if body := told(t, x.src.Cfg); body != "" {
				t.Errorf("a re-routed post told the agent of a refusal: %s", body)
			}
		})
	}
}

// No desk for that tenant on this box: NOT sent, both told, no other key tried.
func TestMovedNoDeskRefused(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name string
		arm  func(x *moveFix)
		want string
	}{
		{"no resolver", func(x *moveFix) { x.src.MovedDesk = nil }, "no desk of c-007 in " + movedDst},
		{"no desk in that tenant", func(x *moveFix) {
			x.src.MovedDesk = func(string) (*config.Config, error) { return nil, errors.New("none here") }
		}, "none here"},
		{"another tenant's desk is never used", func(x *moveFix) { x.desk.Tenant = "t9" }, "the desk found is in"},
		{"a desk with no seat for the agent", func(x *moveFix) {
			if err := os.RemoveAll(filepath.Join(x.desk.SpoolRoot, "c-007")); err != nil {
				panic(err)
			}
		}, "no seat for it"},
		{"a desk whose key is gone", func(x *moveFix) {
			if err := os.RemoveAll(x.desk.KeysDir); err != nil {
				panic(err)
			}
		}, "its key does not load"},
	}
	for _, tc := range cases {
		t.Run(tc.name+", live send", func(t *testing.T) {
			x := newMoveFix(t, liveMoved())
			tc.arm(x)
			_, err := x.src.SendMessageClaims(ctx, x.post(t, "HUM-3"), wuiBox, Claims{})
			assertRefused(t, x, err, movedDst, movedLink, tc.want)
		})
		t.Run(tc.name+", queued", func(t *testing.T) {
			x := newMoveFix(t, liveMoved())
			tc.arm(x)
			queue(t, x.src, x.post(t, "HUM-3"), wuiBox, Claims{})
			_, err := flushOnce(t, x.src)
			assertRefused(t, x, err, movedDst, movedLink, tc.want)
		})
	}
	t.Run("the answer path", func(t *testing.T) {
		x := newMoveFix(t, liveMoved())
		x.src.MovedDesk = nil
		_, err := x.src.SendAnswerMessage(ctx, x.post(t, "HUM-3"), wuiBox, "q-msg", 4)
		var he *HubError
		if !errors.As(err, &he) || he.Token != wire.TokenTopicMoved || len(x.dstHub.sends()) != 0 {
			t.Fatalf("got %v, %d sends", err, len(x.dstHub.sends()))
		}
		if !strings.Contains(told(t, x.src.Cfg), movedDst) {
			t.Error("the agent was not told")
		}
	})
}

// An expired redirect (404, no destination) and a detail ParseMovedDetail
// refuses: no re-route, reported, never silent. CONTROL: the same fixture
// re-routes on a live refusal (TestMovedRerouteEveryPath).
func TestMovedNoDestinationRefused(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name  string
		reply func(wire.Frame) []wire.Frame
	}{
		{"expired 404", hubRefuses(http.StatusNotFound, wire.TokenTopicMoved, "this topic is gone from this workspace")},
		{"a 409 whose detail does not parse", hubRefuses(http.StatusConflict, wire.TokenTopicMoved, "topic moved somewhere")},
		{"a 409 with an empty tenant", hubRefuses(http.StatusConflict, wire.TokenTopicMoved, wire.MovedDetail("", movedLink))},
		{"a 404 that names a tenant", hubRefuses(http.StatusNotFound, wire.TokenTopicMoved, wire.MovedDetail(movedDst, movedLink))},
	}
	for _, tc := range cases {
		t.Run(tc.name+", live send", func(t *testing.T) {
			x := newMoveFix(t, tc.reply)
			_, err := x.src.SendMessageClaims(ctx, x.post(t, "HUM-3"), wuiBox, Claims{})
			assertRefused(t, x, err, "names no destination")
		})
		t.Run(tc.name+", queued", func(t *testing.T) {
			x := newMoveFix(t, tc.reply)
			queue(t, x.src, x.post(t, "HUM-3"), wuiBox, Claims{})
			_, err := flushOnce(t, x.src)
			assertRefused(t, x, err, "names no destination")
			raw, rerr := os.ReadFile(firstRejected(t, x.src) + reasonSuffix)
			if rerr != nil || !strings.Contains(string(raw), wire.TokenTopicMoved) {
				t.Errorf("reason beside the rejected post: %s (%v)", raw, rerr)
			}
		})
	}
}

func firstRejected(t *testing.T, c *Client) string {
	t.Helper()
	l, err := filepath.Glob(filepath.Join(c.rejectedDir(), "*.json"))
	if err != nil || len(l) == 0 {
		t.Fatalf("rejected/: %v %v", l, err)
	}
	return l[0]
}

// A failed read (503) stays retryable: nothing re-routed, nothing rejected, the
// post still pending on every path that queues, and the next flush sends it.
func TestMovedCheckFailedStaysRetryable(t *testing.T) {
	ctx := context.Background()
	const token = "moved_check_failed"
	failing := hubRefuses(http.StatusServiceUnavailable, token, "the topic could not be checked; try again")
	check := func(t *testing.T, x *moveFix) {
		t.Helper()
		if n := len(x.dstHub.sends()); n != 0 {
			t.Errorf("re-routed on a 503: %d sends", n)
		}
		if n := count(t, x.src.rejectedDir()); n != 0 {
			t.Errorf("%d in rejected/", n)
		}
		if n := count(t, x.src.pendingDir()); n != 1 {
			t.Errorf("%d pending, want 1", n)
		}
	}
	t.Run("dial", func(t *testing.T) {
		x := newMoveFix(t, failing)
		d, err := x.src.SendMessageClaims(ctx, x.post(t, "HUM-3"), wuiBox, Claims{})
		if err != nil || d != wire.DeliveryPending {
			t.Fatalf("delivery %q err %v", d, err)
		}
		check(t, x)
	})
	t.Run("sidecar", func(t *testing.T) {
		x := newMoveFix(t, failing)
		x.src.Cfg.SubmitSocket = shortSock(t)
		t.Cleanup(sidecarUp(t, x.src))
		d, err := x.src.SendMessageClaims(ctx, x.post(t, "HUM-3"), wuiBox, Claims{})
		if err != nil || d != wire.DeliveryPending {
			t.Fatalf("delivery %q err %v", d, err)
		}
		check(t, x)
	})
	t.Run("queued, then the read works", func(t *testing.T) {
		x := newMoveFix(t, failing)
		queue(t, x.src, x.post(t, "HUM-3"), wuiBox, Claims{})
		if _, err := flushOnce(t, x.src); !errors.Is(err, ErrUnreachable) {
			t.Fatalf("flush: %v", err)
		}
		check(t, x)
		x.srcHub.mu.Lock()
		x.srcHub.reply = liveMoved()
		x.srcHub.mu.Unlock()
		if n, err := flushOnce(t, x.src); n != 1 || err != nil {
			t.Fatalf("second flush: %d %v", n, err)
		}
		if n := len(x.dstHub.sends()); n != 1 {
			t.Errorf("after the read works: %d sends", n)
		}
	})
	t.Run("an answer is never queued", func(t *testing.T) {
		x := newMoveFix(t, failing)
		_, err := x.src.SendAnswerMessage(ctx, x.post(t, "HUM-3"), wuiBox, "q-msg", 4)
		var he *HubError
		if !errors.As(err, &he) || he.Token != token {
			t.Fatalf("got %v", err)
		}
		if n := count(t, x.src.pendingDir()); n != 0 {
			t.Errorf("%d pending", n)
		}
	})
}

// A second topic_moved from <DST> stops at one hop: no third workspace is ever
// asked, the post ends in the desk's rejected/ and both roots tell the agent.
func TestMovedSecondHopStops(t *testing.T) {
	ctx := context.Background()
	third, thirdHub := deskOf(t, "t3", hubTakes)
	second := hubRefuses(http.StatusConflict, wire.TokenTopicMoved, wire.MovedDetail("t3", "https://t3.example.com/t/abc"))
	toThird := func(tenant string) (*config.Config, error) {
		if tenant != "t3" {
			return nil, fmt.Errorf("no desk in %s", tenant)
		}
		return third, nil
	}

	t.Run("live send", func(t *testing.T) {
		x := newMoveFix(t, liveMoved())
		x.dstHub.reply = second
		x.src.MovedDesk = func(tenant string) (*config.Config, error) {
			if tenant == movedDst {
				return x.desk, nil
			}
			return toThird(tenant)
		}
		_, err := x.src.SendMessageClaims(ctx, x.post(t, "HUM-3"), wuiBox, Claims{})
		var he *HubError
		if !errors.As(err, &he) || he.Token != wire.TokenTopicMoved || !strings.Contains(err.Error(), "one hop only") {
			t.Fatalf("got %v", err)
		}
		if a, b := len(x.dstHub.sends()), len(thirdHub.sends()); a != 1 || b != 0 {
			t.Errorf("sends: <DST> %d, third %d, want 1 and 0", a, b)
		}
		dc := New(x.desk)
		if n := count(t, dc.rejectedDir()); n != 1 {
			t.Errorf("the desk's rejected/ holds %d", n)
		}
		for _, cfg := range []*config.Config{x.src.Cfg, x.desk} {
			if body := told(t, cfg); !strings.Contains(body, "one hop only") || !strings.Contains(body, "t3") {
				t.Errorf("%s was not told: %s", cfg.TenantID(), body)
			}
		}
	})

	// The desk's own sidecar flushes the re-routed post later, and it DOES
	// resolve desks: only the claim beside the envelope stops the hop.
	t.Run("queued on the desk, its sidecar resolves desks", func(t *testing.T) {
		x := newMoveFix(t, liveMoved())
		x.dstHub.reply = second
		dc := New(x.desk)
		dc.MovedDesk = toThird
		m := x.post(t, "HUM-3")
		queue(t, dc, m, wuiBox, Claims{Rerouted: "t1"})
		if _, err := flushOnce(t, dc); err == nil || !strings.Contains(err.Error(), "one hop only") {
			t.Fatalf("flush: %v", err)
		}
		if n := len(thirdHub.sends()); n != 0 {
			t.Errorf("the third workspace got %d sends", n)
		}
	})

	t.Run("control, a first refusal on that sidecar does re-route", func(t *testing.T) {
		x := newMoveFix(t, liveMoved())
		x.dstHub.reply = second
		dc := New(x.desk)
		dc.MovedDesk = toThird
		before := len(thirdHub.sends())
		queue(t, dc, x.post(t, "HUM-3"), wuiBox, Claims{})
		if _, err := flushOnce(t, dc); err != nil {
			t.Fatalf("flush: %v", err)
		}
		if n := len(thirdHub.sends()) - before; n != 1 {
			t.Errorf("the third workspace got %d sends, want 1", n)
		}
	})

	t.Run("the answer path", func(t *testing.T) {
		x := newMoveFix(t, liveMoved())
		x.dstHub.reply = second
		_, err := x.src.SendAnswerMessage(ctx, x.post(t, "HUM-3"), wuiBox, "q-msg", 4)
		var he *HubError
		if !errors.As(err, &he) || he.Token != wire.TokenTopicMoved {
			t.Fatalf("got %v", err)
		}
		if n := len(x.dstHub.sends()); n != 1 {
			t.Errorf("<DST> got %d sends", n)
		}
	})
}

// A retry of a re-route: a desk hub that fails keeps the post on the desk, claim
// and all, and the retry is the same bytes the hub dedups on msg_id. It never
// goes back through <SRC> (the second-hop rule would refuse it).
func TestMovedRetryIsTheSameEnvelope(t *testing.T) {
	ctx := context.Background()
	x := newMoveFix(t, liveMoved())
	x.dstHub.reply = hubRefuses(http.StatusInternalServerError, "internal", "message not stored")
	m := x.post(t, "HUM-3")
	d, err := x.src.SendMessageClaims(ctx, m, wuiBox, Claims{TypedBy: "HUM-1"})
	if err != nil || d != wire.DeliveryPending {
		t.Fatalf("delivery %q err %v", d, err)
	}
	dc := New(x.desk)
	left, err := dc.Pending()
	if err != nil || len(left) != 1 {
		t.Fatalf("desk pending %v %v", left, err)
	}
	if cl := pendingClaims(left[0]); cl.Rerouted != "t1" || cl.TypedBy != "HUM-1" {
		t.Errorf("claims kept on the desk: %+v", cl)
	}
	if n := count(t, x.src.pendingDir()); n != 0 {
		t.Errorf("%d still pending in <SRC>: a second re-route waits", n)
	}
	x.dstHub.mu.Lock()
	x.dstHub.reply = hubTakes
	x.dstHub.mu.Unlock()
	if n, err := flushOnce(t, dc); n != 1 || err != nil {
		t.Fatalf("desk flush: %d %v", n, err)
	}
	sends := x.dstHub.sends()
	if len(sends) != 2 || string(sends[0].Env) != string(sends[1].Env) {
		t.Fatalf("retry changed the envelope: %d sends\n%s\n%s", len(sends), sends[0].Env, sends[len(sends)-1].Env)
	}
	if sends[1].TypedBy != "HUM-1" {
		t.Errorf("the retry lost typed_by: %q", sends[1].TypedBy)
	}

	// A crash between writing the desk's copy and removing <SRC>'s: <SRC>
	// refuses it again and the re-route signs the same bytes.
	x2 := newMoveFix(t, liveMoved())
	m2 := x2.post(t, "HUM-3")
	queue(t, x2.src, m2, wuiBox, Claims{})
	if n, err := flushOnce(t, x2.src); n != 1 || err != nil {
		t.Fatalf("flush: %d %v", n, err)
	}
	queue(t, x2.src, m2, wuiBox, Claims{})
	if n, err := flushOnce(t, x2.src); n != 1 || err != nil {
		t.Fatalf("flush again: %d %v", n, err)
	}
	s2 := x2.dstHub.sends()
	if len(s2) != 2 || string(s2[0].Env) != string(s2[1].Env) {
		t.Fatalf("a second re-route of one post changed the envelope: %d sends", len(s2))
	}
}

// Day 31. Nothing is remembered: the post of day 30 re-routes, the post of day 31
// asks <SRC> again, gets the 404 and is refused. The desk's hub saw only the first.
func TestMovedDayThirtyOneNothingCached(t *testing.T) {
	ctx := context.Background()
	x := newMoveFix(t, liveMoved())
	if _, err := x.src.SendMessageClaims(ctx, x.post(t, "HUM-3"), wuiBox, Claims{}); err != nil {
		t.Fatal(err)
	}
	if n := len(x.dstHub.sends()); n != 1 {
		t.Fatalf("day 30: %d sends", n)
	}
	x.srcHub.mu.Lock()
	x.srcHub.reply = hubRefuses(http.StatusNotFound, wire.TokenTopicMoved, "this topic is gone from this workspace")
	x.srcHub.mu.Unlock()
	_, err := x.src.SendMessageClaims(ctx, x.post(t, "HUM-3"), wuiBox, Claims{})
	if err == nil || !strings.Contains(err.Error(), "names no destination") {
		t.Fatalf("day 31: %v", err)
	}
	if a, b := len(x.srcHub.sends()), len(x.dstHub.sends()); a != 2 || b != 1 {
		t.Errorf("sends: <SRC> %d, <DST> %d, want 2 and 1", a, b)
	}
}

// to_box in <DST>: box-wui stays, a named box stays if that workspace's roster
// has the agent there, else its roster places it, else the post is refused.
func TestMovedToBoxIsTheDesksWorkspace(t *testing.T) {
	ctx := context.Background()
	toBox := func(t *testing.T, x *moveFix) string {
		t.Helper()
		sends := x.dstHub.sends()
		if len(sends) != 1 {
			t.Fatalf("%d sends", len(sends))
		}
		e, err := wire.ParseEnvelope(sends[0].Env)
		if err != nil {
			t.Fatal(err)
		}
		return e.ToBox
	}
	t.Run("the roster agrees", func(t *testing.T) {
		x := newMoveFix(t, liveMoved())
		New(x.desk).saveRoster(map[string][]string{"box-b": {"c-009"}, "box-c": {"c-009"}})
		if _, err := x.src.SendMessageClaims(ctx, x.post(t, "c-009"), "box-b", Claims{}); err != nil {
			t.Fatal(err)
		}
		if got := toBox(t, x); got != "box-b" {
			t.Errorf("to_box %s", got)
		}
	})
	t.Run("the roster places it elsewhere", func(t *testing.T) {
		x := newMoveFix(t, liveMoved())
		New(x.desk).saveRoster(map[string][]string{"box-z": {"c-009"}})
		if _, err := x.src.SendMessageClaims(ctx, x.post(t, "c-009"), "box-b", Claims{}); err != nil {
			t.Fatal(err)
		}
		if got := toBox(t, x); got != "box-z" {
			t.Errorf("to_box %s", got)
		}
	})
	t.Run("not there", func(t *testing.T) {
		x := newMoveFix(t, liveMoved())
		_, err := x.src.SendMessageClaims(ctx, x.post(t, "c-009"), "box-b", Claims{})
		assertRefused(t, x, err, "cannot place c-009")
	})
}

// A blob is uploaded from the desk's store, so the re-route copies it there.
func TestMovedCopiesBlobs(t *testing.T) {
	ctx := context.Background()
	x := newMoveFix(t, liveMoved())
	m := x.post(t, "HUM-3")
	raw := []byte("the attachment")
	id := blobID(raw)
	if err := writeAtomic(filepath.Join(x.src.Cfg.FilesDir(), id), raw); err != nil {
		t.Fatal(err)
	}
	m.Files = []msg.Attachment{{Mode: "blob", Kind: "file", FileID: id, Name: "a.txt", Bytes: int64(len(raw)), SHA256: id}}
	d, err := x.src.SendMessageClaims(ctx, m, wuiBox, Claims{})
	if err != nil || d != wire.DeliverySent {
		t.Fatalf("delivery %q err %v", d, err)
	}
	x.dstHub.mu.Lock()
	got := string(x.dstHub.files[id])
	x.dstHub.mu.Unlock()
	if got != string(raw) {
		t.Errorf("the desk's hub holds %q", got)
	}
}

// A client that names no tenant still marks the re-route: an empty claim is no
// claim, and the desk's sidecar would hop again.
func TestMovedClaimSetWithNoTenant(t *testing.T) {
	x := newMoveFix(t, liveMoved())
	x.src.Cfg.Tenant = ""
	x.dstHub.reply = hubRefuses(http.StatusInternalServerError, "internal", "message not stored")
	if _, err := x.src.SendMessageClaims(context.Background(), x.post(t, "HUM-3"), wuiBox, Claims{}); err != nil {
		t.Fatal(err)
	}
	left, err := New(x.desk).Pending()
	if err != nil || len(left) != 1 {
		t.Fatalf("desk pending %v %v", left, err)
	}
	if cl := pendingClaims(left[0]); cl.Rerouted == "" {
		t.Error("the re-route carries no claim")
	}
}
