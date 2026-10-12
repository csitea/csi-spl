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
				return st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: id, Op: op, By: "c-001@sat", Placement: place}, "sat", at)
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
			if _, err := st.UpdateFleetAsk(ctx, other, AskUpdate{Fleet: "main", AskID: a1, Op: AskQueue, By: "c-001"}, "x", t0.Add(time.Hour)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("other tenant queues an ask: %v", err)
			}
		})
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
