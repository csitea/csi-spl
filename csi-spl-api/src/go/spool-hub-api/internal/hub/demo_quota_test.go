package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// quotaEnv is demoEnv with box-wui pinned in the demo workspace and CLE-07
// on box-a, so an "@CLE-07 ..." browser send is a signed dispatch.
func quotaEnv(t *testing.T, mut ...func(*hub.Options)) (*env, string) {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	e, demo := demoEnv(t, append([]func(*hub.Options){func(o *hub.Options) {
		o.WUIKey = key
		o.DemoPostsPerMinute = 1000 // T012's post quota is its own test (demo_post_quota_test.go)
	}}, mut...)...)
	e.pin(demo, e.box(demo, "box-a", "CLE-07"))
	e.pinKey(demo, hub.WUIBox, pub)
	return e, demo
}

// turnID is the msg id of the i-th agent turn of a test.
func turnID(i int) string { return fmt.Sprintf("7d1e0c2a-0000-4000-8000-%012d", i) }

// sendTurn sends "@CLE-07 turn i" and returns the ack or error frame.
func sendTurn(t *testing.T, c *websocket.Conn, i int) map[string]any {
	t.Helper()
	wsjson.Write(context.Background(), c, map[string]any{"type": "send", "msg_id": turnID(i), //nolint:errcheck
		"task_id": "lobby", "kind": "task", "body": fmt.Sprintf("@CLE-07 turn %d", i)})
	return readType(t, c, "ack")
}

// queued is the msg ids queued for box-a.
func queued(t *testing.T, e *env, tid string) map[string]bool {
	t.Helper()
	q, err := e.st.QueuedFor(context.Background(), tid, "box-a", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	for _, d := range q {
		out[d.MsgID] = true
	}
	return out
}

// specs/077 T013 (3.7): a demo_user's 20 agent turns of a visit are
// delivered; the 21st answers 429 demo_quota before any box delivery is
// built - no deliveries row, no stored message. A resend of a stored turn
// still re-acks (it is no new turn).
// CONTROL: SPOOL_HUB_DEMO_AGENT_TURNS raised to 21 delivers the same 21st.
func TestDemoAgentTurnQuota(t *testing.T) {
	for _, tc := range []struct {
		name  string
		turns int // Options.DemoAgentTurns; 0 = the default 20
		want  bool
	}{{"default 20", 0, false}, {"CONTROL limit 21", 21, true}} {
		t.Run(tc.name, func(t *testing.T) {
			e, demo := quotaEnv(t, func(o *hub.Options) { o.DemoAgentTurns = tc.turns })
			c := dialMember(t, e, demo, "", seat(t, e, demo, rbac.DemoUser))
			for i := 1; i <= 20; i++ {
				if ack := sendTurn(t, c, i); ack["type"] != "ack" || ack["to_box"] != "box-a" || ack["delivery"] != wire.DeliveryQueued {
					t.Fatalf("turn %d: %v", i, ack)
				}
			}
			f := sendTurn(t, c, 21)
			q := queued(t, e, demo)
			if !tc.want {
				if f["type"] != "error" || f["error"] != "demo_quota" || f["status"] != float64(http.StatusTooManyRequests) {
					t.Fatalf("21st turn: %v, want 429 demo_quota", f)
				}
				if len(q) != 20 || q[turnID(21)] {
					t.Fatalf("box-a queue after the refusal: %d rows, 21st queued %v", len(q), q[turnID(21)])
				}
				if _, _, err := e.st.MessageTimes(context.Background(), demo, turnID(21)); !errors.Is(err, store.ErrNotFound) {
					t.Fatalf("refused turn stored: %v", err)
				}
				if ack := sendTurn(t, c, 20); ack["type"] != "ack" {
					t.Fatalf("resend of turn 20 at the limit: %v", ack)
				}
				return
			}
			if f["type"] != "ack" || !q[turnID(21)] || len(q) != 21 {
				t.Fatalf("CONTROL: 21st turn under limit 21: %v, %d queued", f, len(q))
			}
		})
	}
}

// T013: the quota counts demo users only. A developer of the demo workspace
// sends 25 turns, all delivered; a demo_user's spent quota leaves the next
// demo_user's visit untouched.
func TestDemoAgentTurnQuotaOthersUnaffected(t *testing.T) {
	e, demo := quotaEnv(t, func(o *hub.Options) { o.DemoAgentTurns = 2 })
	dev := dialMember(t, e, demo, "", seat(t, e, demo, rbac.Developer))
	for i := 1; i <= 25; i++ {
		if ack := sendTurn(t, dev, i); ack["type"] != "ack" {
			t.Fatalf("developer turn %d: %v", i, ack)
		}
	}
	a := dialMember(t, e, demo, "", seat(t, e, demo, rbac.DemoUser))
	for i := 101; i <= 102; i++ {
		if ack := sendTurn(t, a, i); ack["type"] != "ack" {
			t.Fatalf("visitor a turn %d: %v", i, ack)
		}
	}
	if f := sendTurn(t, a, 103); f["error"] != "demo_quota" {
		t.Fatalf("visitor a 3rd turn: %v", f)
	}
	b := dialMember(t, e, demo, "", seat(t, e, demo, rbac.DemoUser))
	if ack := sendTurn(t, b, 201); ack["type"] != "ack" {
		t.Fatalf("visitor b first turn: %v", ack)
	}
	if q := queued(t, e, demo); len(q) != 25+2+1 {
		t.Fatalf("box-a queue: %d rows, want 28", len(q))
	}
}

// quotaTake is one recorded TakeQuota call.
type quotaTake struct {
	tenant, member, kind string
	window               time.Time
	limit                int
}

// quotaLog collects the TakeQuota calls of quotaRecMem / quotaRecPg.
type quotaLog struct {
	mu    sync.Mutex
	takes []quotaTake
}

func (l *quotaLog) add(tenant, member, kind string, window time.Time, limit int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.takes = append(l.takes, quotaTake{tenant, member, kind, window, limit})
}

func (l *quotaLog) all() []quotaTake {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]quotaTake(nil), l.takes...)
}

