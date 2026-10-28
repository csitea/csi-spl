package hub_test

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// SPL-3983 (owner HUM-10, 2026-10-27: "the discusoin has been archieved ->
// the agents should be killed / freed"): lane_op archived answers the live
// lanes whose topic is archived, in the operator workspace and in the
// customer workspace the put found the topic in; agent_box narrows it to one
// box. Memory, and Postgres under SPOOL_TEST_PG_DSN. RED CONTROL (master):
// the op was refused, "lane_op must be put or list".
func TestFleetLaneArchived(t *testing.T) {
	r := newWSLanesRig(t)
	ctx, now := context.Background(), time.Now().UTC()
	live := uid.New()
	lobbyTopic(t, r.e, r.op, live, "## Still talking\n\nlive")
	laneAt(t, r.fleetTokensRig, "c-601", "box-a", r.opTopic, "", now)
	laneAt(t, r.fleetTokensRig, "c-602", "box-a", r.t1, "", now)
	laneAt(t, r.fleetTokensRig, "c-603", "box-b", r.opTopic, "", now)
	laneAt(t, r.fleetTokensRig, "c-604", "box-a", live, "", now)
	laneAt(t, r.fleetTokensRig, "c-605", "box-a", "dispatch-5e7b15c9", "", now)

	archived := func(box string) map[string]string {
		t.Helper()
		got := map[string]string{}
		for _, l := range laneCall(t, r.opBox, action.LaneArgs{Fleet: "main", Archived: true, Box: box}).Lanes {
			got[l.AgentID] = l.TopicArchivedAt
		}
		return got
	}
	if got := archived(""); len(got) != 0 {
		t.Fatalf("nothing archived yet, answered %v", got)
	}

	// the operator's topic and w1's topic are archived; live stays live
	if _, err := r.e.st.SetArchived(ctx, r.op, r.opTopic, "HUM-1", now.Truncate(time.Second), true); err != nil {
		t.Fatal(err)
	}
	if _, err := r.e.st.SetArchived(ctx, r.w1, r.t1, "HUM-1", now.Truncate(time.Second), true); err != nil {
		t.Fatal(err)
	}
	got := archived("")
	keys := make([]string, 0, len(got))
	for k, at := range got {
		keys = append(keys, k)
		if _, err := time.Parse(time.RFC3339, at); err != nil {
			t.Errorf("%s topic_archived_at %q: %v", k, at, err)
		}
	}
	slices.Sort(keys)
	if !slices.Equal(keys, []string{"c-601", "c-602", "c-603"}) {
		t.Errorf("archived lanes %v, want c-601 (operator topic), c-602 (w1 topic), c-603", keys)
	}
	// agent_box: box-a's rows only
	if got := archived("box-a"); len(got) != 2 || got["c-601"] == "" || got["c-602"] == "" {
		t.Errorf("box-a archived lanes %v, want c-601 and c-602", got)
	}
	// a done lane is not answered
	laneAt(t, r.fleetTokensRig, "c-601", "box-a", r.opTopic, "", now)
	if _, err := lanePut(t, r.opBox, `{"agent_id":"c-601","agent_box":"box-a","topic":"`+r.opTopic+`","state":"done"}`); err != nil {
		t.Fatal(err)
	}
	if got := archived("box-a"); len(got) != 1 || got["c-602"] == "" {
		t.Errorf("after c-601 is done: %v, want c-602 only", got)
	}
	// unarchived: the lane is no longer answered
	if _, err := r.e.st.SetArchived(ctx, r.w1, r.t1, "HUM-1", now, false); err != nil {
		t.Fatal(err)
	}
	if got := archived("box-a"); len(got) != 0 {
		t.Errorf("after the unarchive: %v, want none", got)
	}
}
