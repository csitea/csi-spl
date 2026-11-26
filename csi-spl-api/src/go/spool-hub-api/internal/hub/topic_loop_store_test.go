package hub_test

import (
	"context"
	"net/http"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 182 row L2 on row L1's own store (R7 c-297 N1): the hub's cap and
// timer claim against store.TopicLoopStore as L1 wrote it, with no _test
// double: store.Memory, and Postgres (rdb 0301) under SPOOL_TEST_PG_DSN.
// A prompt is found by its derived id (4.3 step 3), as no view shows it.

// realLoopRig is a loopRig whose store is newStore(t), and whose hub clock
// runs skew ahead of the wall clock.
type realLoopRig struct {
	*loopRig
	st   store.Store
	ls   store.TopicLoopStore
	skew atomic.Int64
}

func newRealLoopRig(t *testing.T) *realLoopRig {
	t.Helper()
	st := newStore(t)
	ls, ok := st.(store.TopicLoopStore)
	if !ok {
		t.Fatalf("%T keeps no discussion loops", st)
	}
	r := &realLoopRig{st: st, ls: ls}
	r.loopRig = newLoopRigOn(t, st, func(o *hub.Options) {
		o.Now = func() time.Time { return time.Now().Add(time.Duration(r.skew.Load())) }
	})
	return r
}

// prompts counts the causes in seeds that fired loop: a stored row at the
// prompt id derived from (loop, seed).
func (r *realLoopRig) prompts(t *testing.T, loop string, seeds []string) int {
	t.Helper()
	n := 0
	for _, s := range seeds {
		if _, err := r.st.GetEditable(context.Background(), r.tid, uid.FromSeed("topic-loop:"+loop+":"+s), time.Now().Add(time.Hour)); err == nil {
			n++
		}
	}
	return n
}

func (r *realLoopRig) loop(t *testing.T, id string) store.TopicLoop {
	t.Helper()
	ls, err := r.ls.TopicLoops(context.Background(), r.tid, r.task)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range ls {
		if l.LoopID == id {
			return l
		}
	}
	t.Fatalf("loop %s not in the store", id)
	return store.TopicLoop{}
}

// The cap on L1's CountTopicLoopFire: 30 agent replies are 15 fires and 15
// awaited answers; 12 prompts are stored and the counters say 12.
func TestTopicLoopStoreCapHolds(t *testing.T) {
	r := newRealLoopRig(t)
	loop := r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	var posts []string
	for i := 0; i < 30; i++ {
		posts = append(posts, r.agentSay(t, r.task, "ALL-0", "reply"))
	}
	r.barrier(t)
	if n := r.prompts(t, loop, posts); n != 12 {
		t.Fatalf("30 agent replies on %T: %d loop prompts, want 12", r.st, n)
	}
	if l := r.loop(t, loop); l.FiresInHour != 12 || l.FiresTotal != 12 {
		t.Fatalf("fires in hour %d, total %d, want 12 and 12", l.FiresInHour, l.FiresTotal)
	}
	code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/topics/"+r.task+"/loops", "HUM-1", nil)
	loops, _ := out["loops"].([]any)
	if code != http.StatusOK || len(loops) != 1 || loops[0].(map[string]any)["held_until"] == nil {
		t.Fatalf("a capped loop shows no held_until: %d %v", code, out)
	}
}

// The claim on L1's ClaimDueTopicLoops: an every_hour loop is not due
// before its hour; past it, two hub instances on one store fire it once,
// seeded on the pre-move due time, and the next tick fires nothing.
func TestTopicLoopStoreClaimFiresOnce(t *testing.T) {
	r := newRealLoopRig(t)
	ctx := context.Background()
	loop := r.addLoop(t, map[string]any{"prompt": "status?", "triggers": []string{store.LoopEveryHour}})
	due := r.loop(t, loop).NextDueAt
	other, err := hub.New(hub.Options{Store: r.st, Blob: blob.Dir{Root: t.TempDir()}, Log: zerolog.Nop(), WUIKey: r.key, Authorizer: r.roles,
		TenantHostPattern: "{tenant}" + domain, QueueTTL: time.Hour, QueueMaxPerBox: 1000, Version: "test",
		Now: func() time.Time { return time.Now().Add(time.Duration(r.skew.Load())) }})
	if err != nil {
		t.Fatal(err)
	}
	r.e.srv.TopicLoopTickOnce(ctx)
	if l := r.loop(t, loop); l.FiresTotal != 0 {
		t.Fatalf("a loop due in an hour fired: %+v", l)
	}
	r.skew.Store(int64(61 * time.Minute))
	r.e.srv.TopicLoopTickOnce(ctx)
	other.TopicLoopTickOnce(ctx)
	r.e.srv.TopicLoopTickOnce(ctx)
	if l := r.loop(t, loop); l.FiresTotal != 1 || !l.NextDueAt.After(due) {
		t.Fatalf("on %T: fires %d, next due %v (was %v), want 1 fire and a later due", r.st, l.FiresTotal, l.NextDueAt, due)
	}
	if n := r.prompts(t, loop, []string{"due:" + due.UTC().Format(time.RFC3339)}); n != 1 {
		t.Fatalf("no prompt seeded on the pre-move due time %v", due)
	}
}

// Spec 182 v0.11 change 8 (SPL-6587, rdb 0329): PUT .../loops/order on L1's
// store stores the list's order, GET reads it back, and an order that does
// not name each loop once is 400 bad_loop with the order unchanged.
func TestTopicLoopStoreOrder(t *testing.T) {
	r := newRealLoopRig(t)
	a := r.addLoop(t, loopBody(store.LoopAfterAgentReply))
	b := r.addLoop(t, loopBody(store.LoopAfterHumanReply))
	c := r.addLoop(t, loopBody(store.LoopBlockerPosted))
	path := "/v1/topics/" + r.task + "/loops"
	order := func(out map[string]any) []string {
		var ids []string
		for _, l := range out["loops"].([]any) {
			ids = append(ids, l.(map[string]any)["loop_id"].(string))
		}
		return ids
	}
	code, out := call(t, r.e, r.tid, http.MethodPut, path+"/order", "HUM-1", map[string]any{"loop_ids": []string{c, a, b}})
	if code != http.StatusOK || !slices.Equal(order(out), []string{c, a, b}) {
		t.Fatalf("order: %d %v", code, out)
	}
	if code, out := call(t, r.e, r.tid, http.MethodGet, path, "HUM-1", nil); code != http.StatusOK || !slices.Equal(order(out), []string{c, a, b}) {
		t.Fatalf("GET after order: %d %v", code, out)
	}
	for why, body := range map[string]map[string]any{
		"missing":  {"loop_ids": []string{c, a}},
		"twice":    {"loop_ids": []string{c, a, a}},
		"stranger": {"loop_ids": []string{c, a, uuidV4()}},
		"no ids":   {},
		"unknown":  {"loop_ids": []string{c, a, b}, "x": 1},
	} {
		if code, out := call(t, r.e, r.tid, http.MethodPut, path+"/order", "HUM-1", body); code != http.StatusBadRequest || out["error"] != "bad_loop" {
			t.Fatalf("%s: %d %v, want 400 bad_loop", why, code, out)
		}
	}
	if _, out := call(t, r.e, r.tid, http.MethodGet, path, "HUM-1", nil); !slices.Equal(order(out), []string{c, a, b}) {
		t.Fatalf("a refused order changed the list: %v", out)
	}
}
