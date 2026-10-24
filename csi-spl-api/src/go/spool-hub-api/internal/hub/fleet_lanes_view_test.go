package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 153 v1.0 row B3 (SPL-3158): the lane row's issue key and short-id
// topic (lane_op put, rdb 0220) and the live lanes view
// GET /v1/operator/fleet-lanes. Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full). Each case names its spec 4 row; each red control is
// the check that failed before the row.

const fleetLanesPath = "/v1/operator/fleet-lanes"

// lanePut is one lane_op put from b, answering the stored row or the error.
func lanePut(t *testing.T, b *box, row string) (hub.LaneRow, error) {
	t.Helper()
	raw, err := b.c.Lane(context.Background(), "put", "main", json.RawMessage(row))
	if err != nil {
		return hub.LaneRow{}, err
	}
	var out laneOut
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Lanes) != 1 {
		t.Fatalf("put answer %s: %v", raw, err)
	}
	return out.Lanes[0], nil
}

// laneAt stores a live row of agent at box written at, through the store (a
// legacy or box id the hub's put would refuse or rename, and a past write).
func laneAt(t *testing.T, r *fleetTokensRig, agent, box, topic, issue string, at time.Time) {
	t.Helper()
	l := store.FleetLane{Fleet: "main", AgentID: agent, AgentBox: box, Scope: "scope of " + agent, Topic: topic, IssueKey: issue, State: "live", Files: []string{}}
	if _, err := r.e.st.PutFleetLane(context.Background(), r.op, l, box, at); err != nil {
		t.Fatalf("lane %s: %v", agent, err)
	}
}

type lanesView struct {
	AsOf  string `json:"as_of"`
	Fleet string `json:"fleet"`
	Lanes []struct {
		AgentID    string `json:"agent_id"`
		AgentBox   string `json:"agent_box"`
		Vendor     string `json:"vendor"`
		Scope      string `json:"scope"`
		TopicID    string `json:"topic_id"`
		TopicTitle string `json:"topic_title"`
		Issues     []struct {
			Key    string `json:"key"`
			Status string `json:"status"`
		} `json:"issues"`
		AgeS       int64  `json:"age_s"`
		LastActive string `json:"last_active"`
	} `json:"lanes"`
}

