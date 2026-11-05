package store

import (
	"context"
	"errors"
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
				Branch: "CLE-77920-fleet-lane-map", Scope: "lane map", Files: []string{"csi-spl-orc/src/bash/run/"}, Topic: "t-1", IssueKey: "SPL-1", State: "live"}
			got, err := st.PutFleetLane(ctx, tid, home, "box-desk", t0)
			if err != nil || got.WriterBox != "box-desk" || got.State != "live" || len(got.Files) != 1 {
				t.Fatalf("home put: %+v %v", got, err)
			}
			sat := FleetLane{Fleet: "main", AgentID: "CLE-100001", AgentBox: "sat", Repo: "csi-spl", Topic: "t-2", IssueKey: "SPL-2", State: "live"}
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
			if _, err = st.PutFleetLane(ctx, tid, FleetLane{Fleet: "main", AgentID: "CLE-3", AgentBox: "box-desk", Topic: "t-3", IssueKey: "SPL-3", State: "live"}, "box-desk", later); err != nil {
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
	ok := FleetLane{Fleet: "main", AgentID: "CLE-7", AgentBox: "box-desk", Topic: "t-7", IssueKey: "SPL-7", State: "live"}
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
		func(l *FleetLane) { l.Topic = "" },    // rdb 0263
		func(l *FleetLane) { l.IssueKey = "" }, // rdb 0263
		func(l *FleetLane) { l.IssueKey = "Unknown" },
	} {
		l := ok
		bad(&l)
		if CheckFleetLane(l) == "" {
			t.Fatalf("accepted %+v", l)
		}
	}
}

// rdb 0263 (SPL-4799; owner HUM-10 t1 0c2d08a2, msgs 80bee509 and
// 937e89a4): a lane row always names its discussion and its issue. A lane
// without either is refused; LaneUnknown, what 0263 wrote into the old rows,
// is a value (an old row's done write carries it); the rows that are no lane
// (BOX-<n>, role seats 001..003, a role rotation's row) store LaneUnknown for a missing link. Run
// on Memory and Postgres.
//
// Red control, before this change: the refused puts below were stored
// (n=3 on each driver).
func TestFleetLaneLinksRequired(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			lane := func(id, topic, issue, state string) FleetLane {
				return FleetLane{Fleet: "main", AgentID: id, AgentBox: "sat", Topic: topic, IssueKey: issue, State: state}
			}
			scoped := func(l FleetLane, scope string) FleetLane { l.Scope = scope; return l }
			for _, bad := range []FleetLane{
				lane("c-100", "", "SPL-4799", "live"),
				lane("c-100", "t-1", "", "live"),
				lane("c-004", "", "", "live"),                                    // c-004 is a lane, not a seat
				scoped(lane("c-005", "", "", "live"), "role seats: who answers"), // a brief heading, no rotation scope
			} {
				if got, err := st.PutFleetLane(ctx, tid, bad, "sat", t0); !errors.Is(err, ErrLaneUnlinked) {
					t.Errorf("lane %+v: stored %+v, err %v; want ErrLaneUnlinked", bad, got, err)
				}
			}
			if _, err := st.PutFleetLane(ctx, tid, lane("c-100", "t-1", "SPL-4799", "live"), "sat", t0); err != nil {
				t.Fatalf("a linked lane: %v", err)
			}
			// an old row 0263 filled with LaneUnknown takes its done write back
			if got, err := st.PutFleetLane(ctx, tid, lane("c-099", LaneUnknown, LaneUnknown, "done"), "sat", t0); err != nil ||
				got.State != "done" || got.Topic != LaneUnknown || got.IssueKey != LaneUnknown {
				t.Errorf("done write of an old unknown row: %+v %v", got, err)
			}
			// the rows that are no lane store LaneUnknown for a missing link
			for _, id := range []string{"BOX-0", "c-001", "g-002", "CLE-003"} {
				got, err := st.PutFleetLane(ctx, tid, lane(id, "", "", "live"), "sat", t0)
				if err != nil || got.Topic != LaneUnknown || got.IssueKey != LaneUnknown {
					t.Errorf("%s: %+v %v, want topic and issue_key %q", id, got, err, LaneUnknown)
				}
			}
			// a row the role rotation wrote (LaneRoleScope) is a seat whatever its id
			seat := scoped(lane("c-462", "", "", "live"), "role c-462 (rotation 20261031T0005Z-orch)")
			if got, err := st.PutFleetLane(ctx, tid, seat, "sat", t0); err != nil || got.Topic != LaneUnknown || got.IssueKey != LaneUnknown {
				t.Errorf("role rotation row: %+v %v, want topic and issue_key %q", got, err, LaneUnknown)
			}
		})
	}
}
