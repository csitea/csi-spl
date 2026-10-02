package hub_test

// Perf round 4, G1: one request reads a channel's human members ONCE. The
// read door (messageDoor / canReadChannel) and the live fan-out
// (channelMemberSet, fanoutMove's old and new sets) asked the store for the
// same channel_humans list two to five times per request.
//
// The counts below run on the memory store. With SPOOL_TEST_PG_DSN the same
// requests also go through the counting pgProxy of onsend_bench_test.go and
// log Postgres round trips per route (n=MEMO_RT_N fresh rigs, default 1):
//
//	SPOOL_TEST_PG_DSN=... MEMO_RT_N=5 go test ./internal/hub -run TestChannelHumansReadOncePerRequest -v

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// humansCount counts ChannelHumanMembers calls that reach the store.
type humansCount struct {
	store.Store
	n atomic.Int64
}

func (c *humansCount) ChannelHumanMembers(ctx context.Context, tenant, channel string) ([]string, error) {
	c.n.Add(1)
	return c.Store.ChannelHumanMembers(ctx, tenant, channel)
}

// memoMoveEnv is moveEnv (archiveEnv's options, the same three channels and
// six rows) with the hub's store wrapped in a humansCount.
func memoMoveEnv(t *testing.T) (moveRig, *humansCount) {
	t.Helper()
	var cnt *humansCount
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Authorizer = roleOf{"HUM-8": rbac.BizOwner, "HUM-9": rbac.Admin}
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
		cnt = &humansCount{Store: o.Store}
		o.Store = cnt
	})
	tid, _ := e.tenant()
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	everyone := []string{"HUM-1", "HUM-2", "HUM-8", "HUM-9"}
	for ch, hums := range map[string][]string{"devel": everyone, "ops": everyone, "secret": {"HUM-2"}} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: "HUM-2", CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
		if err := e.st.AddChannelHumans(ctx, tid, ch, hums, "HUM-2", now); err != nil {
			t.Fatal(err)
		}
	}
	g := moveRig{e: e, tid: tid, T: uuidV4(), U: uuidV4(), W: uuidV4()}
	put := func(task, parent, channel, from string, isParent, n int) string {
		t.Helper()
		id, at := uuidV4(), now.Add(time.Duration(n)*time.Second)
		m := store.Message{TenantID: tid, MsgID: id, TaskID: task, ParentTaskID: parent, Channel: channel, IsParent: isParent,
			TS: at, FromBox: hub.WUIBox, FromID: from, ToBox: hub.WUIBox, ToID: "ALL-0", Kind: "note", Body: "hello " + id,
			Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + id + `"}`),
			ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
		if _, err := e.st.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return id
	}
	g.card = put(g.T, "", "devel", "HUM-1", 1, 0)
	g.r = put(g.T, "", "devel", "HUM-2", 0, 1)
	g.r3 = put(g.T, "", "devel", "HUM-1", 0, 2)
	g.x1 = put(g.r3, g.T, "devel", "HUM-2", 0, 3)
	g.uCard = put(g.U, "", "ops", "HUM-2", 1, 4)
	g.wCard = put(g.W, "", "secret", "HUM-2", 1, 5)
	return g, cnt
}

func TestChannelHumansReadOncePerRequest(t *testing.T) {
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
	if v, err := strconv.Atoi(os.Getenv("MEMO_RT_N")); err == nil && v > 0 {
		n = v
	}
	// reads is the most channel_humans reads the request may make. Before G1
	// (n=5, memory and Postgres alike): kind 2, archive 2, reaction 2,
	// promote 3, move 4, merge-topic 5; fanoutMove's one read for a
	// same-channel move took promote to 2.
	routes := []struct {
		name   string
		reads  int64
		method string
		path   func(g moveRig) string
		body   func(g moveRig) any
	}{
		{"kind", 2, http.MethodPatch, func(g moveRig) string { return "/v1/messages/" + g.card + "/kind" },
			func(moveRig) any { return map[string]string{"kind": "blocker"} }},
		{"archive", 2, http.MethodPut, func(g moveRig) string { return "/v1/messages/" + g.card + "/archive" },
			func(moveRig) any { return nil }},
		{"reaction", 2, http.MethodPut, func(g moveRig) string { return "/v1/messages/" + g.card + "/reactions" },
			func(moveRig) any { return map[string]string{"emoji": "👍"} }},
		{"promote", 2, http.MethodPost, func(g moveRig) string { return "/v1/messages/" + g.r3 + "/promote-topic" },
			func(moveRig) any { return map[string]any{} }},
		{"move", 4, http.MethodPost, func(g moveRig) string { return "/v1/messages/" + g.card + "/move" },
			func(moveRig) any { return map[string]string{"to_channel": "ops"} }},
		{"merge-topic", 5, http.MethodPost, func(g moveRig) string { return "/v1/messages/" + g.card + "/merge-topic" },
			func(g moveRig) any { return map[string]any{"to_task": g.U} }},
	}
	for _, rt := range routes {
		var reads, trips []int64
		for i := 0; i < n; i++ {
			g, cnt := memoMoveEnv(t)
			time.Sleep(20 * time.Millisecond)
			r0, p0 := cnt.n.Load(), int64(0)
			if proxy != nil {
				p0 = proxy.packets.Load()
			}
			if code, out := call(t, g.e, g.tid, rt.method, rt.path(g), "HUM-1", rt.body(g)); code != http.StatusOK {
				t.Fatalf("%s: %d %v", rt.name, code, out)
			}
			time.Sleep(20 * time.Millisecond)
			reads = append(reads, cnt.n.Load()-r0)
			if proxy != nil {
				trips = append(trips, proxy.packets.Load()-p0)
			}
		}
		slices.Sort(reads)
		slices.Sort(trips)
		if proxy != nil {
			t.Logf("%-12s channel_humans reads %v  DB round trips %v (median %d, n=%d)", rt.name, reads, trips, trips[len(trips)/2], n)
		} else {
			t.Logf("%-12s channel_humans reads %v (n=%d)", rt.name, reads, n)
		}
		if reads[0] > rt.reads {
			t.Errorf("%s: %d channel_humans reads, budget %d", rt.name, reads[0], rt.reads)
		}
	}
}

// The memo dies with its request: a member removed between two requests
// loses the channel on the very next one.
func TestChannelHumansMemoIsPerRequest(t *testing.T) {
	g, cnt := memoMoveEnv(t)
	react := func() int {
		code, _ := call(t, g.e, g.tid, http.MethodPut, "/v1/messages/"+g.card+"/reactions", "HUM-1", map[string]string{"emoji": "👍"})
		return code
	}
	if code := react(); code != http.StatusOK {
		t.Fatalf("a member reacts: %d", code)
	}
	if err := g.e.st.RemoveChannelHuman(context.Background(), g.tid, "devel", "HUM-1"); err != nil {
		t.Fatal(err)
	}
	before := cnt.n.Load()
	if code := react(); code != http.StatusNotFound {
		t.Fatalf("a removed member still reaches the message: %d", code)
	}
	if cnt.n.Load() == before {
		t.Fatal("the second request read no membership: a memo outlived its request")
	}
}
