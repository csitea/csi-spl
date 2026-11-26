package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 153 sections 3.22.6-3.22.8, row Q2 (SPL-6396, rdb 0323): a queued
// spawn request's own priority, its dragged rank, and a ci row first. Cases
// C111-C113, C115-C118 and C121 of spec 153 3.22.10, on the memory store and
// on Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
//
// RED on origin/master: no route (C112, C115-C117 answer 404 or 405), no own
// column (C111), and priority first puts a priority 1 feature ahead of a ci
// row (C121). Red controls named per case below.

// orderRig is an operator workspace op with an admin and a developer, a box
// pinned in op, and the operator's fleet asks queued there.
type orderRig struct {
	e          *env
	op         string
	admin, dev string
	b          *box
	t0         time.Time
	n          int
}

func newOrderRig(t *testing.T) *orderRig {
	t.Helper()
	r := &orderRig{op: newTenantID("op"), t0: time.Now().UTC().Add(-2 * time.Hour)}
	r.e = rbacEnv(t, func(o *hub.Options) { o.OperatorTenant = r.op })
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(context.Background(), store.Tenant{ID: r.op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	r.admin, r.dev = seat(t, r.e, r.op, rbac.Admin), seat(t, r.e, r.op, rbac.Developer)
	r.b = r.e.box(r.op, "box-b")
	r.e.pin(r.op, r.b)
	return r
}

// queue puts and queues one orch ask of class, working for disc ("" =
// none), enqueued one minute after the previous one; it answers its id.
func (r *orderRig) queue(t *testing.T, class, disc string) string {
	t.Helper()
	ctx := context.Background()
	at := r.t0.Add(time.Duration(r.n) * time.Minute)
	r.n++
	id := uuidV4()
	if _, _, err := r.e.st.PutFleetAsk(ctx, r.op, store.FleetAsk{Fleet: "main", AskID: id, Role: "orch", Kind: "task",
		From: "c-002@box-b", Topic: "dispatch-0000abcd", Discussion: disc, Summary: "SPAWN REQUEST " + class}, "box-b", at); err != nil {
		t.Fatal(err)
	}
	if _, err := r.e.st.UpdateFleetAsk(ctx, r.op, store.AskUpdate{Fleet: "main", AskID: id, Op: store.AskQueue,
		By: "c-001@sat", Class: class}, "sat", at); err != nil {
		t.Fatal(err)
	}
	return id
}

// list is op's queued orch asks in queue order.
func (r *orderRig) list(t *testing.T) []store.FleetAsk {
	t.Helper()
	as, err := r.e.st.ListFleetAsks(context.Background(), r.op, "main", "orch", false, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	out := make([]store.FleetAsk, 0, len(as))
	for _, a := range as {
		if a.State == "queued" {
			out = append(out, a)
		}
	}
	for i := range out {
		for j := i + 1; j < len(out); j++ {
			if out[j].Position < out[i].Position {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}

// snap is the queue's order, priorities and ranks as text.
func (r *orderRig) snap(t *testing.T) string {
	t.Helper()
	out := ""
	for _, a := range r.list(t) {
		out += fmt.Sprintf("%s:%d:%d:%d:%s ", a.AskID, a.Position, a.OwnPriority, a.QueueRank, a.RankBy)
	}
	return out
}

func (r *orderRig) row(t *testing.T, id string) store.FleetAsk {
	t.Helper()
	for _, a := range r.list(t) {
		if a.AskID == id {
			return a
		}
	}
	t.Fatalf("ask %s not queued", id)
	return store.FleetAsk{}
}

// order is the queue's ask ids, by the names given.
func (r *orderRig) order(t *testing.T, names map[string]string) string {
	t.Helper()
	out := []string{}
	for _, a := range r.list(t) {
		out = append(out, names[a.AskID])
	}
	return strings.Join(out, " ")
}

func (r *orderRig) prio(t *testing.T, as, id string, body any) (int, map[string]any) {
	t.Helper()
	return call(t, r.e, r.op, http.MethodPut, "/v1/operator/fleet-asks/"+id+"/priority", as, body)
}

func (r *orderRig) move(t *testing.T, as, id string, before, after any) (int, map[string]any) {
	t.Helper()
	return call(t, r.e, r.op, http.MethodPut, "/v1/operator/fleet-asks/"+id+"/position", as,
		map[string]any{"before": before, "after": after})
}

func (r *orderRig) setTopic(t *testing.T, task string, p int, at time.Time) {
	t.Helper()
	if _, err := r.e.st.(store.TopicPriorityStore).SetTopicPriority(context.Background(), r.op, task, p, "HUM-7", at); err != nil {
		t.Fatal(err)
	}
}

// C111: the effective priority. Own only 2; discussion only 4; both, the
// newer write; neither 3; each with its priority_source.
// RED CONTROL: askFillPriorities without its own-priority case -> "own only"
// reads 3 default.
func TestFleetAskEffectivePriority(t *testing.T) {
	r := newOrderRig(t)
	dOnly, dBoth, dOld := uuidV4(), uuidV4(), uuidV4()
	own, disc, both, bothOld, none := r.queue(t, "feature", ""), r.queue(t, "feature", dOnly), r.queue(t, "feature", dBoth),
		r.queue(t, "feature", dOld), r.queue(t, "feature", "")
	r.setTopic(t, dOnly, 4, time.Now().UTC().Add(-time.Minute))
	r.setTopic(t, dOld, 5, time.Now().UTC().Add(-time.Minute)) // older than its own set below
	for _, c := range []struct {
		id string
		p  int
	}{{own, 2}, {both, 1}, {bothOld, 2}} {
		if code, out := r.prio(t, r.admin, c.id, map[string]any{"priority": c.p}); code != http.StatusOK {
			t.Fatalf("PUT priority: %d %v", code, out)
		}
	}
	r.setTopic(t, dBoth, 4, time.Now().UTC().Add(time.Second)) // newer than its own 1
	for _, c := range []struct {
		name, id, src string
		want          int
	}{
		{"own only", own, store.AskPrioOwn, 2},
		{"discussion only", disc, store.AskPrioDiscussion, 4},
		{"both, the discussion newer", both, store.AskPrioDiscussion, 4},
		{"both, the own newer", bothOld, store.AskPrioOwn, 2},
		{"neither", none, store.AskPrioDefault, 3},
	} {
		a := r.row(t, c.id)
		if a.Priority != c.want || a.PrioritySource != c.src {
			t.Errorf("%s: priority %d (%s), want %d (%s)", c.name, a.Priority, a.PrioritySource, c.want, c.src)
		}
	}
}

// C112: the priority PUT. 1..5 stored with who; 0 and 6 are 400; a placed
// ask 409; a member 403; no such ask 404. RED on master: no route.
func TestFleetAskPriorityPut(t *testing.T) {
	r := newOrderRig(t)
	id, placed := r.queue(t, "bug", ""), r.queue(t, "bug", "")
	if _, err := r.e.st.UpdateFleetAsk(context.Background(), r.op, store.AskUpdate{Fleet: "main", AskID: placed, Op: store.AskDone,
		By: "c-001@sat", Reason: "placed: c-100@sat"}, "sat", time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, as, id string
		body         any
		want         int
	}{
		{"0", r.admin, id, map[string]any{"priority": 0}, http.StatusBadRequest},
		{"6", r.admin, id, map[string]any{"priority": 6}, http.StatusBadRequest},
		{"no body", r.admin, id, nil, http.StatusBadRequest},
		{"a member", r.dev, id, map[string]any{"priority": 1}, http.StatusForbidden},
		{"a placed ask", r.admin, placed, map[string]any{"priority": 1}, http.StatusConflict},
		{"no such ask", r.admin, uuidV4(), map[string]any{"priority": 1}, http.StatusNotFound},
	} {
		if code, out := r.prio(t, c.as, c.id, c.body); code != c.want {
			t.Errorf("%s: %d %v, want %d", c.name, code, out, c.want)
		}
	}
	if a := r.row(t, id); a.OwnPriority != 0 || a.Priority != 3 {
		t.Fatalf("a refused PUT stored %d (effective %d)", a.OwnPriority, a.Priority)
	}
	for p := 1; p <= 5; p++ {
		code, out := r.prio(t, r.admin, id, map[string]any{"priority": p})
		ask, _ := out["ask"].(map[string]any)
		if code != http.StatusOK || ask["priority"] != float64(p) || ask["priority_source"] != "own" || ask["priority_by"] != r.admin {
			t.Fatalf("priority %d: %d %v", p, code, out)
		}
		if a := r.row(t, id); a.OwnPriority != p || a.PriorityBy != r.admin || a.PriorityAt.IsZero() {
			t.Fatalf("priority %d stored as %d by %q at %v", p, a.OwnPriority, a.PriorityBy, a.PriorityAt)
		}
	}
	if !r.logged(t, "queue.priority_set", id) {
		t.Fatalf("the change is not in the operator workspace's log")
	}
}

// logged reports whether op's log holds a kind row naming id.
func (r *orderRig) logged(t *testing.T, kind, id string) bool {
	t.Helper()
	es, ok := r.e.st.(store.LogEvents)
	if !ok {
		return true
	}
	rows, err := es.WorkspaceEventsPage(context.Background(), r.op, 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range rows {
		if e.Kind == kind && strings.Contains(e.Message, id) && e.Actor == r.admin {
			return true
		}
	}
	return false
}

// C113 (H1 A, the copy): an ask of the operator workspace working for a
// topic of another workspace gets that topic's priority when the operator
// workspace's owner sets it there (SPL-5905 copies it into op), and reads
// it with the source discussion. RED CONTROL: drop the priorityToOperator
// call in handleTopicPriority -> the ask reads 3 (default).
func TestFleetAskOtherWorkspaceDiscussion(t *testing.T) {
	op := newTenantID("op")
	roles := tenantRoles{op: {"HUM-7": rbac.BizOwner}}
	e := archiveEnv(t, func(o *hub.Options) {
		o.OperatorTenant = op
		o.Authorizer = roles
	})
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	tid, _ := e.tenant()
	roles[tid] = map[string]string{"HUM-7": rbac.BizOwner}
	r := &orderRig{e: e, op: op, t0: time.Now().UTC().Add(-time.Hour)}
	task := uuidV4()
	other := r.queue(t, "bug", "")
	id := r.queue(t, "feature", task)
	putCard(t, e, tid, task, "", "HUM-2", hub.WUIBox, 1, time.Now().UTC().Add(-time.Hour))
	if code, out := putPriority(t, e, tid, task, "HUM-7", map[string]any{"priority": 1}); code != http.StatusOK {
		t.Fatalf("PUT topic priority: %d %v", code, out)
	}
	a := r.row(t, id)
	if a.Priority != 1 || a.PrioritySource != store.AskPrioDiscussion || a.Position != 1 {
		t.Fatalf("the ask reads priority %d (%s) at %d, want 1 (discussion) at 1", a.Priority, a.PrioritySource, a.Position)
	}
	if b := r.row(t, other); b.Position != 2 {
		t.Fatalf("the other ask is at %d, want 2", b.Position)
	}
}

// C115: rows A B C D, no rank; D dropped between A and B: A D B C, A ranked
// with no rank_by, D ranked by the admin, B and C unranked. RED: no route.
func TestFleetAskMove(t *testing.T) {
	r := newOrderRig(t)
	ids := map[string]string{}
	names := map[string]string{}
	for _, n := range []string{"A", "B", "C", "D"} {
		ids[n] = r.queue(t, "feature", "")
		names[ids[n]] = n
	}
	if got := r.order(t, names); got != "A B C D" {
		t.Fatalf("before: %s", got)
	}
	code, out := r.move(t, r.admin, ids["D"], ids["A"], ids["B"])
	if code != http.StatusOK {
		t.Fatalf("move: %d %v", code, out)
	}
	if ask, _ := out["ask"].(map[string]any); ask["position"] != float64(2) || ask["rank_by"] != r.admin {
		t.Fatalf("move answer: %v", out)
	}
	if got := r.order(t, names); got != "A D B C" {
		t.Fatalf("after: %s, want A D B C", got)
	}
	a, d, b, c := r.row(t, ids["A"]), r.row(t, ids["D"]), r.row(t, ids["B"]), r.row(t, ids["C"])
	switch {
	case a.QueueRank == 0 || a.RankBy != "":
		t.Fatalf("A: rank %d by %q, want a rank and no rank_by", a.QueueRank, a.RankBy)
	case d.QueueRank <= a.QueueRank || d.RankBy != r.admin:
		t.Fatalf("D: rank %d by %q (A %d)", d.QueueRank, d.RankBy, a.QueueRank)
	case b.QueueRank != 0 || c.QueueRank != 0:
		t.Fatalf("B, C ranked %d, %d", b.QueueRank, c.QueueRank)
	case d.Priority != 3 || d.PrioritySource != store.AskPrioOwn:
		t.Fatalf("D: priority %d (%s)", d.Priority, d.PrioritySource)
	}
	if !r.logged(t, "queue.position_set", ids["D"]) {
		t.Fatalf("the move is not in the operator workspace's log")
	}
	// to the top and to the bottom; the order holds on a second read
	for _, s := range []struct {
		id            string
		before, after any
		want          string
	}{{ids["C"], nil, ids["A"], "C A D B"}, {ids["A"], ids["B"], nil, "C D B A"}} {
		if code, out := r.move(t, r.admin, s.id, s.before, s.after); code != http.StatusOK {
			t.Fatalf("move %s: %d %v", names[s.id], code, out)
		}
		if got := r.order(t, names); got != s.want {
			t.Fatalf("after moving %s: %s, want %s", names[s.id], got, s.want)
		}
	}
}

// C116: a priority 4 row dropped directly above a priority 2 row reads 2,
// source own, and sits above it. RED CONTROL: drop the moved row's priority
// write in askPlanMove -> it snaps back below on the read.
func TestFleetAskMoveAcrossALine(t *testing.T) {
	r := newOrderRig(t)
	hi, lo := r.queue(t, "feature", ""), r.queue(t, "feature", "")
	for id, p := range map[string]int{hi: 2, lo: 4} {
		if code, out := r.prio(t, r.admin, id, map[string]any{"priority": p}); code != http.StatusOK {
			t.Fatalf("prio: %d %v", code, out)
		}
	}
	if code, out := r.move(t, r.admin, lo, nil, hi); code != http.StatusOK {
		t.Fatalf("move: %d %v", code, out)
	}
	a := r.row(t, lo)
	if a.Priority != 2 || a.PrioritySource != store.AskPrioOwn || a.Position != 1 {
		t.Fatalf("dropped row: priority %d (%s) at %d, want 2 (own) at 1", a.Priority, a.PrioritySource, a.Position)
	}
}

// C117: a stale neighbour is 409 stale_position and changes nothing; a bad
// body is 400; a member 403. Then moves at once, every one answered 200 or
// 409, end in a valid order: each priority's ranks distinct. On Postgres the
// role's queued rows are locked FOR UPDATE. RED CONTROL (Postgres): drop the
// FOR UPDATE in pgAskLockQueue -> two moves read the same line and write
// the same rank.
func TestFleetAskMoveStaleAndRace(t *testing.T) {
	r := newOrderRig(t)
	ids := []string{}
	for i := 0; i < 8; i++ {
		ids = append(ids, r.queue(t, "feature", ""))
	}
	before := r.snap(t)
	for _, c := range []struct {
		name, as      string
		before, after any
		want          int
	}{
		{"not adjacent", r.admin, ids[0], ids[2], http.StatusConflict},
		{"a neighbour not queued", r.admin, uuidV4(), nil, http.StatusConflict},
		{"both null in a line of 8", r.admin, nil, nil, http.StatusConflict},
		{"its own neighbour", r.admin, ids[7], nil, http.StatusBadRequest},
		{"not an id", r.admin, "x", nil, http.StatusBadRequest},
		{"a member", r.dev, ids[0], ids[1], http.StatusForbidden},
	} {
		code, out := r.move(t, c.as, ids[7], c.before, c.after)
		if code != c.want || (c.want == http.StatusConflict && out["error"] != "stale_position") {
			t.Errorf("%s: %d %v, want %d", c.name, code, out, c.want)
		}
	}
	if after := r.snap(t); after != before {
		t.Fatalf("a refused move changed the queue")
	}
	var wg sync.WaitGroup
	codes := make([]int, 6)
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			codes[i], _ = r.move(t, r.admin, ids[7-i%3], ids[i%3], ids[i%3+1])
		}(i)
	}
	wg.Wait()
	ok := 0
	for i, c := range codes {
		if c != http.StatusOK && c != http.StatusConflict {
			t.Fatalf("move %d: %d", i, c)
		}
		if c == http.StatusOK {
			ok++
		}
	}
	if ok == 0 {
		t.Fatalf("no move of the race won")
	}
	seen := map[[2]int64]string{}
	for _, a := range r.list(t) {
		if a.QueueRank == 0 {
			continue
		}
		k := [2]int64{int64(a.Priority), a.QueueRank}
		if o, dup := seen[k]; dup {
			t.Fatalf("asks %s and %s share rank %d at priority %d", o, a.AskID, a.QueueRank, a.Priority)
		}
		seen[k] = a.AskID
	}
}

// C118: a new arrival of the same priority lands after the ranked rows; a
// higher one ahead of them; a stall back in line keeps its rank; a priority
// change clears it (its own, and its discussion's newer set). RED: no ranks
// (askBefore without the rank step) -> the arrival orders by class/time.
func TestFleetAskRankAgainstArrivals(t *testing.T) {
	r := newOrderRig(t)
	disc := uuidV4()
	a, b, c := r.queue(t, "refactor", ""), r.queue(t, "feature", disc), r.queue(t, "feature", "")
	names := map[string]string{a: "A", b: "B", c: "C"}
	// C to the top: C and A... C ranked first, A unranked behind it
	if code, out := r.move(t, r.admin, c, nil, a); code != http.StatusOK {
		t.Fatalf("move: %d %v", code, out)
	}
	if code, out := r.move(t, r.admin, b, c, a); code != http.StatusOK {
		t.Fatalf("move: %d %v", code, out)
	}
	if got := r.order(t, names); got != "C B A" {
		t.Fatalf("after the moves: %s, want C B A", got)
	}
	n := r.queue(t, "refactor", "") // after the ranked rows (and, at 3, no class jump: spec 150 B15a)
	names[n] = "N"
	if got := r.order(t, names); got != "C B A N" {
		t.Fatalf("a same-priority arrival: %s, want C B A N", got)
	}
	h := r.queue(t, "feature", "")
	names[h] = "H"
	if code, out := r.prio(t, r.admin, h, map[string]any{"priority": 1}); code != http.StatusOK {
		t.Fatalf("prio: %d %v", code, out)
	}
	if got := r.order(t, names); got != "H C B A N" {
		t.Fatalf("a higher arrival: %s, want H C B A N", got)
	}
	ctx := context.Background()
	for _, op := range []string{store.AskAck, store.AskQueue} { // a stalled placement back in line
		if _, err := r.e.st.UpdateFleetAsk(ctx, r.op, store.AskUpdate{Fleet: "main", AskID: c, Op: op, By: "c-001@sat"}, "sat", time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if got, cr := r.order(t, names), r.row(t, c); got != "H C B A N" || cr.QueueRank == 0 || cr.RankBy != r.admin {
		t.Fatalf("a stall back in line: %s, C rank %d by %q", got, cr.QueueRank, cr.RankBy)
	}
	if code, out := r.prio(t, r.admin, c, map[string]any{"priority": 3}); code != http.StatusOK {
		t.Fatalf("prio: %d %v", code, out)
	}
	if cr := r.row(t, c); cr.QueueRank != 0 || cr.RankBy != "" {
		t.Fatalf("its own priority set kept the rank %d by %q", cr.QueueRank, cr.RankBy)
	}
	r.setTopic(t, disc, 3, time.Now().UTC().Add(time.Second))
	if br := r.row(t, b); br.QueueRank != 0 || br.PrioritySource != store.AskPrioDiscussion {
		t.Fatalf("its discussion's newer set kept the rank %d (%s)", br.QueueRank, br.PrioritySource)
	}
	if got := r.order(t, names); got != "H A B C N" { // Q6 = A: queue order inside 3, N no longer jumps by class
		t.Fatalf("after the clears: %s, want H A B C N", got)
	}
}

// C121 (H3 A): a ci row at no priority is position 1 ahead of a priority 1
// feature. RED on master: priority first puts the feature ahead.
func TestFleetAskCIFirst(t *testing.T) {
	r := newOrderRig(t)
	f := r.queue(t, "feature", "")
	ci := r.queue(t, "ci", "")
	if code, out := r.prio(t, r.admin, f, map[string]any{"priority": 1}); code != http.StatusOK {
		t.Fatalf("prio: %d %v", code, out)
	}
	if a := r.row(t, ci); a.Position != 1 || a.Priority != 3 {
		t.Fatalf("the ci row is at %d (priority %d), want 1 (its own 3)", a.Position, a.Priority)
	}
}

// R7 W1: a ci row is always priority 1 (askPrio), so a drag that drops it
// at a slot of another priority (above a priority 3 feature: the moved row
// takes the priority of the row below it) cannot place it there. It is
// refused 409 ci_first and changes nothing; a drag between two priority 1
// rows still works. RED on 49e47aa76: 200, the ci row
// unmoved and the rank and rank_by written onto a feature nobody dragged.
func TestFleetAskMoveCIOutOfItsPriority(t *testing.T) {
	r := newOrderRig(t)
	f1, f2 := r.queue(t, "feature", ""), r.queue(t, "feature", "")
	ci := r.queue(t, "ci", "")
	names := map[string]string{f1: "F1", f2: "F2", ci: "CI"}
	before := r.snap(t)
	code, out := r.move(t, r.admin, ci, f1, f2)
	if code != http.StatusConflict || out["error"] != "ci_first" {
		t.Fatalf("ci row between two priority 3 rows: %d %v, want 409 ci_first", code, out)
	}
	if after := r.snap(t); after != before {
		t.Fatalf("a refused ci move changed the queue:\n%s\n%s", before, after)
	}
	for _, f := range []string{f1, f2} {
		if code, out := r.prio(t, r.admin, f, map[string]any{"priority": 1}); code != http.StatusOK {
			t.Fatalf("prio: %d %v", code, out)
		}
	}
	if code, out := r.move(t, r.admin, ci, f1, f2); code != http.StatusOK {
		t.Fatalf("ci row below a priority 1 row: %d %v, want 200", code, out)
	}
	if got := r.order(t, names); got != "F1 CI F2" {
		t.Fatalf("order %q, want F1 CI F2", got)
	}
	if a := r.row(t, ci); a.QueueRank == 0 || a.RankBy == "" {
		t.Fatalf("the moved ci row: rank %d by %q, want its own drag", a.QueueRank, a.RankBy)
	}
}

// ask_op position: the dispatch holder's move on the owner's word records
// "<by> msg <owner msg id>" in rank_by; with no owner msg it is refused.
// RED: no op (the default branch refuses "position" as an unknown ask_op).
func TestFleetAskOpPosition(t *testing.T) {
	r := newOrderRig(t)
	a, b := r.queue(t, "feature", ""), r.queue(t, "feature", "")
	msg := uuidV4()
	send := func(body map[string]any) (map[string]any, error) {
		raw, _ := json.Marshal(body)
		out, err := r.b.c.Ask(context.Background(), "position", "main", raw)
		got := map[string]any{}
		json.Unmarshal(out, &got) //nolint:errcheck
		return got, err
	}
	if _, err := send(map[string]any{"ask_id": b, "by": "c-002", "after": a}); err == nil {
		t.Fatalf("a move with no owner_msg was taken")
	}
	if out, err := send(map[string]any{"ask_id": b, "by": "c-002", "after": a, "owner_msg": msg}); err != nil {
		t.Fatalf("ask_op position: %v %v", err, out)
	}
	got := r.row(t, b)
	if got.Position != 1 || got.RankBy != "c-002@box-b msg "+msg {
		t.Fatalf("moved row at %d, rank_by %q", got.Position, got.RankBy)
	}
}
