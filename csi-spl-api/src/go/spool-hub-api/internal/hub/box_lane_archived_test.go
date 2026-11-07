package hub_test

import (
	"context"
	"encoding/json"
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
	if _, err := lanePut(t, r.opBox, `{"agent_id":"c-601","agent_box":"box-a","topic":"`+r.opTopic+`","issue_key":"unknown","state":"done"}`); err != nil {
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

// SPL-4955 (owner HUM-10, msg 51465f86): lane_op archived naming a topic answers
// that topic's stamp and no rows, by full id or short id, in the operator
// workspace and in the customer workspace that holds it. RED CONTROL: without
// the topic branch the answer has no topic_archived_at, and the first check
// after the archive fails.
func TestFleetLaneOneTopicArchived(t *testing.T) {
	r := newWSLanesRig(t)
	ctx, now := context.Background(), time.Now().UTC()
	laneAt(t, r.fleetTokensRig, "c-601", "box-a", r.opTopic, "", now)
	read := func(topic string) laneAnswerWire {
		t.Helper()
		raw, err := action.Lane(ctx, r.opBox.cfg, action.LaneArgs{Fleet: "main", Archived: true, Topic: topic, Hub: r.opBox.c})
		if err != nil {
			t.Fatal(err)
		}
		var a laneAnswerWire
		if err := json.Unmarshal(raw, &a); err != nil {
			t.Fatal(err)
		}
		return a
	}
	if a := read(r.opTopic); a.TopicArchivedAt != "" || a.Topic != r.opTopic {
		t.Fatalf("a live topic: %+v, want its id and no stamp", a)
	}
	if _, err := r.e.st.SetArchived(ctx, r.op, r.opTopic, "HUM-1", now.Truncate(time.Second), true); err != nil {
		t.Fatal(err)
	}
	if _, err := r.e.st.SetArchived(ctx, r.w1, r.t1, "HUM-1", now.Truncate(time.Second), true); err != nil {
		t.Fatal(err)
	}
	for name, topic := range map[string]string{"full id": r.opTopic, "short id": r.opTopic[:8], "another workspace": r.t1} {
		a := read(topic)
		if _, err := time.Parse(time.RFC3339, a.TopicArchivedAt); err != nil {
			t.Errorf("%s: topic_archived_at %q: %v", name, a.TopicArchivedAt, err)
		}
		if len(a.Lanes) != 0 {
			t.Errorf("%s: %d rows, want none", name, len(a.Lanes))
		}
	}
	// a doubt never drops a row: an id that starts no topic, and a task name
	for _, topic := range []string{"00000000", "spawn-share"} {
		if a := read(topic); a.TopicArchivedAt != "" {
			t.Errorf("%q: stamp %q, want none", topic, a.TopicArchivedAt)
		}
	}
}

type laneAnswerWire struct {
	Lanes           []json.RawMessage `json:"lanes"`
	Topic           string            `json:"topic"`
	TopicArchivedAt string            `json:"topic_archived_at"`
}
