package hub_test

import (
	"cmp"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 153 section 3.17 (SPL-4778; owner HUM-10, t1 dc2d6c40): a workspace's
// own boxes (a box joined to it, spec 108) publish their lanes with
// `spool lane`, the put lands in the workspace of the box's pin, and the
// workspace's owners and admins see them on GET /v1/view/lanes beside the
// operator lanes on their topics. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (RLS). C71-C74, C79.
// RED CONTROL (master af48d0fcb): C71 fails, w1's admin gets [c-501] only:
// the route read the operator workspace's rows alone.
func TestWorkspaceOwnLanes(t *testing.T) {
	r := newWSLanesRig(t)
	now := time.Now()
	mac := r.e.box(r.w1, "mbp-"+newTenantID(""))
	r.e.pin(r.w1, mac)
	put := func(agent, topic, state string) {
		t.Helper()
		topic = cmp.Or(topic, store.LaneUnknown) // rdb 0264: no lane without its discussion
		if _, err := lanePut(t, mac, `{"agent_id":"`+agent+`","agent_box":"`+mac.id+`","topic":"`+topic+`","issue_key":"unknown","scope":"scope of `+agent+`","state":"`+state+`"}`); err != nil {
			t.Fatalf("put %s: %v", agent, err)
		}
	}
	laneAt(t, r.fleetTokensRig, "c-501", r.opBox.id, r.t1, "", now.Add(-1*time.Minute)) // an operator lane on a w1 topic
	put("c-701", r.t1, "live")                                                          // C71: on a w1 topic
	put("c-702", "", "live")                                                            // C71: no topic
	put("c-703", r.t2, "live")                                                          // C72: a w2 topic id, no w2 text
	put("c-704", "", "done")                                                            // C73: not active
	old := store.FleetLane{Fleet: "main", AgentID: "c-705", AgentBox: mac.id, Scope: "old", Topic: store.LaneUnknown, IssueKey: store.LaneUnknown, State: "live", Files: []string{}}
	if _, err := r.e.st.PutFleetLane(context.Background(), r.w1, old, mac.id, now.Add(-3*time.Hour)); err != nil {
		t.Fatal(err) // C73: written 3 h ago, no burn
	}

	// C71: w1's admin sees the operator lane on its topic and its own box's lanes, with the box.
	v, raw := wsLanes(t, r, r.w1, r.w1Admin, http.StatusOK)
	if got := laneKeys(v); !slices.Equal(got, []string{"c-501", "c-703", "c-702", "c-701"}) {
		t.Errorf("C71/C73 w1 admin lanes %v, want [c-501 c-703 c-702 c-701] (newest write first)", got)
	}
	for _, l := range v.Lanes {
		own := strings.HasPrefix(l.AgentID, "c-7")
		if own && (l.AgentBox != mac.id || l.Workspace != r.w1 || l.State != "live") {
			t.Errorf("C71 own row: %+v", l)
		}
		if !own && l.AgentBox != "" {
			t.Errorf("C71 the operator row shows its box: %+v", l)
		}
		if l.AgentID == "c-701" && (l.TopicID != r.t1 || l.TopicTitle != "W1 build") {
			t.Errorf("C71 c-701 topic: %+v", l)
		}
		if l.AgentID == "c-703" && l.TopicTitle != "" {
			t.Errorf("C72 c-703 shows a title for a topic not of w1: %+v", l)
		}
	}
	for _, leak := range []string{"W2 secret", "confidential", "Operator only", r.opBox.id} {
		if strings.Contains(raw, leak) {
			t.Errorf("C72: %q in w1's answer: %s", leak, raw)
		}
	}

	// C74: no other workspace sees w1's own lanes or its box: w2's admin and
	// the operator workspace's admin on this route.
	if v, raw := wsLanes(t, r, r.w2, r.w2Admin, http.StatusOK); len(v.Lanes) != 0 || strings.Contains(raw, mac.id) {
		t.Errorf("C74 w2 admin: %s, want no lane", raw)
	}
	if v, raw := wsLanes(t, r, r.op, r.admin, http.StatusOK); strings.Contains(raw, mac.id) || slices.Contains(laneKeys(v), "c-701") {
		t.Errorf("C74 operator admin on %s: %s", workspaceLanesPath, raw)
	}

	// C79 (owner F2 = A): the operator view lists w1's own lanes, named by
	// w1, with the topic id as text and no w1 title, text or issue.
	op := getLanes(t, r.fleetTokensRig)
	opRaw, _ := json.Marshal(op)
	mine := []string{}
	for _, l := range op.Lanes {
		if l.AgentBox != mac.id {
			continue
		}
		mine = append(mine, l.AgentID)
		if l.Workspace != r.w1 || l.TopicTitle != "" || len(l.Issues) != 0 || l.Scope != "" {
			t.Errorf("C79 operator row of w1's own lane: %+v", l)
		}
		if l.AgentID == "c-701" && l.TopicID != r.t1 {
			t.Errorf("C79 c-701 topic id %q, want %s as text", l.TopicID, r.t1)
		}
	}
	if !slices.Equal(mine, []string{"c-703", "c-702", "c-701"}) {
		t.Errorf("C79 operator view, w1's own lanes %v, want [c-703 c-702 c-701]", mine)
	}
	for _, leak := range []string{"W1 build", "row B6", "W2 secret", "c-704", "c-705", "scope of c-70"} { // R7 W1: no w1 scope text
		if strings.Contains(string(opRaw), leak) {
			t.Errorf("C79: %q in the operator view: %s", leak, opRaw)
		}
	}
}

// Spec 153 section 3.17 (SPL-4778), the roster rows: a joined box's
// `spool hub-run` announces its agents, and W's lanes view lists each one
// that may run (running true or unreported) and has no lane row, keyed by
// <agent>@<box>. C75-C78, C80. RED CONTROL (master af48d0fcb, and this tree before
// rosterLanes): C75 fails, w1's admin reads [c-001@] only.
func TestWorkspaceOwnRosterLanes(t *testing.T) {
	r := newWSLanesRig(t)
	ctx, now := context.Background(), time.Now()
	mac := r.e.box(r.w1, "mbp-"+newTenantID(""))
	r.e.pin(r.w1, mac)
	away := r.e.box(r.w1, "away-"+newTenantID(""))
	r.e.pin(r.w1, away)
	fleetPub, _, _ := ed25519.GenerateKey(nil)
	r.e.pinKey(r.w1, r.opBox.id, fleetPub) // a fleet box's desk pin in w1
	roster := func(box string, agents ...string) {
		t.Helper()
		if err := r.e.st.SetRoster(ctx, r.w1, box, agents, now); err != nil {
			t.Fatal(err)
		}
	}
	roster(mac.id, "c-001", "c-701", "c-706", "c-707")
	roster(away.id, "c-708")
	roster(r.opBox.id, "c-002")
	for _, b := range []string{mac.id, r.opBox.id} { // away never stamps: offline (C77)
		if err := r.e.st.TouchBox(ctx, r.w1, b, now); err != nil {
			t.Fatal(err)
		}
	}
	if ar, ok := r.e.st.(store.AgentRunner); ok {
		if err := ar.SetAgentRun(ctx, r.w1, mac.id, map[string]bool{"c-701": true, "c-706": false}); err != nil {
			t.Fatal(err) // c-706 reported not running (C76); c-001, c-707 unreported (NULL)
		}
	}
	if _, err := lanePut(t, mac, `{"agent_id":"c-701","agent_box":"`+mac.id+`","topic":"`+r.t1+`","issue_key":"unknown","scope":"the build","state":"live"}`); err != nil {
		t.Fatal(err)
	}
	laneAt(t, r.fleetTokensRig, "c-001", r.opBox.id, r.t1, "", now.Add(-1*time.Minute)) // the fleet's c-001 on a w1 topic

	v, raw := wsLanes(t, r, r.w1, r.w1Admin, http.StatusOK)
	got := []string{}
	for _, l := range v.Lanes {
		got = append(got, l.AgentID+"@"+l.AgentBox)
	}
	// C75: the fleet's c-001 (no box, 3.6) and the Mac's c-001 are two rows;
	// c-701 once (its lane row), c-707 unreported still shows.
	want := []string{"c-001@", "c-701@" + mac.id, "c-001@" + mac.id, "c-707@" + mac.id}
	if !slices.Equal(got, want) {
		t.Errorf("C75-C78 w1 lanes %v, want %v", got, want)
	}
	for _, l := range v.Lanes {
		if l.AgentBox == mac.id && l.AgentID != "c-701" && (l.State != "live" || l.TopicID != "" || l.Scope != "" || l.Workspace != r.w1 || l.Vendor != "claude") {
			t.Errorf("C75 roster row: %+v", l)
		}
	}
	// C76 c-706 (not running), C77 c-708 (box offline), C78 c-002 of the
	// fleet box pinned in w1: absent, and the fleet box id never shows.
	for _, leak := range []string{"c-706", "c-708", "c-002", r.opBox.id, away.id} {
		if strings.Contains(raw, leak) {
			t.Errorf("C76-C78: %q in w1's answer: %s", leak, raw)
		}
	}
	if v, raw := wsLanes(t, r, r.w2, r.w2Admin, http.StatusOK); len(v.Lanes) != 0 || strings.Contains(raw, mac.id) {
		t.Errorf("C74 twin w2 admin: %s, want no lane", raw)
	}

	// C80 (owner F2 = A): the operator view holds the fleet's c-001 and the
	// joined box's c-001 as two rows, both of w1, and c-707; never c-706,
	// c-708 or the fleet box's roster agent c-002 announced in w1.
	op := getLanes(t, r.fleetTokensRig)
	opGot := []string{}
	for _, l := range op.Lanes {
		opGot = append(opGot, l.AgentID+"@"+l.AgentBox+" "+l.Workspace)
	}
	opWant := []string{"c-001@" + r.opBox.id + " " + r.w1, "c-701@" + mac.id + " " + r.w1, "c-001@" + mac.id + " " + r.w1, "c-707@" + mac.id + " " + r.w1}
	if !slices.Equal(opGot, opWant) {
		t.Errorf("C80 operator view %v, want %v", opGot, opWant)
	}
	opRaw, _ := json.Marshal(op)
	for _, leak := range []string{"c-706", "c-708", "c-002", away.id} {
		if strings.Contains(string(opRaw), leak) {
			t.Errorf("C80: %q in the operator view: %s", leak, opRaw)
		}
	}
}

// C81 (R7 N1): a box pinned in two workspaces announces its agents in each;
// the operator view lists such an agent once, and not at all beside a lane
// row of it in either workspace. Each workspace's own view is unchanged.
// RED CONTROL (451145f8f): c-709 twice (w1 and w2), c-711 as its w2 lane
// row and again as a w1 roster row.
func TestOperatorLanesAnnouncedAgentOnce(t *testing.T) {
	r := newWSLanesRig(t)
	ctx, now := context.Background(), time.Now()
	mac := r.e.box(r.w1, "mbp-"+newTenantID(""))
	r.e.pin(r.w1, mac)
	w2Pub, _, _ := ed25519.GenerateKey(nil)
	r.e.pinKey(r.w2, mac.id, w2Pub) // the same box id, its own key in w2
	for _, w := range []string{r.w1, r.w2} {
		if err := r.e.st.SetRoster(ctx, w, mac.id, []string{"c-709", "c-711"}, now); err != nil {
			t.Fatal(err)
		}
		if err := r.e.st.TouchBox(ctx, w, mac.id, now); err != nil {
			t.Fatal(err)
		}
	}
	lane := store.FleetLane{Fleet: "main", AgentID: "c-711", AgentBox: mac.id, Scope: "w2 work", Topic: store.LaneUnknown, IssueKey: store.LaneUnknown, State: "live", Files: []string{}}
	if _, err := r.e.st.PutFleetLane(ctx, r.w2, lane, mac.id, now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	count := map[string]int{}
	for _, l := range getLanes(t, r.fleetTokensRig).Lanes {
		if l.AgentBox == mac.id {
			count[l.AgentID]++
		}
	}
	if count["c-709"] != 1 || count["c-711"] != 1 || len(count) != 2 {
		t.Errorf("C81 operator rows of the shared box %v, want c-709 and c-711 once each", count)
	}
	if v, _ := wsLanes(t, r, r.w1, r.w1Admin, http.StatusOK); !slices.Contains(laneKeys(v), "c-709") || !slices.Contains(laneKeys(v), "c-711") {
		t.Errorf("C81 w1's own view %v, want its announced c-709 and c-711", laneKeys(v))
	}
}
