package hub_test

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 186 M4 (SPL-6378): the multicast_check frame (7.1.2) and the one
// frame of a kind in flight per connection (plan N4). Memory, and Postgres
// under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

func checkFrame(ids ...string) map[string]any {
	return map[string]any{"type": "multicast_check", "task_ids": ids, "body": "hello all", "files": []any{}}
}

func messageCount(t *testing.T, e *env, tid string) int {
	t.Helper()
	n, err := e.st.CountMessagesSince(context.Background(), tid, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// Per target: in scope is ok, an archived topic topic_archived, out of scope
// (another channel, a DM, the issue's topic, an unknown id) multicast_no_topic;
// the whole check is ok only when every target is. Neither frame stores.
func TestMulticastCheckTargets(t *testing.T) {
	r := newSelectRig(t)
	c := r.dial(t, r.author)
	before := messageCount(t, r.e, r.tid)
	a := bulkCall(t, c, "multicast_checked", checkFrame(r.pub, r.mine, r.lob, r.pub))
	if !a.OK || len(a.Targets) != 3 {
		t.Fatalf("in scope: %s, want ok with 3 targets", a.raw)
	}
	for _, x := range a.Targets {
		if !x.OK || x.Title == "" || x.Channel == "" {
			t.Errorf("target %+v, want ok with its channel and title", x)
		}
	}
	unknown := uuidV4()
	a = bulkCall(t, c, "multicast_checked", checkFrame(r.pub, r.arch, r.theirs, r.dm, r.issue, r.locked, unknown))
	want := map[string]string{r.pub: "", r.arch: "topic_archived", r.theirs: "multicast_no_topic", r.dm: "multicast_no_topic",
		r.issue: "multicast_no_topic", r.locked: "multicast_no_topic", unknown: "multicast_no_topic"}
	if a.OK || len(a.Targets) != len(want) {
		t.Fatalf("mixed: %s, want not ok, %d targets", a.raw, len(want))
	}
	for _, x := range a.Targets {
		if x.Error != want[x.TaskID] || x.OK != (want[x.TaskID] == "") {
			t.Errorf("target %s: ok=%v error %q, want %q", x.TaskID, x.OK, x.Error, want[x.TaskID])
		}
	}
	if strings.Contains(strings.ToLower(a.raw), "wombat") || strings.Contains(a.raw, "of theirs") {
		t.Errorf("a hidden topic's title came back: %s", a.raw)
	}
	if a := bulkCall(t, c, "multicast_checked", checkFrame()); a.OK || a.Error != "multicast_none" {
		t.Errorf("no target: %s, want multicast_none", a.raw)
	}
	bulkCall(t, c, "topic_selected", selectFrame([]string{"*"}))
	if after := messageCount(t, r.e, r.tid); after != before {
		t.Errorf("messages %d -> %d: a read-only frame stored something", before, after)
	}
}

// 1200 targets with an unlimited quota are all ok (no cap, R2 QTA).
func TestMulticastCheckNoCap(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	author := seat(t, e, tid, rbac.Developer)
	now := time.Now().UTC().Truncate(time.Second)
	ids := make([]string, 0, 1200)
	for i := range 1200 {
		ids = append(ids, putRow(t, e, tid, uuidV4(), "feedback", author, "ALL-0", "t", now.Add(time.Duration(-i)*time.Second)).TaskID)
	}
	a := bulkCall(t, dialMember(t, e, tid, "x", author), "multicast_checked", checkFrame(ids...))
	n := 0
	for _, x := range a.Targets {
		if x.OK {
			n++
		}
	}
	if !a.OK || n != 1200 {
		t.Errorf("1200 targets: ok=%v, %d ok, want all 1200", a.OK, n)
	}
}

// One target more than the remaining quota refuses the whole check with the
// quota token, naming the count and the remaining messages; exactly the
// remaining passes. RED CONTROL: count the quota per target and the check
// is not refused as a whole.
func TestMulticastCheckQuotaOnce(t *testing.T) {
	r := newSelectRig(t)
	used := messageCount(t, r.e, r.tid)
	e2 := rbacEnvSharing(t, r.e, used+2) // two messages left this period
	c := dialMember(t, e2, r.tid, "x", r.author)
	a := bulkCall(t, c, "multicast_checked", checkFrame(r.pub, r.mine, r.lob))
	if a.OK || a.Error != billing.TokenQuota || !strings.Contains(a.Detail, "3 topics") || !strings.Contains(a.Detail, "2 messages") {
		t.Errorf("3 targets, 2 left: %s, want the whole check refused %q naming 3 and 2", a.raw, billing.TokenQuota)
	}
	if a := bulkCall(t, c, "multicast_checked", checkFrame(r.pub, r.mine)); !a.OK {
		t.Errorf("2 targets, 2 left: %s, want ok", a.raw)
	}
}

// rbacEnvSharing is a second hub on e's store with a month quota of limit.
func rbacEnvSharing(t *testing.T, e *env, limit int) *env {
	t.Helper()
	e2 := rbacEnv(t, func(o *hub.Options) { o.Store, o.QuotaMessagesPerMonth = e.st, limit })
	e2.st = e.st
	return e2
}

// gateStore holds the first ViewTopics until its context ends, so a frame is
// surely in flight when the next one of its kind arrives.
type gateStore struct {
	store.Store
	once    sync.Once
	entered chan struct{}
}

func (g *gateStore) ViewTopics(ctx context.Context, tenant string, q store.TopicQuery) ([]store.TopicRow, error) {
	first := false
	g.once.Do(func() { first = true; close(g.entered) })
	if first {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return g.Store.ViewTopics(ctx, tenant, q)
}

// With one frame of a kind in flight, a newer req_id of that kind cancels
// it: the older gets no answer, the newer one answer. RED CONTROL: run the
// frames inline in the read loop and the first never ends (the test times
// out); drop the cancel and the first never answers either, but the second
// waits behind nothing and the token frame proves the order.
func TestBulkNewerCancelsOlder(t *testing.T) {
	for _, kind := range []string{"topic_select", "multicast_check"} {
		t.Run(kind, func(t *testing.T) {
			g := &gateStore{entered: make(chan struct{})}
			e := newEnv(t, func(o *hub.Options) {
				o.ViewDoor, o.LobbyTaskID, o.ViewCORSOrigins = hub.ViewDoorOff, lobby, []string{wuiOrigin}
				g.Store = o.Store
				o.Store = g
			})
			tid, _ := e.tenant()
			task := putRow(t, e, tid, uuidV4(), "feedback", "HUM-1", "ALL-0", "Release", time.Now().UTC()).TaskID
			c := dialMember(t, e, tid, "x", "")
			frame := func() map[string]any {
				if kind == "topic_select" {
					return selectFrame([]string{"*"})
				}
				return checkFrame(task)
			}
			older, want := frame(), map[string]string{"topic_select": "topic_selected", "multicast_check": "multicast_checked"}[kind]
			older["req_id"] = uuidV4()
			wsjson.Write(context.Background(), c, older) //nolint:errcheck
			select {
			case <-g.entered:
			case <-time.After(10 * time.Second):
				t.Fatal("the first frame never reached ViewTopics")
			}
			a := bulkCall(t, c, want, frame())
			if !a.OK {
				t.Errorf("newer: %s", a.raw)
			}
			wsjson.Write(context.Background(), c, map[string]string{"type": "token"}) //nolint:errcheck
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			for {
				var f map[string]any
				if err := wsjson.Read(ctx, c, &f); err != nil {
					t.Fatalf("waiting for the token frame: %v", err)
				}
				if f["req_id"] == older["req_id"] {
					t.Fatalf("the cancelled frame answered: %v", f)
				}
				if f["type"] == "token" {
					return
				}
			}
		})
	}
}
