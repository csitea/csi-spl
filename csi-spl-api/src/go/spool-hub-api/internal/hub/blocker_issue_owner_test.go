package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// An owner question becomes an issue only when the owner decides (owner
// HUM-10, t1 5ea2e615 msg db5ed497): the sweep skips a workspace owner, and
// POST /v1/messages/{msg_id}/issue is the owner's decision. Memory, and
// Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

func TestBlockerToOwnerMakesNoIssue(t *testing.T) {
	r := newBlockerRig(t)
	owner := seat(t, r.e, r.tid, rbac.BizOwner)
	r.post(t, r.tid, uid.New(), r.agent, owner, "blocker", "which bucket?", r.base)
	r.post(t, r.tid, uid.New(), r.admin, "ALL-0", "blocker", "@"+owner+" and the dev one?", r.base)
	if got := r.sweep(30 * time.Minute); got.Created != 0 {
		t.Fatalf("an owner tagged: created %d, want 0", got.Created)
	}
	if n := len(r.blockerIssues(t, r.tid)); n != 0 {
		t.Fatalf("an owner tagged: %d issues, want 0", n)
	}
	// CONTROL: the same sweep still converts a blocker to an agent.
	r.post(t, r.tid, uid.New(), r.admin, "ALL-0", "blocker", "@"+r.agent+" the build is red", r.base)
	r.sweep(31 * time.Minute)
	is := r.blockerIssues(t, r.tid)
	if len(is) != 1 || is[0].Assignee != r.agent {
		t.Fatalf("CONTROL: a blocker to an agent: want 1 issue for %s, got %+v", r.agent, is)
	}
}

func TestOwnerMakesIssueOfBlocker(t *testing.T) {
	r := newBlockerRig(t)
	owner := seat(t, r.e, r.tid, rbac.BizOwner)
	task := uid.New()
	id := r.post(t, r.tid, task, r.agent, owner, "blocker", "Rotate the prd key?\nmore", r.base)
	r.sweep(10 * time.Minute)
	path := "/v1/messages/" + id + "/issue"

	if code, _ := call(t, r.e, r.tid, http.MethodPost, path, r.target, map[string]any{}); code != http.StatusForbidden {
		t.Fatalf("a developer: %d, want 403", code)
	}
	if code, _ := call(t, r.e, r.tid, http.MethodPost, path, owner, map[string]any{"assignee": r.target}); code != http.StatusBadRequest {
		t.Fatalf("an assignee the blocker does not tag: %d, want 400", code)
	}
	code, out := call(t, r.e, r.tid, http.MethodPost, path, owner, map[string]any{})
	if code != http.StatusCreated {
		t.Fatalf("the owner decides: %d %v", code, out)
	}
	is := r.blockerIssues(t, r.tid)
	if len(is) != 1 {
		t.Fatalf("want 1 issue, got %d", len(is))
	}
	i := is[0]
	if i.Assignee != owner || i.CreatedBy != owner || i.Status != store.IssueTodo || i.Title != "Rotate the prd key?" ||
		!strings.Contains(i.Description, "(/m/"+id+")") || i.TaskID != store.BlockerIssueTask(r.tid, id, owner) {
		t.Fatalf("issue %+v", i)
	}
	if code, out := call(t, r.e, r.tid, http.MethodPost, path, owner, nil); code != http.StatusOK ||
		out["issue"].(map[string]any)["key"] != i.Key() {
		t.Fatalf("a second call: %d %v, want 200 with %s", code, out, i.Key())
	}
	// The answer link is unchanged: the owner answers in the topic, the
	// issue resolves and the mark clears.
	r.post(t, r.tid, task, owner, r.agent, "note", "yes, rotate it", r.base.Add(20*time.Minute))
	if got := r.sweep(21 * time.Minute); got.Resolved != 1 {
		t.Fatalf("the owner's answer: resolved %d, want 1", got.Resolved)
	}
	if k := r.kindOf(t, id); k == "blocker" {
		t.Fatalf("the mark stayed after the issue resolved")
	}
	if code, _ := call(t, r.e, r.tid, http.MethodPost, path, owner, nil); code != http.StatusConflict {
		t.Fatalf("no mark any more: %d, want 409", code)
	}
}

