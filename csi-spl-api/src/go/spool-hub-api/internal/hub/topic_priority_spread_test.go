package hub_test

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 150 section 3.4 item 4, v1.3 (SPL-5223; owner HUM-10, t1 20da7236,
// msgs 76af2576 and 01c1f25e): the last prio change wins, both ways. An
// issue's own change sets every discussion it links (the default discussion
// left out), their other issues follow, and lanes follow their issues; the
// 5-min sweep never undoes a newer change. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// patchPrio sets an issue's priority as hum, the way the WUI does.
func patchPrio(t *testing.T, e *env, tid, hum, key string, prio int) {
	t.Helper()
	if code, out := call(t, e, tid, http.MethodPatch, "/v1/issues/"+key, hum, map[string]any{"priority": prio}); code != http.StatusOK {
		t.Fatalf("PATCH %s priority %d: %d %v", key, prio, code, out)
	}
}

// topicPrio is the priority stored for task in tid, 0 when none is set.
func topicPrio(t *testing.T, e *env, tid, task string) int {
	t.Helper()
	got, err := e.st.(store.TopicPriorityStore).SetTopicPriorities(context.Background(), tid, []string{task})
	if err != nil {
		t.Fatal(err)
	}
	return got[task]
}

// linkTopic links one more discussion to an issue.
func linkTopic(t *testing.T, e *env, tid, hum, key, task string) {
	t.Helper()
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues/"+key+"/discussions", hum, map[string]any{"discussion": task}); code != http.StatusOK {
		t.Fatalf("link %s to %s: %d %v", task, key, code, out)
	}
}

// C150-F5: an issue linked to two discussions is set by hand; both
// discussions take it, the other issue of one of them and its lane follow,
// and the sweep keeps it. RED CONTROL (master 35927a0d8): the discussions
// stay at 3 and the sweep puts the issue back to 3.
func TestIssuePrioritySpreadsToDiscussions(t *testing.T) {
	r := newFleetTokensRig(t)
	talkA, talkB := uid.New(), uid.New()
	lobbyTopic(t, r.e, r.op, talkA, "## Spread A\n\nrow")
	lobbyTopic(t, r.e, r.op, talkB, "## Spread B\n\nrow")
	k := issueWithPrio(t, r.e, r.op, r.admin, "born of A", talkA, 5)
	linkTopic(t, r.e, r.op, r.admin, k, talkB)
	sib := issueWithPrio(t, r.e, r.op, r.admin, "sibling on B", talkB, 5)
	laneAt(t, r, "c-661", r.opBox.id, talkB, sib, time.Now().Add(-time.Minute))
	for _, task := range []string{talkA, talkB} {
		if code, out := putPriority(t, r.e, r.op, task, r.admin, map[string]any{"priority": 3}); code != http.StatusOK {
			t.Fatalf("PUT priority: %d %v", code, out)
		}
	}
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 3 {
		t.Fatalf("before: issue prio %d, want 3 from its discussions", got)
	}

	patchPrio(t, r.e, r.op, r.admin, k, 1)
	if a, b := topicPrio(t, r.e, r.op, talkA), topicPrio(t, r.e, r.op, talkB); a != 1 || b != 1 {
		t.Errorf("C150-F5 the issue's discussions: A %d, B %d; want 1 and 1", a, b)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, sib); got != 1 {
		t.Errorf("C150-F5 the other issue of B: prio %d, want 1", got)
	}
	if p, _ := prioOf(t, prioLanes(t, r.e, r.ws, r.op, fleetLanesPath, r.admin), "c-661"); p != 1 {
		t.Errorf("C150-F5 the lane of the other issue: prio %d, want 1", p)
	}
	prioSync(t, r, "dry_run=0")
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 1 {
		t.Errorf("C150-F5 the sweep undid a newer issue change: prio %d, want 1", got)
	}

	// A later discussion change works as today: B's issues take it, k
	// keeps the highest of its discussions (A is still 1).
	if code, out := putPriority(t, r.e, r.op, talkB, r.admin, map[string]any{"priority": 4}); code != http.StatusOK {
		t.Fatalf("PUT B 4: %d %v", code, out)
	}
	if s, i := issuePrio(t, r.e, r.op, r.admin, sib), issuePrio(t, r.e, r.op, r.admin, k); s != 4 || i != 1 {
		t.Errorf("C150-F5 discussion change after the issue's: sibling %d, issue %d; want 4 and 1", s, i)
	}
	if ch, _ := ownChanges(r, prioSync(t, r, "dry_run=0"))["changes"].([]any); len(ch) != 0 {
		t.Errorf("C150-F5 sweep after both changes moves issues: %v", ch)
	}
}

