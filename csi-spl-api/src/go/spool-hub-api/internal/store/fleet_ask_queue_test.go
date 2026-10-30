package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// rdb 0180 (owner HUM-10, t1 c9beaa77): a spawn request waits in a queue.
// queue takes an open ask to queued with enqueued_at and a position; the
// placer acks the head (placing), and either closes it done or, when the
// placement stalled, queues it again at the SAME place (enqueued_at is set
// once). Every later ask moves up when the head leaves. A queued ask stays in
// the open list whatever its age, and another tenant neither sees nor queues
// it. Run on Memory and Postgres.
func TestFleetAskQueue(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 12, 2, 0, 0, 0, time.UTC)
	const (
		a1 = "a1a1a1a1-0000-4000-8000-000000000001"
		a2 = "a2a2a2a2-0000-4000-8000-000000000002"
		a3 = "a3a3a3a3-0000-4000-8000-000000000003"
	)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			other := newTenant(t, st)
			for i, id := range []string{a1, a2, a3} {
				if _, _, err := st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: id, Role: "orch", Kind: "task", From: "c-002@box-b",
					Summary: "SPAWN REQUEST lane " + id[:2]}, "box-b", t0.Add(time.Duration(i)*time.Minute)); err != nil {
					t.Fatal(err)
				}
			}
			upd := func(id, op, place string, at time.Time) (FleetAsk, error) {
				u := AskUpdate{Fleet: "main", AskID: id, Op: op, By: "c-001@sat", Placement: place}
				if op == AskQueue {
					u.Class = "bug"
				}
				return st.UpdateFleetAsk(ctx, tid, u, "sat", at)
			}
			queue := func(at time.Time) map[string]FleetAsk {
				t.Helper()
				as, err := st.ListFleetAsks(ctx, tid, "main", "orch", false, at)
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]FleetAsk{}
				for _, a := range as {
					out[a.AskID] = a
				}
				return out
			}

			// a2 is queued first, then a1: the position is the queue's order, not the ask's age
			got, err := upd(a2, AskQueue, "claude:hub-pg-split", t0.Add(10*time.Minute))
			if err != nil || got.State != "queued" || !got.EnqueuedAt.Equal(t0.Add(10*time.Minute)) || got.Placement != "claude:hub-pg-split" || !got.Open() {
				t.Fatalf("queue a2: %+v %v", got, err)
			}
			if _, err = upd(a1, AskQueue, "", t0.Add(11*time.Minute)); err != nil {
				t.Fatal(err)
			}
			q := queue(t0.Add(12 * time.Minute))
			if q[a2].Position != 1 || q[a1].Position != 2 || q[a2].QueueLen != 2 || q[a3].Position != 0 || q[a3].State != "open" {
				t.Fatalf("positions: a2 %+v a1 %+v a3 %+v", q[a2], q[a1], q[a3])
			}
			// a day later a queued ask is still in the open list, still queued
			if q = queue(t0.Add(26 * time.Hour)); q[a2].State != "queued" || q[a1].State != "queued" || q[a1].Age < 24*time.Hour {
				t.Fatalf("a queued ask ages in place: %+v", q)
			}

			// the placer takes the head: a2 placing, a1 moves up to 1 of 1
			if got, err = upd(a2, AskAck, "", t0.Add(20*time.Minute)); err != nil || got.State != "acked" || got.EnqueuedAt.IsZero() {
				t.Fatalf("placing: %+v %v", got, err)
			}
			if q = queue(t0.Add(21 * time.Minute)); q[a1].Position != 1 || q[a1].QueueLen != 1 || q[a2].Position != 0 {
				t.Fatalf("head left: a1 %+v a2 %+v", q[a1], q[a2])
			}
			// the placement stalled: queued again, back at the head, placement kept
			if got, err = upd(a2, AskQueue, "", t0.Add(50*time.Minute)); err != nil || !got.EnqueuedAt.Equal(t0.Add(10*time.Minute)) || got.Placement != "claude:hub-pg-split" {
				t.Fatalf("re-queue: %+v %v", got, err)
			}
			if q = queue(t0.Add(51 * time.Minute)); q[a2].Position != 1 || q[a1].Position != 2 {
				t.Fatalf("a stalled placement keeps its place: a2 %+v a1 %+v", q[a2], q[a1])
			}
			// placed: done with the agent id, a1 is next
			if _, err = upd(a2, AskAck, "", t0.Add(52*time.Minute)); err != nil {
				t.Fatal(err)
			}
			got, err = st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: a2, Op: AskDone, By: "c-001@sat", Reason: "placed: c-281@box-b"}, "sat", t0.Add(53*time.Minute))
			if err != nil || got.State != "done" || got.Reason != "placed: c-281@box-b" {
				t.Fatalf("placed: %+v %v", got, err)
			}
			if q = queue(t0.Add(54 * time.Minute)); q[a1].Position != 1 || q[a1].QueueLen != 1 {
				t.Fatalf("next: %+v", q[a1])
			}
			if _, err = upd(a2, AskQueue, "", t0.Add(55*time.Minute)); !errors.Is(err, ErrConflict) {
				t.Fatalf("a placed ask is not queued again: %v", err)
			}

			// another tenant: no rows, no queue op
			if as, _ := st.ListFleetAsks(ctx, other, "main", "", true, t0.Add(time.Hour)); len(as) != 0 {
				t.Fatalf("other tenant sees the queue: %+v", as)
			}
			if _, err := st.UpdateFleetAsk(ctx, other, AskUpdate{Fleet: "main", AskID: a1, Op: AskQueue, By: "c-001", Class: "bug"}, "x", t0.Add(time.Hour)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("other tenant queues an ask: %v", err)
			}
		})
	}
}

