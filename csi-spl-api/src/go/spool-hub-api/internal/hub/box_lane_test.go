package hub_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// CLE-77920 (specs/058 G4): two machines' boxes share one lane map through
// the real front end (action.Lane == `spool lane`). Each machine sees the
// other's lanes, which `git worktree list` never could; the hub records the
// writing box from the session; a malformed frame is refused before the store.

type laneOut struct {
	Fleet string        `json:"fleet"`
	Lanes []hub.LaneRow `json:"lanes"`
}

func laneCall(t *testing.T, b *box, in action.LaneArgs) laneOut {
	t.Helper()
	in.Hub = b.c
	raw, err := action.Lane(context.Background(), b.cfg, in)
	if err != nil {
		t.Fatalf("lane %+v: %v", in, err)
	}
	var out laneOut
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("answer %s: %v", raw, err)
	}
	return out
}

func TestBoxFleetLaneMap(t *testing.T) {
	e, tid, _, _, home, sat := boxArchiveRig(t)

	if got := laneCall(t, home, action.LaneArgs{Fleet: "main"}); got.Fleet != "main" || len(got.Lanes) != 0 {
		t.Fatalf("empty map: %+v", got)
	}
	got := laneCall(t, home, action.LaneArgs{Fleet: "main", Agent: "CLE-77920", Box: "box-b", Repo: "csi-spl",
		Branch: "CLE-77920-lane-map", Scope: "lane map", Files: []string{"csi-spl-orc/src/bash/run/spl-lane-map.func.sh"}, Topic: "t-1"})
	if len(got.Lanes) != 1 || got.Lanes[0].State != "live" || got.Lanes[0].WriterBox != "box-b" {
		t.Fatalf("home put (state defaults to live, box from the session): %+v", got)
	}
	laneCall(t, sat, action.LaneArgs{Fleet: "main", Agent: "CLE-100001", Box: "box-c", Repo: "csi-spl",
		Files: []string{"csi-spl-orc/src/bash/run/spl-lane-map.func.sh"}})

	// the home box reads the satellite's lane, and the other way round
	for _, b := range []*box{home, sat} {
		m := laneCall(t, b, action.LaneArgs{Fleet: "main"})
		if len(m.Lanes) != 2 {
			t.Fatalf("both machines' lanes: %+v", m)
		}
		seen := map[string]string{}
		for _, l := range m.Lanes {
			seen[l.AgentID] = l.AgentBox + "/" + l.WriterBox
		}
		if seen["CLE-77920"] != "box-b/box-b" || seen["CLE-100001"] != "box-c/box-c" {
			t.Fatalf("rows: %v", seen)
		}
	}

	// exit-clean on the home box flips its row, written from either box
	laneCall(t, home, action.LaneArgs{Fleet: "main", Agent: "CLE-77920", Box: "box-b", State: "done"})
	m := laneCall(t, sat, action.LaneArgs{Fleet: "main"})
	if len(m.Lanes) != 2 || m.Lanes[0].AgentID != "CLE-100001" || m.Lanes[1].State != "done" {
		t.Fatalf("done row sorts after live: %+v", m)
	}

	// refusals: the client checks, and the hub checks a raw frame too
	for _, in := range []action.LaneArgs{
		{Fleet: "Main"},
		{Fleet: "main", Agent: "cle-1", Box: "box-b"},
		{Fleet: "main", Agent: "CLE-1", Box: ""},
		{Fleet: "main", Agent: "CLE-1", Box: "box-b", State: "gone"},
		{Fleet: "main", Agent: "CLE-1", Box: "box-b", Scope: "two\nlines"},
	} {
		in.Hub = home.c
		if _, err := action.Lane(context.Background(), home.cfg, in); err == nil {
			t.Fatalf("accepted %+v", in)
		}
	}
	if _, err := home.c.Lane(context.Background(), "drop", "main", nil); err == nil {
		t.Fatalf("hub accepted lane_op drop")
	}
	if _, err := home.c.Lane(context.Background(), "put", "main", json.RawMessage(`{"agent_id":"CLE-1","agent_box":"box-b","state":"gone"}`)); err == nil {
		t.Fatalf("hub accepted state gone")
	}
	if _, err := home.c.Lane(context.Background(), "put", "main", json.RawMessage(`"not an object"`)); err == nil {
		t.Fatalf("hub accepted a non-object lane")
	}
	if ls, _ := e.st.ListFleetLanes(context.Background(), tid, "main", time.Now()); len(ls) != 2 {
		t.Fatalf("a refusal wrote: %+v", ls)
	}
}
