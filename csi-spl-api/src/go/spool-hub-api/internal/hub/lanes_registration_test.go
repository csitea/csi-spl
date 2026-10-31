package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 153 section 3.11 (SPL-4457; owner HUM-10, t1 0acd4eaa, msg
// 69522885): a Lanes row with no topic shows the discussion its own issue
// links (never the tenant's default one), and a role seat says so instead of
// two empty cells. Memory, and Postgres under SPOOL_TEST_PG_DSN.

// laneRegRow is the part of a view row these cases read.
type laneRegRow struct {
	AgentID    string `json:"agent_id"`
	TopicID    string `json:"topic_id"`
	TopicTitle string `json:"topic_title"`
	RoleSeat   bool   `json:"role_seat"`
	Issues     []struct {
		Key string `json:"key"`
	} `json:"issues"`
}

func laneRegRows(t *testing.T, r *fleetTokensRig) map[string]laneRegRow {
	t.Helper()
	code, body := call(t, r.e, r.op, http.MethodGet, fleetLanesPath, r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("GET %s: %d %v", fleetLanesPath, code, body)
	}
	raw, _ := json.Marshal(body["lanes"])
	var rows []laneRegRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		t.Fatal(err)
	}
	out := map[string]laneRegRow{}
	for _, l := range rows {
		out[l.AgentID] = l
	}
	return out
}

// C50, C50b, C50c: the topic from the lane's own issue. RED CONTROL (master
// 4cd5b29d2): c-451's topic_id was "" (the row stored none), so the cell was
// a dash although SPL-1 links the lane's discussion.
func TestFleetLanesTopicFromOwnIssue(t *testing.T) {
	r := newFleetTokensRig(t)
	now := time.Now()
	box := r.opBox.id
	talk, other := uid.New(), uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Lane origin\n\nthe brief's topic")
	lobbyTopic(t, r.e, r.op, other, "## Another lane's topic\n\nkept")
	for _, disc := range []string{talk, store.IssueDiscussionDefault(r.op)} { // SPL-1 links talk, SPL-2 the default only
		if code, out := call(t, r.e, r.op, http.MethodPost, "/v1/issues", r.admin, map[string]any{"title": "lane work", "discussions": []string{disc}}); code != http.StatusCreated {
			t.Fatalf("issue on %s: %d %v", disc, code, out)
		}
	}
	laneAt(t, r, "c-451", box, "", "SPL-1", now.Add(-time.Minute))      // C50
	laneAt(t, r, "c-452", box, "", "SPL-2", now.Add(-2*time.Minute))    // C50b: the default discussion is no origin
	laneAt(t, r, "c-453", box, "", "OPS-1", now.Add(-3*time.Minute))    // C50b: another prefix's key
	laneAt(t, r, "c-454", box, other, "SPL-1", now.Add(-4*time.Minute)) // C50c: a stored topic stays

	rows := laneRegRows(t, r)
	if l := rows["c-451"]; l.TopicID != talk || l.TopicTitle != "Lane origin" || len(l.Issues) != 1 || l.Issues[0].Key != "SPL-1" {
		t.Errorf("C50 a lane with no topic shows its issue's discussion: %+v, want topic %s titled 'Lane origin', issue SPL-1", l, talk)
	}
	for _, id := range []string{"c-452", "c-453"} {
		if l := rows[id]; l.TopicID != "" {
			t.Errorf("C50b %s: topic %q, want none (default discussion / foreign key)", id, l.TopicID)
		}
	}
	if l := rows["c-454"]; l.TopicID != other {
		t.Errorf("C50c a stored topic is kept: %q, want %s", l.TopicID, other)
	}
}

// C51: a role seat's row carries role_seat; a lane's does not. RED CONTROL
// (master 4cd5b29d2): no row carried role_seat, so a seat's topic and issue
// cells were dashes like a lane that lost them.
func TestFleetLanesRoleSeat(t *testing.T) {
	r := newFleetTokensRig(t)
	now := time.Now()
	box := r.opBox.id
	laneAt(t, r, "c-001", box, "", "", now.Add(-time.Minute))
	laneAt(t, r, "g-002", box, "", "", now.Add(-2*time.Minute))
	laneAt(t, r, "c-461", box, "", "", now.Add(-3*time.Minute))
	seat := store.FleetLane{Fleet: "main", AgentID: "c-462", AgentBox: box, Scope: "role c-462 (rotation 20261031T0005Z-orch)", State: "live", Files: []string{}}
	if _, err := r.e.st.PutFleetLane(context.Background(), r.op, seat, box, now.Add(-4*time.Minute)); err != nil {
		t.Fatal(err)
	}
	rows := laneRegRows(t, r)
	for id, want := range map[string]bool{"c-001": true, "g-002": true, "c-462": true, "c-461": false} {
		if got := rows[id].RoleSeat; got != want {
			t.Errorf("C51 %s role_seat %v, want %v", id, got, want)
		}
	}
}
