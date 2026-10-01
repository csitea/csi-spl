package store

import (
	"context"
	"testing"
	"time"
)

// CLE-77920 (rdb 0096): the fleet-wide lane map. Two machines write their
// lanes into one fleet; both read the same rows; exit flips a row to done
// in place; a done row is pruned a week after its last write and a live one
// never is; another tenant sees none of it. Run on Memory and Postgres.
func TestFleetLanePutList(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 1, 19, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			other := newTenant(t, st)

			if ls, err := st.ListFleetLanes(ctx, tid, "main", t0); err != nil || len(ls) != 0 {
				t.Fatalf("empty map: %+v %v", ls, err)
			}
			home := FleetLane{Fleet: "main", AgentID: "CLE-77920", AgentBox: "box-desk", Repo: "csi-spl",
				Branch: "CLE-77920-fleet-lane-map", Scope: "lane map", Files: []string{"csi-spl-orc/src/bash/run/"}, Topic: "t-1", State: "live"}
			got, err := st.PutFleetLane(ctx, tid, home, "box-desk", t0)
			if err != nil || got.WriterBox != "box-desk" || got.State != "live" || len(got.Files) != 1 {
				t.Fatalf("home put: %+v %v", got, err)
			}
			sat := FleetLane{Fleet: "main", AgentID: "CLE-100001", AgentBox: "sat", Repo: "csi-spl", State: "live"}
			if got, err = st.PutFleetLane(ctx, tid, sat, "box-desk-sat", t0.Add(time.Minute)); err != nil || len(got.Files) != 0 {
				t.Fatalf("sat put: %+v %v", got, err)
			}

			ls, err := st.ListFleetLanes(ctx, tid, "main", t0.Add(2*time.Minute))
			if err != nil || len(ls) != 2 {
				t.Fatalf("list: %+v %v", ls, err)
			}
			if ls[0].AgentID != "CLE-100001" || ls[1].AgentID != "CLE-77920" || ls[1].Age != 2*time.Minute || ls[1].Files[0] != "csi-spl-orc/src/bash/run/" {
				t.Fatalf("order / age / files: %+v", ls)
			}

			// exit-clean: same row, state done, written from the other box
			home.State = "done"
			if _, err = st.PutFleetLane(ctx, tid, home, "box-desk", t0.Add(3*time.Minute)); err != nil {
				t.Fatal(err)
			}
			ls, _ = st.ListFleetLanes(ctx, tid, "main", t0.Add(3*time.Minute))
			if len(ls) != 2 || ls[0].AgentID != "CLE-100001" || ls[1].State != "done" {
				t.Fatalf("done sorts after live, one row per agent: %+v", ls)
			}

			// a week later a write prunes the done row, never the live one
			later := t0.Add(LaneDoneTTL + 4*time.Minute)
			if _, err = st.PutFleetLane(ctx, tid, FleetLane{Fleet: "main", AgentID: "CLE-3", AgentBox: "box-desk", State: "live"}, "box-desk", later); err != nil {
				t.Fatal(err)
			}
			ls, _ = st.ListFleetLanes(ctx, tid, "main", later)
			ids := map[string]bool{}
			for _, l := range ls {
				ids[l.AgentID] = true
			}
			if len(ls) != 2 || ids["CLE-77920"] || !ids["CLE-100001"] || !ids["CLE-3"] {
				t.Fatalf("prune: %+v", ls)
			}

			// another fleet and another tenant are separate maps
			if ls, _ := st.ListFleetLanes(ctx, tid, "other", later); len(ls) != 0 {
				t.Fatalf("other fleet sees rows: %+v", ls)
			}
			if ls, _ := st.ListFleetLanes(ctx, other, "main", later); len(ls) != 0 {
				t.Fatalf("other tenant sees rows: %+v", ls)
			}
		})
	}
}

// The client and the hub refuse what 0096's CHECKs would.
func TestCheckFleetLane(t *testing.T) {
	ok := FleetLane{Fleet: "main", AgentID: "CLE-7", AgentBox: "box-desk", State: "live"}
	if why := CheckFleetLane(ok); why != "" {
		t.Fatalf("refused a good row: %s", why)
	}
	long := make([]string, LaneFilesMax+1)
	for i := range long {
		long[i] = "a"
	}
	for _, bad := range []func(*FleetLane){
		func(l *FleetLane) { l.Fleet = "Main" },
		func(l *FleetLane) { l.AgentID = "cle-7" },
		func(l *FleetLane) { l.AgentID = "BOX-desk" },
		func(l *FleetLane) { l.AgentBox = "" },
		func(l *FleetLane) { l.Repo = "a/b" },
		func(l *FleetLane) { l.Branch = "-x" },
		func(l *FleetLane) { l.Scope = "two\nlines" },
		func(l *FleetLane) { l.Files = long },
		func(l *FleetLane) { l.Files = []string{""} },
		func(l *FleetLane) { l.Topic = "a b" },
		func(l *FleetLane) { l.State = "gone" },
	} {
		l := ok
		bad(&l)
		if CheckFleetLane(l) == "" {
			t.Fatalf("accepted %+v", l)
		}
	}
}
