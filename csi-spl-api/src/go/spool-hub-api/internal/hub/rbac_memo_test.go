package hub_test

// Perf edition 20261004, E07: one message write reads the writer's role
// ONCE. A write route asked rbac for the same (tenant, human) role on its
// session door permit (humanTenant), its own permit and its moderator checks:
// each ask was a MemberRole round trip.
//
// Measured on trunk 0f7a40db5 (Postgres, n=5, load 10..13): authorizer
// MemberRole reads 2 per write (3 on move, promote, merge-topic) -> 1; DB
// round trips (median) edit 14 -> 12, delete 10 -> 8, reaction put 8 -> 6,
// reaction delete 12 -> 10, kind 7 -> 5, archive 14 -> 12, unarchive 14 -> 12,
// move 17 -> 14, promote 14 -> 11, merge-topic 20 -> 17, topic delete 14 -> 12.
// Two membership reads stay per write: the session door's own
// (auth ActiveTenant) and editorID's (wuiSession -> sessionFor).
//
// The counts below run on a prod-like session door (store-backed
// rbac.Authorizer, one signed-in member) on the memory store. With
// SPOOL_TEST_PG_DSN the same requests also go through the counting pgProxy
// of onsend_bench_test.go and log Postgres round trips per route
// (n=ROLE_RT_N samples, default 1):
//
//	SPOOL_TEST_PG_DSN=... ROLE_RT_N=5 go test ./internal/hub -run TestMemberRoleReadOncePerRequest -v

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// roleCount counts the MemberRole reads the hub's authorizer sends to the
// store; demoted, once set, is the role every read answers.
type roleCount struct {
	rbac.Source
	n       atomic.Int64
	demoted atomic.Value // string
}

func (c *roleCount) MemberRole(ctx context.Context, humanID, tenant string) (string, error) {
	c.n.Add(1)
	if role, _ := c.demoted.Load().(string); role != "" {
		return role, nil
	}
	return c.Source.MemberRole(ctx, humanID, tenant)
}

// roleRig is the session door rig with the production authorizer over a
// roleCount, a signed-in owner and an open WUI socket.
type roleRig struct {
	r      *doorRig
	cnt    *roleCount
	tenant string
	c      *websocket.Conn
}

func newRoleRig(t *testing.T) *roleRig {
	t.Helper()
	g := &roleRig{}
	g.r = newDoorRig(t, func(o *hub.Options) {
		g.cnt = &roleCount{Source: store.RBACSource{H: o.Store.(store.Humans)}}
		o.Authorizer = &rbac.Authorizer{Src: g.cnt}
	})
	g.tenant, _ = g.r.e.tenant()
	if landed := g.r.signIn(t, g.tenant); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+g.tenant+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: g.r.browser})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.CloseNow() })                       //nolint:errcheck
	wsjson.Write(ctx, c, map[string]string{"type": "hello"}) //nolint:errcheck
	(&wuiClient{t: t, c: c}).read("welcome")
	g.c = c
	return g
}

// topic posts a fresh #alerts topic of a card and one reply (the member's own).
func (g *roleRig) topic(t *testing.T) (task, card, reply string) {
	t.Helper()
	task, card, reply = uuid4(), uuid4(), uuid4()
	channelFrame(t, g.c, card, task, store.ChannelAlerts, "card "+card)
	channelFrame(t, g.c, reply, task, store.ChannelAlerts, "reply "+reply)
	return task, card, reply
}

func (g *roleRig) do(t *testing.T, method, path string, body any) (int, string) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	return g.r.req(t, method, g.tenant, path, http.Header{"Content-Type": {"application/json"}}, rd)
}

// roleRoute is one message write: setup posts what it needs and returns the
// method, path and body of the request under test.
type roleRoute struct {
	name  string
	reads int64
	setup func(t *testing.T, g *roleRig) (method, path string, body any)
}