// rdb 0195 (SPL-1817, owner HUM-10 t1 3209f8b8 msg 8cb6cc7d): the queue
// orders by class, ci, a flagged row (urgent bug, bypass feature), refactor,
// bug, feature, and only then by enqueued_at. CONTROL: the rows are queued
// oldest-feature-first, so today's FIFO would put the feature at 1. A queue
// op with no class (none stored) is ErrAskClass, a re-queue with none keeps
// the stored one, and a flag its class does not take is refused. The bypass
// records who set it and when. Run on Memory and Postgres.
func TestFleetAskQueueClassOrder(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 14, 8, 0, 0, 0, time.UTC)
	const owner = "8cb6cc7d-7628-4ac3-be00-86e427bb3487"
	ids := map[string]string{
		"feature": "f0f0f0f0-0000-4000-8000-000000000001", "bug": "b0b0b0b0-0000-4000-8000-000000000002",
		"refactor": "a0a0a0a0-0000-4000-8000-000000000003", "ci": "c0c0c0c0-0000-4000-8000-000000000004",
		"bypass": "e0e0e0e0-0000-4000-8000-000000000005", "none": "d0d0d0d0-0000-4000-8000-000000000006",
	}
	order := []string{"feature", "bug", "refactor", "ci", "bypass", "none"}
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			for i, k := range order {
				if _, _, err := st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: ids[k], Role: "orch", Kind: "task", From: "c-002@box-b",
					Summary: "SPAWN REQUEST " + k}, "box-b", t0.Add(time.Duration(i)*time.Minute)); err != nil {
					t.Fatal(err)
				}
			}
			q := func(k string, u AskUpdate, at time.Time) (FleetAsk, error) {
				u.Fleet, u.AskID, u.Op, u.By = "main", ids[k], AskQueue, "c-001@sat"
				return st.UpdateFleetAsk(ctx, tid, u, "sat", at)
			}
			if got, err := q("none", AskUpdate{}, t0.Add(9*time.Minute)); !errors.Is(err, ErrAskClass) || got.State != "open" {
				t.Fatalf("a queue with no class: %+v %v", got, err)
			}
			if _, err := q("bug", AskUpdate{Class: "bug", Flag: "bypass", FlagMsg: owner}, t0.Add(9*time.Minute)); !errors.Is(err, ErrAskClass) {
				t.Fatalf("a bypass on a bug: %v", err)
			}
			for i, k := range []string{"feature", "bug", "refactor", "ci", "bypass"} {
				u := AskUpdate{Class: k}
				if k == "bypass" {
					u = AskUpdate{Class: "feature", Flag: "bypass", FlagMsg: owner}
				}
				if _, err := q(k, u, t0.Add(time.Duration(10+i)*time.Minute)); err != nil {
					t.Fatalf("queue %s: %v", k, err)
				}
			}
			pos := func() map[string]FleetAsk {
				t.Helper()
				as, err := st.ListFleetAsks(ctx, tid, "main", "orch", false, t0.Add(time.Hour))
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]FleetAsk{}
				for k, id := range ids {
					for _, a := range as {
						if a.AskID == id {
							out[k] = a
						}
					}
				}
				return out
			}
			p := pos()
			for k, want := range map[string]int{"ci": 1, "bypass": 2, "refactor": 3, "bug": 4, "feature": 5, "none": 0} {
				if p[k].Position != want {
					t.Fatalf("%s at %d, want %d (FIFO would be feature first): %+v", k, p[k].Position, want, p)
				}
			}
			if b := p["bypass"]; b.Class != "feature" || b.Flag != "bypass" || b.FlagMsg != owner || b.FlagBy != "c-001@sat" || !b.FlagAt.Equal(t0.Add(14*time.Minute)) {
				t.Fatalf("the bypass record: %+v", b)
			}
			// the placer's stalled re-queue sends no class: the stored one stays
			if _, err := st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: ids["refactor"], Op: AskAck, By: "c-001@sat"}, "sat", t0.Add(time.Hour)); err != nil {
				t.Fatal(err)
			}
			if got, err := q("refactor", AskUpdate{}, t0.Add(2*time.Hour)); err != nil || got.Class != "refactor" {
				t.Fatalf("re-queue keeps the class: %+v %v", got, err)
			}
			if p = pos(); p["refactor"].Position != 3 {
				t.Fatalf("re-queued refactor at %d", p["refactor"].Position)
			}
		})
	}
}