func getLanes(t *testing.T, r *fleetTokensRig) lanesView {
	t.Helper()
	code, body := call(t, r.e, r.op, http.MethodGet, fleetLanesPath, r.admin, nil)
	if code != http.StatusOK {
		t.Errorf("GET %s as the operator admin: %d %v", fleetLanesPath, code, body)
		return lanesView{}
	}
	raw, _ := json.Marshal(body)
	var v lanesView
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// laneKeys is the view's agent ids; issuesOf one lane's issue keys.
func laneKeys(v lanesView) []string {
	out := []string{}
	for _, l := range v.Lanes {
		out = append(out, l.AgentID)
	}
	return out
}

func issuesOf(t *testing.T, v lanesView, agent string) []string {
	t.Helper()
	for _, l := range v.Lanes {
		if l.AgentID == agent {
			out := []string{}
			for _, i := range l.Issues {
				out = append(out, i.Key+" "+i.Status)
			}
			return out
		}
	}
	t.Errorf("lane %s absent from %v", agent, laneKeys(v))
	return nil
}

// C7b, C9, C10: the put stores the issue key and turns a short-id topic into
// the one topic it starts. RED CONTROL (master): issue_key was dropped and
// an 8-hex topic stored as sent.
func TestFleetLanePutIssueKeyAndShortTopic(t *testing.T) {
	r := newFleetTokensRig(t)
	one := "5eed0153-0000-4000-8000-000000000001"
	twinA, twinB := "b3b3b3b3-0000-4000-8000-00000000000a", "b3b3b3b3-0000-4000-8000-00000000000b"
	for _, task := range []string{one, twinA, twinB} {
		lobbyTopic(t, r.e, r.op, task, "topic "+task)
	}
	box := r.opBox.id

	// C9: the key round-trips through put and list.
	got, err := lanePut(t, r.opBox, `{"agent_id":"c-901","agent_box":"`+box+`","issue_key":"SPL-3075","state":"live"}`)
	if err != nil || got.IssueKey != "SPL-3075" {
		t.Errorf("C9 put issue_key: %+v %v", got, err)
	}
	list := laneCall(t, r.opBox, action.LaneArgs{Fleet: "main"})
	if len(list.Lanes) != 1 || list.Lanes[0].IssueKey != "SPL-3075" {
		t.Errorf("C9 list issue_key: %+v", list.Lanes)
	}

	// C10: a malformed key is refused and the row stays; twin: SPL-1 stored.
	for _, bad := range []string{"spl 1", "SPL-", "S-1", "SPL-1234567890"} {
		if _, err := lanePut(t, r.opBox, `{"agent_id":"c-901","agent_box":"`+box+`","issue_key":"`+bad+`","state":"live"}`); err == nil || !strings.Contains(err.Error(), "issue_key") {
			t.Errorf("C10 issue_key %q: %v, want refused", bad, err)
		}
	}
	if l := laneCall(t, r.opBox, action.LaneArgs{Fleet: "main"}).Lanes; len(l) != 1 || l[0].IssueKey != "SPL-3075" {
		t.Errorf("C10 a refusal changed the row: %+v", l)
	}
	if got, err := lanePut(t, r.opBox, `{"agent_id":"c-901","agent_box":"`+box+`","issue_key":"SPL-1","state":"live"}`); err != nil || got.IssueKey != "SPL-1" {
		t.Errorf("C10 twin SPL-1: %+v %v", got, err)
	}

	// C7b: one topic starts 5eed0153 -> its uuid; two start b3b3b3b3 -> "".
	for _, c := range []struct{ topic, want string }{
		{"5eed0153", one},
		{"b3b3b3b3", ""},
		{"0bad0bad", ""},
		{"dispatch-5e7b15c9", "dispatch-5e7b15c9"}, // not a short id: as sent
		{one, one},
	} {
		got, err := lanePut(t, r.opBox, `{"agent_id":"c-902","agent_box":"`+box+`","topic":"`+c.topic+`","state":"live"}`)
		if err != nil || got.Topic != c.want {
			t.Errorf("C7b topic %q stored %q (%v), want %q", c.topic, got.Topic, err, c.want)
		}
		ls, _ := r.e.st.ListFleetLanes(context.Background(), r.op, "main", time.Now())
		for _, l := range ls {
			if l.AgentID == "c-902" && l.Topic != c.want {
				t.Errorf("C7b topic %q in the store: %q, want %q", c.topic, l.Topic, c.want)
			}
		}
	}
}

// C11, C11b, C12, C13: who reads the view and which rows are active. RED
// CONTROL (master): the route did not exist (404 for every caller).
func TestFleetLanesViewActiveAndDoor(t *testing.T) {
	r := newFleetTokensRig(t)
	now := time.Now()
	box := r.opBox.id
	other := r.e.box(r.op, "x-"+newTenantID(""))
	r.e.pin(r.op, other)

	laneAt(t, r, "c-311", box, "", "", now.Add(-2*time.Hour))    // C11: 2 h old, no burn
	laneAt(t, r, "c-312", box, "", "", now.Add(-3*time.Hour))    // C11b: 3 h old, burn 5 min ago here
	laneAt(t, r, "c-313", box, "", "", now.Add(-3*time.Hour))    // C11b twin: burn under another box_tag
	laneAt(t, r, "c-314", box, "", "", now.Add(-5*time.Minute))  // fresh write, no burn
	laneAt(t, r, "BOX-0", box, "", "", now.Add(-time.Minute))    // C13: the box row
	laneAt(t, r, "CLE-77", box, "", "", now.Add(-time.Minute))   // C13: an old upper-case id
	laneAt(t, r, "c-077", box, "", "", now.Add(-time.Minute))    // C13 twin
	laneAt(t, r, "c-315", box, "", "", now.Add(-20*time.Minute)) // burn 20 min ago: past 15
	m := now.UTC().Truncate(time.Minute)
	if _, err := r.push(t, r.opBox, tokSample{agent: "c-312", vendor: "claude", minute: m.Add(-5 * time.Minute), in: 10, out: 1},
		tokSample{agent: "c-315", vendor: "claude", minute: m.Add(-20 * time.Minute), in: 10, out: 1}); err != nil {
		t.Fatal(err)
	}
	if _, err := r.push(t, other, tokSample{agent: "c-313", vendor: "claude", minute: m.Add(-5 * time.Minute), in: 10, out: 1}); err != nil {
		t.Fatal(err)
	}
	done := store.FleetLane{Fleet: "main", AgentID: "c-316", AgentBox: box, State: "done", Files: []string{}}
	if _, err := r.e.st.PutFleetLane(context.Background(), r.op, done, box, now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}

	v := getLanes(t, r)
	got := laneKeys(v)
	// c-315 is still active by its write (20 min < 60 min); c-077 and c-314 by
	// theirs; c-312 by its burn.
	want := []string{"c-077", "c-314", "c-315", "c-312"}
	if !slices.Equal(got, want) {
		t.Errorf("active lanes %v, want %v (newest write first)", got, want)
	}
	for _, l := range v.Lanes {
		if l.AgentID == "c-312" && (l.LastActive == "" || l.Vendor != "claude" || l.Scope != "scope of c-312" || l.AgeS < 3*3600-60) {
			t.Errorf("C11b row: %+v", l)
		}
		if l.AgentID == "c-314" && (l.LastActive != "" || l.Vendor != "claude") {
			t.Errorf("a lane with no burn: %+v", l)
		}
	}
	if v.Fleet != "main" || v.AsOf == "" {
		t.Errorf("answer head: fleet %q as_of %q", v.Fleet, v.AsOf)
	}

	// C12: a developer of the operator workspace and an admin of another one.
	for _, who := range [][2]string{{r.op, r.dev}, {r.other, r.otherA}} {
		if code, body := call(t, r.e, who[0], http.MethodGet, fleetLanesPath, who[1], nil); code != http.StatusForbidden {
			t.Errorf("C12 %s of %s: %d %v, want 403", who[1], who[0], code, body)
		}
	}
	if code, _ := call(t, r.e, r.op, http.MethodGet, fleetLanesPath+"?fleet=Main", r.admin, nil); code != http.StatusBadRequest {
		t.Errorf("fleet=Main: %d, want 400", code)
	}
	if code, body := call(t, r.e, r.op, http.MethodGet, fleetLanesPath+"?fleet=other", r.admin, nil); code != http.StatusOK || len(body["lanes"].([]any)) != 0 {
		t.Errorf("fleet=other: %d %v, want 200 and no lanes", code, body)
	}
}

// C14, C14b: a lane's issues are its topic's links plus its own key, each
// once; a topic of another tenant gives no title and no link. RED CONTROL
// (master): the route did not exist.
func TestFleetLanesViewIssuesAndTenant(t *testing.T) {
	r := newFleetTokensRig(t)
	now := time.Now()
	box := r.opBox.id
	talk, foreign := uid.New(), uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Lanes tab build\n\nrow B3")
	lobbyTopic(t, r.e, r.other, foreign, "## A customer topic\n\nsecret")
	for _, title := range []string{"one", "two"} { // SPL-1 links talk; SPL-2 the default
		disc := talk
		if title == "two" {
			disc = store.IssueDiscussionDefault(r.op)
		}
		if code, out := call(t, r.e, r.op, http.MethodPost, "/v1/issues", r.admin, map[string]any{"title": title, "discussions": []string{disc}}); code != http.StatusCreated {
			t.Fatalf("issue %s: %d %v", title, code, out)
		}
	}
	// In the other tenant, an issue that links its topic: never shown.
	if code, out := call(t, r.e, r.other, http.MethodPost, "/v1/issues", r.otherA, map[string]any{"title": "theirs", "discussions": []string{foreign}}); code != http.StatusCreated {
		t.Fatalf("other tenant issue: %d %v", code, out)
	}

	laneAt(t, r, "c-401", box, talk, "SPL-2", now.Add(-time.Minute))      // C14
	laneAt(t, r, "c-402", box, talk, "SPL-1", now.Add(-2*time.Minute))    // C14 twin
	laneAt(t, r, "c-403", box, foreign, "SPL-2", now.Add(-3*time.Minute)) // C14b
	laneAt(t, r, "c-404", box, "", "OPS-7", now.Add(-4*time.Minute))      // a key of another prefix

	v := getLanes(t, r)
	if got := issuesOf(t, v, "c-401"); !slices.Equal(got, []string{"SPL-1 wip", "SPL-2 wip"}) && !slices.Equal(got, []string{"SPL-1 eval", "SPL-2 eval"}) {
		t.Errorf("C14 issues %v, want SPL-1 and SPL-2, each once", got)
	}
	if got := issuesOf(t, v, "c-402"); len(got) != 1 || !strings.HasPrefix(got[0], "SPL-1 ") {
		t.Errorf("C14 twin issues %v, want SPL-1 once", got)
	}
	if got := issuesOf(t, v, "c-403"); len(got) != 1 || !strings.HasPrefix(got[0], "SPL-2 ") {
		t.Errorf("C14b issues %v, want the lane's own SPL-2 only", got)
	}
	if got := issuesOf(t, v, "c-404"); !slices.Equal(got, []string{"OPS-7 "}) {
		t.Errorf("another prefix: %v, want OPS-7 with no status", got)
	}
	for _, l := range v.Lanes {
		switch l.AgentID {
		case "c-401", "c-402":
			if l.TopicID != talk || l.TopicTitle != "Lanes tab build" {
				t.Errorf("C14b twin: the operator's topic is titled: %+v", l)
			}
		case "c-403":
			if l.TopicID != foreign || l.TopicTitle != "" {
				t.Errorf("C14b: another tenant's topic: %+v", l)
			}
		}
	}
	raw, _ := json.Marshal(v)
	if strings.Contains(string(raw), "customer") {
		t.Errorf("C14b: another tenant's data in the view: %s", raw)
	}
}