// quotaRecMem / quotaRecPg record every TakeQuota; every store call is the
// wrapped store's.
type quotaRecMem struct {
	*store.Memory
	log *quotaLog
}
type quotaRecPg struct {
	*store.Postgres
	log *quotaLog
}

func (s quotaRecMem) TakeQuota(ctx context.Context, tenant, member, kind string, window time.Time, limit int) (int, bool, error) {
	s.log.add(tenant, member, kind, window, limit)
	return s.Memory.TakeQuota(ctx, tenant, member, kind, window, limit)
}

func (s quotaRecPg) TakeQuota(ctx context.Context, tenant, member, kind string, window time.Time, limit int) (int, bool, error) {
	s.log.add(tenant, member, kind, window, limit)
	return s.Postgres.TakeQuota(ctx, tenant, member, kind, window, limit)
}

// refactor r37-02: one agent turn and one plain post of a demo_user take
// exactly these counters, in this order: each send's minute, its day, then
// one agent turn of its visit (a lobby post fans out to box-a too). It pins
// each take's tenant, member, kind, window and limit, which the count-only
// tests above do not tell apart (a swapped kind or window still refuses).
func TestDemoQuotaTakes(t *testing.T) {
	clk, rec := newPostClock(), &quotaLog{}
	e, demo := quotaEnv(t, clk.opt, func(o *hub.Options) {
		o.DemoAgentTurns, o.DemoPostsPerDay = 7, 333
		switch s := o.Store.(type) {
		case *store.Memory:
			o.Store = quotaRecMem{s, rec}
		case *store.Postgres:
			o.Store = quotaRecPg{s, rec}
		}
	})
	vis := seat(t, e, demo, rbac.DemoUser)
	c := dialMember(t, e, demo, "", vis)
	if ack := sendTurn(t, c, 1); ack["type"] != "ack" {
		t.Fatalf("agent turn: %v", ack)
	}
	if ack := sendPost(t, c, 2); ack["type"] != "ack" {
		t.Fatalf("post: %v", ack)
	}
	since, err := e.st.(store.QuotaCounter).MemberSince(context.Background(), demo, vis)
	if err != nil {
		t.Fatal(err)
	}
	now := clk.now().UTC()
	minute := quotaTake{demo, vis, "post_min", now.Truncate(time.Minute), 1000}
	day := quotaTake{demo, vis, "post_day", now.Truncate(24 * time.Hour), 333}
	turn := quotaTake{demo, vis, "agent_turn", since, 7}
	want := []quotaTake{minute, day, turn, minute, day, turn}
	got := rec.all()
	if len(got) != len(want) {
		t.Fatalf("takes: %+v, want %+v", got, want)
	}
	for i := range want {
		if g, w := got[i], want[i]; g.tenant != w.tenant || g.member != w.member || g.kind != w.kind ||
			!g.window.Equal(w.window) || g.limit != w.limit {
			t.Fatalf("take %d: %+v, want %+v", i, g, w)
		}
	}
}
