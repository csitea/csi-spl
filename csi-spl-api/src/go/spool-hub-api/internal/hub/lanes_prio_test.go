package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 153 section 3.14 (SPL-4727; owner HUM-10, t1 0d0bc34c, msgs 136f2e49
// and c78812f2): every lane row carries its prio, the highest among its
// issues, read in the one issue read the view already makes. Memory, and
// Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// laneIssueReads counts the store's FleetLaneIssues calls: the lanes views'
// one read of issue status and prio.
type laneIssueReads struct{ n atomic.Int64 }

type countingMemory struct {
	*store.Memory
	c *laneIssueReads
}

func (m countingMemory) FleetLaneIssues(ctx context.Context, tenant string, topics []string, numbers []int) (map[string][]int, map[int]store.FleetLaneIssue, error) {
	m.c.n.Add(1)
	return m.Memory.FleetLaneIssues(ctx, tenant, topics, numbers)
}

type countingPostgres struct {
	*store.Postgres
	c *laneIssueReads
}

func (p countingPostgres) FleetLaneIssues(ctx context.Context, tenant string, topics []string, numbers []int) (map[string][]int, map[int]store.FleetLaneIssue, error) {
	p.c.n.Add(1)
	return p.Postgres.FleetLaneIssues(ctx, tenant, topics, numbers)
}

// countLaneIssueReads wraps the hub's store (the rig seeds through the
// unwrapped one) so every FleetLaneIssues call is counted.
func countLaneIssueReads(c *laneIssueReads) func(*hub.Options) {
	return func(o *hub.Options) {
		switch st := o.Store.(type) {
		case *store.Memory:
			o.Store = countingMemory{st, c}
		case *store.Postgres:
			o.Store = countingPostgres{st, c}
		}
	}
}

type prioLane struct {
	AgentID   string `json:"agent_id"`
	Workspace string `json:"workspace"`
	Priority  int    `json:"priority"`
	Issues    []struct {
		Key      string `json:"key"`
		Priority int    `json:"priority"`
	} `json:"issues"`
}

// prioLanes is one GET of path in tid as hum: each lane of the rig's own
// workspaces (ws) by agent id (on a shared Postgres the operator view also
// lists other tests' workspaces, 3.17).
func prioLanes(t *testing.T, e *env, ws map[string]bool, tid, path, hum string) map[string]prioLane {
	t.Helper()
	code, body := call(t, e, tid, http.MethodGet, path, hum, nil)
	if code != http.StatusOK {
		t.Fatalf("GET %s: %d %v", path, code, body)
	}
	raw, _ := json.Marshal(body["lanes"])
	var rows []prioLane
	if err := json.Unmarshal(raw, &rows); err != nil {
		t.Fatal(err)
	}
	out := map[string]prioLane{}
	for _, l := range rows {
		if ws[l.Workspace] {
			out[l.AgentID] = l
		}
	}
	return out
}

// issueWithPrio files an issue in tid at prio, linking disc; its key.
func issueWithPrio(t *testing.T, e *env, tid, hum, title, disc string, prio int) string {
	t.Helper()
	code, out := call(t, e, tid, http.MethodPost, "/v1/issues", hum, map[string]any{"title": title, "priority": prio, "discussions": []string{disc}})
	if code != http.StatusCreated {
		t.Fatalf("issue %s: %d %v", title, code, out)
	}
	return fmt.Sprint(issueOf(t, out)["key"])
}

// prioOf is one lane's prio and its issues as "KEY prio" words.
func prioOf(t *testing.T, ls map[string]prioLane, agent string) (int, string) {
	t.Helper()
	l, ok := ls[agent]
	if !ok {
		t.Errorf("lane %s absent", agent)
		return 0, ""
	}
	words := []string{}
	for _, i := range l.Issues {
		words = append(words, fmt.Sprintf("%s %d", i.Key, i.Priority))
	}
	return l.Priority, strings.Join(words, ",")
}

// C61: the operator route sends each issue's prio and the lane's prio, the
// highest (lowest number) among its issues; a lane with no issue, or only
// a key of another prefix, sends none. RED CONTROL (master dd281db78): no
// lane and no issue carried a priority (every value 0).
func TestFleetLanesPrio(t *testing.T) {
	r := newFleetTokensRig(t)
	now := time.Now()
	box := r.opBox.id
	talk := uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Prio column\n\nrow")
	k1 := issueWithPrio(t, r.e, r.op, r.admin, "three", talk, 3)
	k2 := issueWithPrio(t, r.e, r.op, r.admin, "one", store.IssueDiscussionDefault(r.op), 1)
	k3 := issueWithPrio(t, r.e, r.op, r.admin, "four", talk, 4)

	laneAt(t, r, "c-611", box, talk, k2, now.Add(-1*time.Minute)) // topic 3 and 4, own key 1
	laneAt(t, r, "c-612", box, talk, "", now.Add(-2*time.Minute)) // topic 3 and 4
	laneAt(t, r, "c-613", box, "", "", now.Add(-3*time.Minute))   // no issue
	laneAt(t, r, "c-614", box, "", "OPS-7", now.Add(-4*time.Minute))

	ls := prioLanes(t, r.e, r.ws, r.op, fleetLanesPath, r.admin)
	if p, is := prioOf(t, ls, "c-611"); p != 1 || is != k1+" 3,"+k2+" 1,"+k3+" 4" {
		t.Errorf("C61 c-611: prio %d, issues %q; want 1 and %s 3,%s 1,%s 4", p, is, k1, k2, k3)
	}
	if p, is := prioOf(t, ls, "c-612"); p != 3 || is != k1+" 3,"+k3+" 4" {
		t.Errorf("C61 c-612: prio %d, issues %q; want 3", p, is)
	}
	if p, _ := prioOf(t, ls, "c-613"); p != 0 {
		t.Errorf("C61 no issue: prio %d, want none", p)
	}
	if p, is := prioOf(t, ls, "c-614"); p != 0 || is != "OPS-7 0" {
		t.Errorf("C61 another prefix: prio %d, issues %q; want none and OPS-7 with none", p, is)
	}
}

// C61b: the workspace route sends the prio of the workspace's own issues on
// the topic. RED CONTROL (master dd281db78): priority 0.
func TestWorkspaceLanesPrio(t *testing.T) {
	r := newWSLanesRig(t)
	k := issueWithPrio(t, r.e, r.w1, r.w1Admin, "two", r.t1, 2)
	issueWithPrio(t, r.e, r.w1, r.w1Admin, "five", r.t1, 5)
	laneAt(t, r.fleetTokensRig, "c-621", r.opBox.id, r.t1, "", time.Now().Add(-time.Minute))
	ls := prioLanes(t, r.e, r.ws, r.w1, workspaceLanesPath, r.w1Admin)
	if p, is := prioOf(t, ls, "c-621"); p != 2 || !strings.HasPrefix(is, k+" 2,") {
		t.Errorf("C61b w1 lane: prio %d, issues %q; want 2 from %s", p, is, k)
	}
}

// C62: the prio rides the one issue read: each GET of either route makes
// exactly one FleetLaneIssues call, for 2 lanes and for 12, never one per
// row. RED CONTROL: a per-row read (the call moved into the row loop)
// counts 2 and 12.
func TestLanesPrioOneIssueRead(t *testing.T) {
	reads := &laneIssueReads{}
	r := newWSLanesRig(t, countLaneIssueReads(reads))
	issueWithPrio(t, r.e, r.op, r.admin, "op", store.IssueDiscussionDefault(r.op), 2)
	issueWithPrio(t, r.e, r.w1, r.w1Admin, "w1", r.t1, 2)
	now := time.Now()
	for _, n := range []int{2, 12} {
		for i := 0; i < n; i++ {
			laneAt(t, r.fleetTokensRig, fmt.Sprintf("c-%03d", 640+i), r.opBox.id, r.t1, "SPL-1", now.Add(-time.Duration(i+1)*time.Second))
		}
		for _, g := range []struct{ tid, path, hum string }{{r.op, fleetLanesPath, r.admin}, {r.w1, workspaceLanesPath, r.w1Admin}} {
			reads.n.Store(0)
			if ls := prioLanes(t, r.e, r.ws, g.tid, g.path, g.hum); len(ls) < n {
				t.Fatalf("%s: %d lanes, want %d", g.path, len(ls), n)
			}
			if got := reads.n.Load(); got != 1 {
				t.Errorf("C62 %s with %d lanes: %d issue reads, want 1", g.path, n, got)
			}
		}
	}
}