// C150-F6: two issues on one discussion, set one after the other: the
// newest wins everywhere and the sweep does not flip them back and forth.
// RED CONTROL (master 35927a0d8): the discussion stays at 3, and the sweep
// puts both issues back to 3.
func TestIssuePriorityLastChangeWins(t *testing.T) {
	r := newFleetTokensRig(t)
	talk := uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Last wins\n\nrow")
	a := issueWithPrio(t, r.e, r.op, r.admin, "first", talk, 5)
	b := issueWithPrio(t, r.e, r.op, r.admin, "second", talk, 5)
	if code, out := putPriority(t, r.e, r.op, talk, r.admin, map[string]any{"priority": 3}); code != http.StatusOK {
		t.Fatalf("PUT priority: %d %v", code, out)
	}
	patchPrio(t, r.e, r.op, r.admin, a, 2)
	patchPrio(t, r.e, r.op, r.admin, b, 4)
	for i := 0; i < 2; i++ {
		if got := topicPrio(t, r.e, r.op, talk); got != 4 {
			t.Errorf("C150-F6 run %d: discussion prio %d, want the newest 4", i, got)
		}
		if pa, pb := issuePrio(t, r.e, r.op, r.admin, a), issuePrio(t, r.e, r.op, r.admin, b); pa != 4 || pb != 4 {
			t.Errorf("C150-F6 run %d: issues %d and %d, want 4 and 4", i, pa, pb)
		}
		prioSync(t, r, "dry_run=0")
	}
}

// C150-F7: the fleet's lane issue in the operator workspace links the
// owner's topic in another workspace: its change sets that topic there, and
// that workspace's own issue on it follows. An issue of the other
// workspace that links an operator topic (a relay copy) writes its own
// workspace's row only, never the operator workspace's. RED CONTROL (master 35927a0d8): the far
// topic stays unset.
func TestIssuePrioritySpreadAcrossWorkspaces(t *testing.T) {
	r := newFleetTokensRig(t)
	far := uid.New()
	lobbyTopic(t, r.e, r.other, far, "## Far\n\nrow")
	relayCopy(t, r.e, r.op, far)
	kOp := issueWithPrio(t, r.e, r.op, r.admin, "lane issue on a far topic", far, 5)
	kOther := issueWithPrio(t, r.e, r.other, r.otherA, "owner issue on it", far, 5)

	patchPrio(t, r.e, r.op, r.admin, kOp, 2)
	if got := topicPrio(t, r.e, r.other, far); got != 2 {
		t.Errorf("C150-F7 the far topic in its own workspace: prio %d, want 2", got)
	}
	if got := topicPrio(t, r.e, r.op, far); got != 0 {
		t.Errorf("C150-F7 a row in the operator workspace for a far topic: prio %d, want none", got)
	}
	if got := issuePrio(t, r.e, r.other, r.otherA, kOther); got != 2 {
		t.Errorf("C150-F7 the far workspace's issue: prio %d, want 2", got)
	}

	opTalk := uid.New()
	lobbyTopic(t, r.e, r.op, opTalk, "## Operator topic\n\nrow")
	relayCopy(t, r.e, r.other, opTalk)
	kRelay := issueWithPrio(t, r.e, r.other, r.otherA, "issue on a relay copy", opTalk, 5)
	patchPrio(t, r.e, r.other, r.otherA, kRelay, 1)
	if got := topicPrio(t, r.e, r.op, opTalk); got != 0 {
		t.Errorf("C150-F7 tenant isolation: the other workspace wrote the operator's topic prio %d", got)
	}
	if got := topicPrio(t, r.e, r.other, opTalk); got != 1 {
		t.Errorf("C150-F7 the other workspace's own row for its copy: prio %d, want 1", got)
	}
}

// C150-F8: an issue change whose spread did not happen (written past the
// hub, as a failed apply leaves it): the sweep's dry run lists the spread
// and moves nothing, its apply sets the discussion and leaves the issue.
// RED CONTROL (agentPrioSync's run with spread false): the answer lists no
// spread and the discussion stays at 3.
func TestIssuePrioritySweepSpreads(t *testing.T) {
	r := newFleetTokensRig(t)
	talk := uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Sweep spreads\n\nrow")
	k := issueWithPrio(t, r.e, r.op, r.admin, "missed spread", talk, 5)
	if code, out := putPriority(t, r.e, r.op, talk, r.admin, map[string]any{"priority": 3}); code != http.StatusOK {
		t.Fatalf("PUT priority: %d %v", code, out)
	}
	n, _ := store.ParseIssueRef(k)
	one := 1
	if _, err := r.e.st.(store.Issues).UpdateIssue(context.Background(), r.op, n, store.IssuePatch{Priority: &one, PriorityOwn: true}, "HUM-1", time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	dry := prioSync(t, r, "")
	if got := fmt.Sprint(ownSpread(r, dry)); got != fmt.Sprintf("[map[from:3 key:%s to:1 topic:%s workspace:%s]]", k, talk, r.op) {
		t.Errorf("C150-F8 dry run spread: %s", got)
	}
	if got := topicPrio(t, r.e, r.op, talk); got != 3 {
		t.Errorf("C150-F8 dry run wrote the discussion: %d, want 3", got)
	}
	prioSync(t, r, "dry_run=0")
	if d, i := topicPrio(t, r.e, r.op, talk), issuePrio(t, r.e, r.op, r.admin, k); d != 1 || i != 1 {
		t.Errorf("C150-F8 apply: discussion %d, issue %d; want 1 and 1", d, i)
	}
	if sp := ownSpread(r, prioSync(t, r, "dry_run=0")); len(sp) != 0 {
		t.Errorf("C150-F8 second apply is not a no-op: %v", sp)
	}
}

// ownSpread is the answer's spreads of the rig's workspaces.
func ownSpread(r *fleetTokensRig, out map[string]any) []any {
	sp, _ := out["spread"].([]any)
	keep := []any{}
	for _, c := range sp {
		if m, _ := c.(map[string]any); r.ws[fmt.Sprint(m["workspace"])] {
			keep = append(keep, c)
		}
	}
	return keep
}
