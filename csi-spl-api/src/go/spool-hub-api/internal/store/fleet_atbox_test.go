package store

import (
	"context"
	"testing"
	"time"
)

// spec 061 3.3.1 (FR-015, rdb 0102): every machine numbers c-004..c-999 on
// its own, so c-004@box-desk and c-004@sat are two agents. They coexist in
// the roster, the lane map, the asks and the leases, and neither row
// overwrites the other. Run on Memory and Postgres.
func TestAgentAtBoxCollision(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)

			// roster: one c-004 per box
			for _, b := range []string{"box-desk", "sat"} {
				if err := st.SetRoster(ctx, tid, b, []string{"c-004"}, t0); err != nil {
					t.Fatalf("roster %s: %v", b, err)
				}
			}
			roster, err := st.Roster(ctx, tid)
			if err != nil || len(roster["box-desk"]) != 1 || len(roster["sat"]) != 1 {
				t.Fatalf("roster holds both: %+v %v", roster, err)
			}

			// lanes: one row per agent AT ITS BOX
			for _, b := range []string{"box-desk", "sat"} {
				l := FleetLane{Fleet: "main", AgentID: "c-004", AgentBox: b, Repo: "csi-spl", Branch: "c-004-" + b, State: "live"}
				if _, err := st.PutFleetLane(ctx, tid, l, b, t0); err != nil {
					t.Fatalf("lane %s: %v", b, err)
				}
			}
			done := FleetLane{Fleet: "main", AgentID: "c-004", AgentBox: "sat", Repo: "csi-spl", Branch: "c-004-sat", State: "done"}
			if _, err := st.PutFleetLane(ctx, tid, done, "sat", t0.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}
			ls, err := st.ListFleetLanes(ctx, tid, "main", t0.Add(time.Minute))
			if err != nil || len(ls) != 2 {
				t.Fatalf("two lanes: %+v %v", ls, err)
			}
			if ls[0].AgentBox != "box-desk" || ls[0].State != "live" || ls[0].Branch != "c-004-box-desk" ||
				ls[1].AgentBox != "sat" || ls[1].State != "done" {
				t.Fatalf("sat's exit touched only sat's row: %+v", ls)
			}

			// asks: a bare sender is keyed on the box that wrote it
			a1, a2 := "a0000000-0000-4000-8000-000000000001", "a0000000-0000-4000-8000-000000000002"
			got1, _, err := st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: a1, Role: "orch", Kind: "task", From: "c-004"}, "box-desk", t0)
			if err != nil || got1.From != "c-004@box-desk" {
				t.Fatalf("ask from box-desk: %+v %v", got1, err)
			}
			got2, _, err := st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: a2, Role: "orch", Kind: "task", From: "c-004"}, "sat", t0)
			if err != nil || got2.From != "c-004@sat" {
				t.Fatalf("ask from sat: %+v %v", got2, err)
			}
			acked, err := st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: a2, Op: AskAck, By: "c-001"}, "sat", t0)
			if err != nil || acked.AckedBy != "c-001@sat" {
				t.Fatalf("a bare acker is keyed on its box: %+v %v", acked, err)
			}

			// leases: holders c-004@box-desk and c-004@sat side by side
			if _, err := st.CASFleetLease(ctx, tid, "main", "orch", "c-004@box-desk", "box-desk", 0, t0); err != nil {
				t.Fatal(err)
			}
			if _, err := st.CASFleetLease(ctx, tid, "main", "dispatch", "c-004@sat", "sat", 0, t0); err != nil {
				t.Fatal(err)
			}
			o, _ := st.GetFleetLease(ctx, tid, "main", "orch", t0)
			d, _ := st.GetFleetLease(ctx, tid, "main", "dispatch", t0)
			if o.Holder != "c-004@box-desk" || d.Holder != "c-004@sat" {
				t.Fatalf("leases: %+v %+v", o, d)
			}
		})
	}
}

func TestAskAtBox(t *testing.T) {
	for _, c := range [][3]string{
		{"c-004", "sat", "c-004@sat"},
		{"c-004@box-desk", "sat", "c-004@box-desk"},
		{"", "sat", ""},
		{"c-004", "", "c-004"},
	} {
		if got := AskAtBox(c[0], c[1]); got != c[2] {
			t.Errorf("AskAtBox(%q, %q) = %q, want %q", c[0], c[1], got, c[2])
		}
	}
}