func TestCheckAskClass(t *testing.T) {
	const m = "8cb6cc7d-7628-4ac3-be00-86e427bb3487"
	for _, c := range [][3]string{{"", "", ""}, {"ci", "", ""}, {"refactor", "", ""}, {"bug", "urgent", ""}, {"feature", "bypass", m}} {
		if why := CheckAskClass(c[0], c[1], c[2]); why != "" {
			t.Fatalf("%v refused: %s", c, why)
		}
	}
	for _, c := range [][3]string{{"chore", "", ""}, {"Bug", "", ""}, {"feature", "fast", ""}, {"feature", "bypass", ""}, {"feature", "bypass", "8cb6cc7d"}, {"bug", "", m}} {
		if CheckAskClass(c[0], c[1], c[2]) == "" {
			t.Fatalf("%v accepted", c)
		}
	}
}

func TestCheckFleetAskQueue(t *testing.T) {
	if why := CheckFleetAskOp(AskQueue, "c-001@sat", ""); why != "" {
		t.Fatalf("queue refused: %s", why)
	}
	for _, p := range []string{"", "claude:hub-pg-split", "mistral:perf5-m1", "grok:a.b_c"} {
		if !AskPlacementRe.MatchString(p) {
			t.Fatalf("placement %q refused", p)
		}
	}
	for _, p := range []string{"claude", "Claude:x", "claude:", "claude:-x", "claude:x y", "claude:x;rm"} {
		if AskPlacementRe.MatchString(p) {
			t.Fatalf("placement %q accepted", p)
		}
	}
}

