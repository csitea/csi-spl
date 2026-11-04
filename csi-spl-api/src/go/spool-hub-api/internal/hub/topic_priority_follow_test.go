package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 150 section 3.4 item 4 (SPL-4813; owner HUM-10, csitea b0f50875,
// msgs ee3d6efc and f061e485): the discussion's priority is the source. An
// issue follows the highest priority SET on its linked discussions (the
// workspace's default discussion does not count), and a lane shows the
// highest of its issues, so a lane on a priority 1 discussion shows 1.
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// issuePrio is one issue's stored priority, read through the hub.
func issuePrio(t *testing.T, e *env, tid, hum, key string) int {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues/"+key, hum, nil)
	if code != http.StatusOK {
		t.Fatalf("GET issue %s: %d %v", key, code, out)
	}
	p, _ := issueOf(t, out)["priority"].(float64)
	return int(p)
}

// relayCopy stores in tid a post of another workspace's topic task, as the
// fleet relay leaves one (prd: t1 holds 2 posts of csitea's 269d405d, so a
// t1 issue may link it).
func relayCopy(t *testing.T, e *env, tid, task string) {
	t.Helper()
	at := time.Now().UTC()
	m := store.Message{TenantID: tid, MsgID: uid.New(), TaskID: task, Channel: store.ChannelLobby, TS: at,
		FromBox: "box-wui", FromID: "HUM-1", ToBox: "box-wui", ToID: "ALL-0", Kind: "note", Body: "relayed",
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte(`{"env":1}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour), IsParent: 1}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
}

// C150-F1: the owner sets a discussion's priority AFTER its lane and issue
// exist; the PUT moves the issue and the lane shows it at once. An issue on
// the default discussion only, and a lane on an unset discussion, keep their
// own. RED CONTROL (master 77463637a): the lane stays at 5.
func TestTopicPriorityFollowsToIssuesAndLanes(t *testing.T) {
	r := newFleetTokensRig(t)
	talk, other := uid.New(), uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Prio follows\n\nrow")
	lobbyTopic(t, r.e, r.op, other, "## Unset\n\nrow")
	k := issueWithPrio(t, r.e, r.op, r.admin, "born of talk", talk, 5)
	issueWithPrio(t, r.e, r.op, r.admin, "born of other", other, 4)
	kDefault := issueWithPrio(t, r.e, r.op, r.admin, "default only", store.IssueDiscussionDefault(r.op), 5)
	laneAt(t, r, "c-651", r.opBox.id, talk, "", time.Now().Add(-time.Minute))
	laneAt(t, r, "c-652", r.opBox.id, other, "", time.Now().Add(-2*time.Minute))
	if p, _ := prioOf(t, prioLanes(t, r.e, r.ws, r.op, fleetLanesPath, r.admin), "c-651"); p != 5 {
		t.Fatalf("before: lane prio %d, want 5", p)
	}

	if code, out := putPriority(t, r.e, r.op, talk, r.admin, map[string]any{"priority": 1}); code != http.StatusOK {
		t.Fatalf("PUT priority: %d %v", code, out)
	}
	ls := prioLanes(t, r.e, r.ws, r.op, fleetLanesPath, r.admin)
	if p, is := prioOf(t, ls, "c-651"); p != 1 || is != k+" 1" {
		t.Errorf("C150-F1 lane on the priority 1 discussion: prio %d, issues %q; want 1 and %s 1", p, is, k)
	}
	if p, _ := prioOf(t, ls, "c-652"); p != 4 {
		t.Errorf("C150-F1 lane on an unset discussion: prio %d, want its issue's 4", p)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, kDefault); got != 5 {
		t.Errorf("C150-F1 issue on the default discussion only: prio %d, want its own 5", got)
	}

	// C150-F3: the fleet's lane issue sits in the operator workspace and
	// links the owner's topic in another workspace (csitea 269d405d, t1
	// SPL-4637): the other workspace's PUT moves it too. RED CONTROL: a run
	// that reads the operator workspace's own priorities only leaves it at 5.
	far := uid.New()
	lobbyTopic(t, r.e, r.other, far, "## Far\n\nrow")
	relayCopy(t, r.e, r.op, far)
	kFar := issueWithPrio(t, r.e, r.op, r.admin, "lane issue on a far topic", far, 5)
	laneAt(t, r, "c-653", r.opBox.id, far, kFar, time.Now().Add(-3*time.Minute))
	if code, out := putPriority(t, r.e, r.other, far, r.otherA, map[string]any{"priority": 2}); code != http.StatusOK {
		t.Fatalf("PUT far priority: %d %v", code, out)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, kFar); got != 2 {
		t.Errorf("C150-F3 operator issue on another workspace's topic: prio %d, want 2", got)
	}
	if p, _ := prioOf(t, prioLanes(t, r.e, r.ws, r.op, fleetLanesPath, r.admin), "c-653"); p != 2 {
		t.Errorf("C150-F3 its lane: prio %d, want 2", p)
	}

	// A later change follows too: the owner triages on discussions.
	if code, out := putPriority(t, r.e, r.op, talk, r.admin, map[string]any{"priority": 3}); code != http.StatusOK {
		t.Fatalf("PUT priority 3: %d %v", code, out)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 3 {
		t.Errorf("C150-F1 second set: issue prio %d, want 3", got)
	}
}

// prioSync runs the agent issue op prio-sync (the 5-min cron's call) from a
// box of the rig's operator workspace; its answer.
func prioSync(t *testing.T, r *fleetTokensRig, query string) map[string]any {
	t.Helper()
	ctx := context.Background()
	b := r.e.box(r.op, "box-"+newTenantID(""), "CLE-07")
	r.e.pin(r.op, b)
	sa, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	raw, err := action.Issue(ctx, b.cfg, action.IssueArgs{Op: "prio-sync", As: "CLE-07", Query: query, Hub: b.c})
	if err != nil {
		t.Fatalf("prio-sync %q: %v", query, err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("reply %s: %v", raw, err)
	}
	return out
}

// ownChanges keeps the answer's changes of the rig's workspaces (on the
// shared Postgres the operator workspace's sweep also walks other tests').
func ownChanges(r *fleetTokensRig, out map[string]any) map[string]any {
	ch, _ := out["changes"].([]any)
	keep := []any{}
	for _, c := range ch {
		if m, _ := c.(map[string]any); r.ws[fmt.Sprint(m["workspace"])] {
			keep = append(keep, c)
		}
	}
	out["changes"] = keep
	return out
}

// C150-F2: the sweep applies a priority stored without the PUT (a row set
// before this rule): a dry run lists the change and writes nothing;
// dry_run=0 writes it and counts the issues with no set discussion; a
// second run changes nothing. From the operator workspace it walks every
// workspace. RED CONTROL (master 77463637a): the op does
// not exist.
func TestTopicPrioritySyncOp(t *testing.T) {
	r := newFleetTokensRig(t)
	talk := uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Sweep\n\nrow")
	k := issueWithPrio(t, r.e, r.op, r.admin, "born of talk", talk, 5)
	issueWithPrio(t, r.e, r.op, r.admin, "default only", store.IssueDiscussionDefault(r.op), 5)
	far := uid.New()
	lobbyTopic(t, r.e, r.other, far, "## Far\n\nrow")
	relayCopy(t, r.e, r.op, far)
	kFar := issueWithPrio(t, r.e, r.op, r.admin, "lane issue on a far topic", far, 5)
	ps := r.e.st.(store.TopicPriorityStore)
	if _, err := ps.SetTopicPriority(context.Background(), r.op, talk, 2, "HUM-1", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := ps.SetTopicPriority(context.Background(), r.other, far, 1, "HUM-1", time.Now()); err != nil {
		t.Fatal(err)
	}
	dry := ownChanges(r, prioSync(t, r, ""))
	if dry["applied"] != false || fmt.Sprint(dry["changes"]) != fmt.Sprintf("[map[from:5 key:%s to:2 topic:%s workspace:%s] map[from:5 key:%s to:1 topic:%s workspace:%s]]", k, talk, r.op, kFar, far, r.op) {
		t.Errorf("C150-F2 dry run: %v", dry)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 5 {
		t.Errorf("C150-F2 dry run wrote: prio %d, want 5", got)
	}
	wet := ownChanges(r, prioSync(t, r, "dry_run=0"))
	if ch, _ := wet["changes"].([]any); wet["applied"] != true || len(ch) != 2 {
		t.Errorf("C150-F2 apply: %v", wet)
	}
	if n, _ := wet["unset"].(float64); n < 1 {
		t.Errorf("C150-F2 apply: unset %v, want the default-only issue counted", wet["unset"])
	}
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 2 {
		t.Errorf("C150-F2 apply: prio %d, want 2", got)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, kFar); got != 1 {
		t.Errorf("C150-F2 apply, operator issue on another workspace's topic: prio %d, want 1", got)
	}
	if ws := fmt.Sprint(wet["workspaces"]); !strings.Contains(ws, r.op) || !strings.Contains(ws, r.other) {
		t.Errorf("C150-F2 the operator workspace sweeps every workspace: %v", ws)
	}
	if ch, _ := ownChanges(r, prioSync(t, r, "dry_run=0"))["changes"].([]any); len(ch) != 0 {
		t.Errorf("C150-F2 second apply is not a no-op: %v", ch)
	}
}
