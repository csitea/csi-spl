package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// CLE-77929 (rdb 0097): asks to the orchestrator. A put is idempotent on the
// msg id; ack, raise and escalate keep the ask open; done / decline close it
// once (the second closer gets ErrConflict and the first closer's row); the
// open list leads with the longest wait; a closed ask is pruned a week after
// its last write; another tenant sees none of it. Run on Memory and Postgres.
func TestFleetAskLifecycle(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 2, 1, 51, 0, 0, time.UTC)
	const (
		a1 = "39451306-8830-4e8e-878c-eb29f2803839"
		a2 = "7b7f6e64-4e75-4f49-b85e-d1a9d755fa5f"
	)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			other := newTenant(t, st)

			if as, err := st.ListFleetAsks(ctx, tid, "main", "orch", false, t0); err != nil || len(as) != 0 {
				t.Fatalf("empty book: %+v %v", as, err)
			}
			ask := FleetAsk{Fleet: "main", AskID: a1, Role: "orch", Kind: "blocker", From: "CLE-002@box-desk", Topic: "692aefe8",
				Summary: "no lane for 6 h", DeadlineAt: t0.Add(30 * time.Minute)}
			got, created, err := st.PutFleetAsk(ctx, tid, ask, "box-desk", t0)
			if err != nil || !created || got.State != "open" || got.WriterBox != "box-desk" || !got.DeadlineAt.Equal(t0.Add(30*time.Minute)) {
				t.Fatalf("put: %+v %v %v", got, created, err)
			}
			// a replay (journal sync, a retried send) changes nothing
			ask.Summary = "changed"
			if got, created, err = st.PutFleetAsk(ctx, tid, ask, "sat", t0.Add(time.Minute)); err != nil || created || got.Summary != "no lane for 6 h" || got.WriterBox != "box-desk" {
				t.Fatalf("replay: %+v %v %v", got, created, err)
			}
			// an older ask from another sender sorts first: the longest wait leads
			if _, _, err = st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: a2, Role: "orch", Kind: "task", From: "CLE-002"}, "box-desk", t0.Add(-6*time.Hour)); err != nil {
				t.Fatal(err)
			}
			as, err := st.ListFleetAsks(ctx, tid, "main", "orch", false, t0.Add(2*time.Minute))
			if err != nil || len(as) != 2 || as[0].AskID != a2 || as[1].Age != 2*time.Minute || as[1].Quiet != 2*time.Minute {
				t.Fatalf("list order / age: %+v %v", as, err)
			}

			// another role is another topic: a dispatch ask is not in orch's list
			const a3 = "22222222-2222-4222-8222-222222222222"
			if _, _, err = st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: a3, Role: "dispatch", Kind: "task", From: "CLE-001"}, "box-desk", t0); err != nil {
				t.Fatal(err)
			}
			if as, _ := st.ListFleetAsks(ctx, tid, "main", "dispatch", false, t0); len(as) != 1 || as[0].AskID != a3 || as[0].Role != "dispatch" {
				t.Fatalf("dispatch topic: %+v", as)
			}
			if as, _ := st.ListFleetAsks(ctx, tid, "main", "", false, t0.Add(2*time.Minute)); len(as) != 3 {
				t.Fatalf("every role: %+v", as)
			}
			if _, err = st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: a3, Op: AskDone, By: "CLE-002"}, "box-desk", t0); err != nil {
				t.Fatal(err)
			}

			// the tick re-raises: still open, quiet restarts, raised_n counts
			got, err = st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: a1, Op: AskRaise, By: "CLE-001@box-desk", Reason: ""}, "box-desk", t0.Add(10*time.Minute))
			if err != nil || got.State != "open" || got.RaisedN != 1 || got.Quiet != 0 {
				t.Fatalf("raise: %+v %v", got, err)
			}
			if got, err = st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: a1, Op: AskEscalate, By: "CLE-001@box-desk", Reason: ""}, "box-desk", t0.Add(11*time.Minute)); err != nil || got.EscalatedAt.IsZero() {
				t.Fatalf("escalate: %+v %v", got, err)
			}
			if got, err = st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: a1, Op: AskAck, By: "CLE-001@sat", Reason: ""}, "sat", t0.Add(12*time.Minute)); err != nil || got.State != "acked" || got.AckedBy != "CLE-001@sat" {
				t.Fatalf("ack: %+v %v", got, err)
			}
			if got, err = st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: a1, Op: AskDone, By: "CLE-001@sat", Reason: "given to CLE-77915"}, "sat", t0.Add(13*time.Minute)); err != nil || got.State != "done" || got.Reason != "given to CLE-77915" {
				t.Fatalf("done: %+v %v", got, err)
			}
			// a second closer learns who closed it
			got, err = st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: a1, Op: AskDecline, By: "CLE-001@box-desk", Reason: "dup"}, "box-desk", t0.Add(14*time.Minute))
			if !errors.Is(err, ErrConflict) || got.ClosedBy != "CLE-001@sat" || got.State != "done" {
				t.Fatalf("second close: %+v %v", got, err)
			}
			if _, err = st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: "00000000-0000-4000-8000-000000000000", Op: AskAck, By: "CLE-001", Reason: ""}, "sat", t0); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown ask: %v", err)
			}

			if as, _ = st.ListFleetAsks(ctx, tid, "main", "orch", false, t0.Add(15*time.Minute)); len(as) != 1 || as[0].AskID != a2 {
				t.Fatalf("open list drops the closed ask: %+v", as)
			}
			if as, _ = st.ListFleetAsks(ctx, tid, "main", "orch", true, t0.Add(15*time.Minute)); len(as) != 2 || as[0].AskID != a2 || as[1].State != "done" {
				t.Fatalf("all: open first, then closed: %+v", as)
			}

			// a week later a write prunes the closed ask, never an open one
			later := t0.Add(AskClosedTTL + 20*time.Minute)
			if _, _, err = st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: "11111111-1111-4111-8111-111111111111", Role: "orch", Kind: "escalation", From: "CLE-3"}, "box-desk", later); err != nil {
				t.Fatal(err)
			}
			as, _ = st.ListFleetAsks(ctx, tid, "main", "orch", true, later)
			ids := map[string]bool{}
			for _, a := range as {
				ids[a.AskID] = true
			}
			if len(as) != 2 || ids[a1] || !ids[a2] {
				t.Fatalf("prune: %+v", as)
			}

			if as, _ := st.ListFleetAsks(ctx, tid, "other", "", true, later); len(as) != 0 {
				t.Fatalf("other fleet sees asks: %+v", as)
			}
			if as, _ := st.ListFleetAsks(ctx, other, "main", "", true, later); len(as) != 0 {
				t.Fatalf("other tenant sees asks: %+v", as)
			}
			if _, err := st.UpdateFleetAsk(ctx, other, AskUpdate{Fleet: "main", AskID: a2, Op: AskAck, By: "CLE-001", Reason: ""}, "x", later); !errors.Is(err, ErrNotFound) {
				t.Fatalf("other tenant acks an ask: %v", err)
			}
		})
	}
}