// Spec 150 row B9 (rdb 0241, SPL-4193; owner HUM-10 prd t1 0344254d, poll Q5
// answer A: "priority first: a priority 1 feature goes before a priority 3
// bug"). The queue ranks by the discussion's priority (rdb 0214, none = 3,
// the owner's default, msg f5ed1396, SPL-4367),
// then by class, then by enqueued_at. Run on Memory and Postgres.
//
//   - C401: of two queued bugs, the one whose discussion is priority 1 is
//     position 1 although it was queued later. CONTROL: the rank ignores
//     priority (FIFO puts the older bug first).
//   - C402: asks with no discussion, or a discussion nobody set, keep the
//     class, then enqueued_at order at 3: after a priority 2 bug, before a
//     priority 4 ci row. CONTROL: a default that ranks first, or the old 5.
//   - C403: a priority 1 feature goes before a priority 2 bug, and both before
//     a ci row nobody gave a priority. CONTROL: class first (poll Q5 B) puts
//     the ci row, then the bug, first.
func TestFleetAskQueuePriority(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 29, 8, 0, 0, 0, time.UTC)
	const (
		dP1    = "0344254d-90fa-4341-989e-ec3675da3741" // a discussion set to 1
		dP2    = "0344254d-90fa-4341-989e-ec3675da3742" // a discussion set to 2
		dP4    = "0344254d-90fa-4341-989e-ec3675da3744" // a discussion set to 4
		dUnset = "0344254d-90fa-4341-989e-ec3675da3745" // a discussion nobody set
	)
	type row struct{ key, class, disc string }
	rows := []row{ // queued in this order, one minute apart
		{"bugOld", "bug", ""}, {"ciNone", "ci", ""}, {"refUnset", "refactor", dUnset},
		{"bugP2", "bug", dP2}, {"featP1", "feature", dP1}, {"bugP1", "bug", dP1}, {"featNone", "feature", ""}, {"ciP4", "ci", dP4},
	}
	ids := map[string]string{}
	for i, r := range rows {
		ids[r.key] = "b9b9b9b9-0000-4000-8000-00000000000" + string(rune('1'+i))
	}
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			for p, d := range map[int]string{1: dP1, 2: dP2, 4: dP4} {
				if _, err := st.(TopicPriorityStore).SetTopicPriority(ctx, tid, d, p, "HUM-10", t0); err != nil {
					t.Fatal(err)
				}
			}
			for i, r := range rows {
				at := t0.Add(time.Duration(i) * time.Minute)
				got, _, err := st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: ids[r.key], Role: "orch", Kind: "task", From: "c-002@box-b",
					Topic: "dispatch-0344254d", Discussion: r.disc, Summary: "SPAWN REQUEST " + r.key}, "box-b", at)
				if err != nil || got.Discussion != r.disc {
					t.Fatalf("put %s: discussion %q, want %q: %v", r.key, got.Discussion, r.disc, err)
				}
				if _, err := st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: ids[r.key], Op: AskQueue, By: "c-001@sat", Class: r.class}, "sat", at); err != nil {
					t.Fatalf("queue %s: %v", r.key, err)
				}
			}
			as, err := st.ListFleetAsks(ctx, tid, "main", "orch", false, t0.Add(time.Hour))
			if err != nil {
				t.Fatal(err)
			}
			got := map[string]FleetAsk{}
			for k, id := range ids {
				for _, a := range as {
					if a.AskID == id {
						got[k] = a
					}
				}
			}
			want := map[string][2]int{ // position, priority
				"bugP1": {1, 1}, "featP1": {2, 1}, // C401: the priority 1 bug before the older bugs; the class orders within 1
				"bugP2":  {3, 2},                                                           // C403: a priority 2 bug after the priority 1 feature
				"ciNone": {4, 3}, "refUnset": {5, 3}, "bugOld": {6, 3}, "featNone": {7, 3}, // C402: the class order at the unset 3, after a 2 (SPL-4367)
				"ciP4": {8, 4}, // a priority 4 ci row after every unset ask: unset is 3, not 5 (msg f5ed1396)
			}
			for k, w := range want {
				if got[k].Position != w[0] || got[k].Priority != w[1] || got[k].QueueLen != len(rows) {
					t.Errorf("%s at %d priority %d, want %d priority %d", k, got[k].Position, got[k].Priority, w[0], w[1])
				}
			}
			// another tenant's priority on the same topic id moves nothing here
			other := newTenant(t, st)
			if _, err := st.(TopicPriorityStore).SetTopicPriority(ctx, other, dUnset, 1, "HUM-10", t0); err != nil {
				t.Fatal(err)
			}
			if as, _ = st.ListFleetAsks(ctx, tid, "main", "orch", false, t0.Add(time.Hour)); len(as) == 0 {
				t.Fatal("empty list")
			}
			for _, a := range as {
				if a.AskID == ids["refUnset"] && (a.Priority != unsetTopicPriority || a.Position != 5) {
					t.Fatalf("another workspace's priority leaked: %+v", a)
				}
			}
		})
	}
}

func TestCheckFleetAskDiscussion(t *testing.T) {
	a := FleetAsk{Fleet: "main", AskID: "b9b9b9b9-0000-4000-8000-000000000001", Role: "orch", Kind: "task", From: "c-002", Topic: "dispatch-0344254d"}
	for _, d := range []string{"", "0344254d-90fa-4341-989e-ec3675da374d"} {
		if a.Discussion = d; CheckFleetAsk(a) != "" {
			t.Fatalf("discussion %q refused: %s", d, CheckFleetAsk(a))
		}
	}
	for _, d := range []string{"0344254d", "0344254D-90FA-4341-989E-EC3675DA374D", "dispatch-0344254d", "not a uuid"} {
		if a.Discussion = d; CheckFleetAsk(a) == "" {
			t.Fatalf("discussion %q accepted", d)
		}
	}
}