func roleRoutes() []roleRoute {
	msgPath := func(id, tail string) string { return "/v1/messages/" + id + tail }
	return []roleRoute{
		{"edit", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, _, r := g.topic(t)
			return http.MethodPatch, msgPath(r, ""), map[string]string{"body": "edited"}
		}},
		{"delete", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, _, r := g.topic(t)
			return http.MethodDelete, msgPath(r, ""), nil
		}},
		{"reaction put", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, c, _ := g.topic(t)
			return http.MethodPut, msgPath(c, "/reactions"), map[string]string{"emoji": "👍"}
		}},
		{"reaction delete", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, c, _ := g.topic(t)
			if code, out := g.do(t, http.MethodPut, msgPath(c, "/reactions"), map[string]string{"emoji": "👍"}); code != http.StatusOK {
				t.Fatalf("reaction put: %d %s", code, out)
			}
			return http.MethodDelete, msgPath(c, "/reactions"), map[string]string{"emoji": "👍"}
		}},
		{"kind", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, c, _ := g.topic(t)
			return http.MethodPatch, msgPath(c, "/kind"), map[string]string{"kind": "blocker"}
		}},
		{"archive", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, c, _ := g.topic(t)
			return http.MethodPut, msgPath(c, "/archive"), nil
		}},
		{"unarchive", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, c, _ := g.topic(t)
			if code, out := g.do(t, http.MethodPut, msgPath(c, "/archive"), nil); code != http.StatusOK {
				t.Fatalf("archive: %d %s", code, out)
			}
			return http.MethodDelete, msgPath(c, "/archive"), nil
		}},
		{"move", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, c, _ := g.topic(t)
			return http.MethodPost, msgPath(c, "/move"), map[string]string{"to_channel": store.ChannelFeedback}
		}},
		{"promote", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, _, r := g.topic(t)
			return http.MethodPost, msgPath(r, "/promote-topic"), map[string]any{}
		}},
		{"merge-topic", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, c, _ := g.topic(t)
			u, _, _ := g.topic(t)
			return http.MethodPost, msgPath(c, "/merge-topic"), map[string]string{"to_task": u}
		}},
		{"topic delete", 1, func(t *testing.T, g *roleRig) (string, string, any) {
			_, c, _ := g.topic(t)
			return http.MethodDelete, msgPath(c, "/topic"), nil
		}},
	}
}

func TestMemberRoleReadOncePerRequest(t *testing.T) {
	var proxy *pgProxy
	if dsn := os.Getenv("SPOOL_TEST_PG_DSN"); dsn != "" {
		u, err := url.Parse(dsn)
		if err != nil {
			t.Fatal(err)
		}
		proxy = newPGProxy(t, u.Host)
		u.Host = proxy.ln.Addr().String()
		t.Setenv("SPOOL_TEST_PG_DSN", u.String())
	}
	n := 1
	if v, err := strconv.Atoi(os.Getenv("ROLE_RT_N")); err == nil && v > 0 {
		n = v
	}
	g := newRoleRig(t)
	for _, rt := range roleRoutes() {
		var reads, trips []int64
		for i := 0; i < n; i++ {
			method, path, body := rt.setup(t, g)
			time.Sleep(20 * time.Millisecond) // let background writes (last-seen, fan-out) settle
			if os.Getenv("RT_MARK") != "" {   // a marker line in a log_statement=all server log
				g.r.e.st.(*store.Postgres).Pool().Exec(context.Background(), "SELECT $1::text", "MARK "+rt.name) //nolint:errcheck
			}
			r0, p0 := g.cnt.n.Load(), int64(0)
			if proxy != nil {
				p0 = proxy.packets.Load()
			}
			if code, out := g.do(t, method, path, body); code/100 != 2 {
				t.Fatalf("%s: %d %s", rt.name, code, out)
			}
			time.Sleep(20 * time.Millisecond)
			reads = append(reads, g.cnt.n.Load()-r0)
			if proxy != nil {
				trips = append(trips, proxy.packets.Load()-p0)
			}
		}
		slices.Sort(reads)
		slices.Sort(trips)
		if proxy != nil {
			t.Logf("%-16s MemberRole reads %v  DB round trips %v (median %d, n=%d)", rt.name, reads, trips, trips[len(trips)/2], n)
		} else {
			t.Logf("%-16s MemberRole reads %v (n=%d)", rt.name, reads, n)
		}
		if reads[0] > rt.reads {
			t.Errorf("%s: %d MemberRole reads, budget %d", rt.name, reads[0], rt.reads)
		}
	}
}

// The control: the role memo dies with its request. A member demoted (here
// to a role the tenant cannot see, which grants nothing) between two writes
// is refused on the very next one, and that request reads the role again.
func TestMemberRoleMemoIsPerRequest(t *testing.T) {
	g := newRoleRig(t)
	_, card, _ := g.topic(t)
	kind := func() (int, string) {
		return g.do(t, http.MethodPatch, "/v1/messages/"+card+"/kind", map[string]string{"kind": "blocker"})
	}
	if code, out := kind(); code != http.StatusOK {
		t.Fatalf("a member sets a kind: %d %s", code, out)
	}
	g.cnt.demoted.Store("retired_role")
	before := g.cnt.n.Load()
	if code, out := kind(); code != http.StatusForbidden {
		t.Fatalf("a demoted member still writes: %d %s", code, out)
	}
	if g.cnt.n.Load() == before {
		t.Fatal("the second request read no role: a memo outlived its request")
	}
}