// The client and the hub refuse what 0097's CHECKs would.
func TestCheckFleetAsk(t *testing.T) {
	ok := FleetAsk{Fleet: "main", AskID: "39451306-8830-4e8e-878c-eb29f2803839", Role: "orch", Kind: "blocker", From: "CLE-002@box-desk", Topic: "692aefe8"}
	if why := CheckFleetAsk(ok); why != "" {
		t.Fatalf("refused a good ask: %s", why)
	}
	for _, bad := range []func(*FleetAsk){
		func(a *FleetAsk) { a.Fleet = "Main" },
		func(a *FleetAsk) { a.AskID = "not-a-uuid" },
		func(a *FleetAsk) { a.AskID = "39451306-8830-4E8E-878C-EB29F2803839" },
		func(a *FleetAsk) { a.Kind = "note" },
		func(a *FleetAsk) { a.Role = "" },
		func(a *FleetAsk) { a.Role = "Orch" },
		func(a *FleetAsk) { a.From = "" },
		func(a *FleetAsk) { a.From = "CLE-002@Box" },
		func(a *FleetAsk) { a.Topic = "a b" },
		func(a *FleetAsk) { a.Summary = "two\nlines" },
	} {
		a := ok
		bad(&a)
		if CheckFleetAsk(a) == "" {
			t.Fatalf("accepted %+v", a)
		}
	}
	if why := CheckFleetAskOp(AskDone, "CLE-001@box-desk", ""); why != "" {
		t.Fatalf("done without a reason refused: %s", why)
	}
	for _, c := range [][3]string{{AskDecline, "CLE-001", ""}, {"drop", "CLE-001", ""}, {AskAck, "", ""}, {AskAck, "cle-1", ""}, {AskDone, "CLE-001", "a\nb"}} {
		if CheckFleetAskOp(c[0], c[1], c[2]) == "" {
			t.Fatalf("accepted op %v", c)
		}
	}
}