func TestOwnerIssueResolvesWhenMarkCleared(t *testing.T) {
	r := newBlockerRig(t)
	owner := seat(t, r.e, r.tid, rbac.BizOwner)
	id := r.post(t, r.tid, uid.New(), r.agent, owner, "blocker", "go?", r.base)
	r.sweep(5 * time.Minute)
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/messages/"+id+"/issue", owner, nil); code != http.StatusCreated {
		t.Fatalf("make issue: %d %v", code, out)
	}
	if code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/messages/"+id+"/kind", owner, map[string]string{"kind": "note"}); code != http.StatusOK {
		t.Fatalf("clear mark: %d %v", code, out)
	}
	if is := r.blockerIssues(t, r.tid); len(is) != 1 || is[0].Status != store.IssueDone {
		t.Fatalf("clearing the mark: %+v, want 1 done", is)
	}
}

// A question to the owner in an issue's own topic holds that issue: blocked +
// needs-owner + one line, no new issue; the owner's answer takes it off and
// the status goes back (spec 135 section 9 Q2 A, owner f2c24a7b).
func TestOwnerQuestionHoldsItsIssue(t *testing.T) {
	r := newBlockerRig(t)
	owner := seat(t, r.e, r.tid, rbac.BizOwner)
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/issues", r.admin, map[string]any{"title": "Auth", "kind": "epic"}); code != http.StatusCreated {
		t.Fatalf("epic: %d %v", code, out)
	}
	code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/issues", r.admin, map[string]any{"epic": "SPL-1",
		"title": "Rotate keys", "description": "the plan", "status": store.IssueWIP})
	if code != http.StatusCreated {
		t.Fatalf("issue: %d %v", code, out)
	}
	is := r.e.st.(store.Issues)
	get := func() store.Issue {
		t.Helper()
		i, err := is.GetIssue(context.Background(), r.tid, 2)
		if err != nil {
			t.Fatal(err)
		}
		return i
	}
	task := get().TaskID
	id := r.post(t, r.tid, task, r.agent, owner, "blocker", "rotate prd too?", r.base)
	for _, d := range []time.Duration{10 * time.Minute, 11 * time.Minute} {
		if got := r.sweep(d); got.Created != 0 {
			t.Fatalf("an owner question in the issue topic: created %d, want 0", got.Created)
		}
	}
	held := get()
	line := "answer [the question](/m/" + id + ") (was wip)"
	if held.Status != store.IssueBlocked || !hasLabel(held.Labels, "needs-owner") ||
		strings.Count(held.Description, line) != 1 || !strings.HasPrefix(held.Description, "the plan\n\n**Needs owner** since ") {
		t.Fatalf("held: %+v", held)
	}
	if n := len(r.blockerIssues(t, r.tid)); n != 0 {
		t.Fatalf("held: %d blocker issues, want 0", n)
	}
	// CONTROL: a question to an agent in another topic is unchanged, and it
	// does not touch this issue.
	r.post(t, r.tid, uid.New(), r.admin, r.agent, "blocker", "the build is red", r.base.Add(time.Minute))
	r.sweep(12 * time.Minute)
	if n := len(r.blockerIssues(t, r.tid)); n != 1 {
		t.Fatalf("CONTROL: a blocker to an agent: %d issues, want 1", n)
	}
	// The owner answers in the topic: the hold goes, wip comes back.
	r.post(t, r.tid, task, owner, r.agent, "note", "yes", r.base.Add(20*time.Minute))
	r.sweep(21 * time.Minute)
	freed := get()
	if freed.Status != store.IssueWIP || hasLabel(freed.Labels, "needs-owner") || freed.Description != "the plan" {
		t.Fatalf("after the answer: %+v", freed)
	}
}

func hasLabel(ls []string, l string) bool {
	for _, x := range ls {
		if x == l {
			return true
		}
	}
	return false
}
