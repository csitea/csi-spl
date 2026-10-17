package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// SPL-2409: owner HUM-10 (t1 7a98c2d1, msgs ef77b762 + 5863d0d6): no issue
// without an epic. A blocker issue, made by the sweep or by the owner's "Make
// an issue", goes under the workspace's one blocker epic
// (hub.BlockerEpicTitle), made once when the workspace has none. Memory, and
// Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// blockerEpics is the tenant's epics titled hub.BlockerEpicTitle.
func (r *blockerRig) blockerEpics(t *testing.T, tid string) []store.Issue {
	t.Helper()
	all, err := r.e.st.(store.Issues).ListIssues(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	var out []store.Issue
	for _, i := range all {
		if i.IsEpic() && i.Title == hub.BlockerEpicTitle {
			out = append(out, i)
		}
	}
	return out
}

func TestBlockerIssueGoesUnderTheBlockerEpic(t *testing.T) {
	r := newBlockerRig(t)
	r.post(t, r.tid, uid.New(), r.admin, r.target, "blocker", "first", r.base)
	r.post(t, r.tid, uid.New(), r.admin, r.agent, "blocker", "second", r.base)
	if got := r.sweep(4 * time.Minute); got.Created != 2 {
		t.Fatalf("created %d, want 2", got.Created)
	}
	es := r.blockerEpics(t, r.tid)
	if len(es) != 1 {
		t.Fatalf("want exactly 1 blocker epic, got %d", len(es))
	}
	is := r.blockerIssues(t, r.tid)
	if len(is) != 2 {
		t.Fatalf("want 2 blocker issues, got %d", len(is))
	}
	for _, i := range is {
		if i.Parent != es[0].Number {
			t.Fatalf("%s: parent %d, want the blocker epic %s", i.Key(), i.Parent, es[0].Key())
		}
	}
	// A later sweep reuses it.
	r.post(t, r.tid, uid.New(), r.admin, r.bystand, "blocker", "third", r.base.Add(10*time.Minute))
	if got := r.sweep(15 * time.Minute); got.Created != 1 {
		t.Fatalf("second sweep: created %d, want 1", got.Created)
	}
	if n := len(r.blockerEpics(t, r.tid)); n != 1 {
		t.Fatalf("after a second sweep: %d blocker epics, want 1", n)
	}
	for _, i := range r.blockerIssues(t, r.tid) {
		if i.Parent != es[0].Number {
			t.Fatalf("%s: parent %d, want %s", i.Key(), i.Parent, es[0].Key())
		}
	}
	// Another workspace has no blocker, so no epic.
	if n := len(r.blockerEpics(t, r.otherTID)); n != 0 {
		t.Fatalf("the other workspace got %d blocker epics", n)
	}
}

func TestBlockerIssueReusesAnExistingEpicByTitle(t *testing.T) {
	r := newBlockerRig(t)
	code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/issues", r.admin, map[string]any{
		"title": hub.BlockerEpicTitle, "kind": store.IssueKindEpic, "discussions": []string{store.IssueDiscussionDefault(r.tid)}})
	if code != http.StatusCreated {
		t.Fatalf("seed the epic: %d %v", code, out)
	}
	pre := r.blockerEpics(t, r.tid)
	if len(pre) != 1 {
		t.Fatalf("seed: %d epics", len(pre))
	}
	r.post(t, r.tid, uid.New(), r.admin, r.target, "blocker", "under the old one", r.base)
	r.sweep(4 * time.Minute)
	if es := r.blockerEpics(t, r.tid); len(es) != 1 || es[0].Number != pre[0].Number {
		t.Fatalf("epics %+v, want only %s", es, pre[0].Key())
	}
	if is := r.blockerIssues(t, r.tid); len(is) != 1 || is[0].Parent != pre[0].Number {
		t.Fatalf("issues %+v, want 1 under %s", is, pre[0].Key())
	}
}

func TestOwnerMadeBlockerIssueGoesUnderTheBlockerEpic(t *testing.T) {
	r := newBlockerRig(t)
	owner := seat(t, r.e, r.tid, rbac.BizOwner)
	id := r.post(t, r.tid, uid.New(), r.agent, owner, "blocker", "go?", r.base)
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/messages/"+id+"/issue", owner, nil); code != http.StatusCreated {
		t.Fatalf("make issue: %d %v", code, out)
	}
	es := r.blockerEpics(t, r.tid)
	is := r.blockerIssues(t, r.tid)
	if len(es) != 1 || len(is) != 1 || is[0].Parent != es[0].Number {
		t.Fatalf("epics %+v issues %+v, want 1 issue under 1 blocker epic", es, is)
	}
}

// The owner exception reads the tenant_owner flag over the member's whole
// role set (025 §10.2): biz_owner anywhere in the set is the owner; admin
// alone and a plain member are not (spec 025 §2: "tenant owner = biz-owner",
// no separate owner flag on the membership).
func TestBlockerOwnerExceptionReadsTheRoleSet(t *testing.T) {
	r := newBlockerRig(t)
	adminOwner := seat(t, r.e, r.tid, rbac.Admin)
	if err := r.e.st.(store.Humans).SetMemberRoles(context.Background(), r.tid, adminOwner,
		[]string{rbac.Admin, rbac.BizOwner}, rbac.Admin, nil); err != nil {
		t.Fatal(err)
	}
	plainAdmin := seat(t, r.e, r.tid, rbac.Admin)
	for _, to := range []string{adminOwner, plainAdmin, r.target} {
		r.post(t, r.tid, uid.New(), r.agent, to, "blocker", "q for "+to, r.base)
	}
	r.sweep(4 * time.Minute)
	got := map[string]bool{}
	for _, i := range r.blockerIssues(t, r.tid) {
		got[i.Assignee] = true
	}
	if got[adminOwner] || !got[plainAdmin] || !got[r.target] || len(got) != 2 {
		t.Fatalf("issues for %v; want plain admin %s and member %s, none for admin+biz_owner %s",
			got, plainAdmin, r.target, adminOwner)
	}
}

// The epic closes and archives itself when its last open issue closes
// (SPL-1729); the next blocker then gets one new epic, on the next topic of
// the chain, never two.
func TestBlockerEpicClosedThenNextOne(t *testing.T) {
	r := newBlockerRig(t)
	id := r.post(t, r.tid, uid.New(), r.admin, r.target, "blocker", "first", r.base)
	r.sweep(4 * time.Minute)
	first := r.blockerEpics(t, r.tid)
	if len(first) != 1 {
		t.Fatalf("want 1 epic, got %d", len(first))
	}
	if code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/messages/"+id+"/kind", r.admin, map[string]string{"kind": "note"}); code != http.StatusOK {
		t.Fatalf("clear mark: %d %v", code, out)
	}
	if n := len(r.blockerEpics(t, r.tid)); n != 0 {
		t.Fatalf("the last issue closed: %d live epics, want 0 (closed and archived)", n)
	}
	r.post(t, r.tid, uid.New(), r.admin, r.target, "blocker", "second", r.base.Add(10*time.Minute))
	r.post(t, r.tid, uid.New(), r.admin, r.bystand, "blocker", "third", r.base.Add(10*time.Minute))
	if got := r.sweep(15 * time.Minute); got.Created != 2 {
		t.Fatalf("created %d, want 2", got.Created)
	}
	next := r.blockerEpics(t, r.tid)
	if len(next) != 1 || next[0].Number == first[0].Number || next[0].TaskID != hub.BlockerEpicTask(r.tid, first[0].Number) {
		t.Fatalf("epics %+v, want one new epic on the chain after %s", next, first[0].Key())
	}
	open := 0
	for _, i := range r.blockerIssues(t, r.tid) {
		if i.Status == store.IssueTodo {
			open++
			if i.Parent != next[0].Number {
				t.Fatalf("%s: parent %d, want %s", i.Key(), i.Parent, next[0].Key())
			}
		}
	}
	if open != 2 {
		t.Fatalf("%d open blocker issues, want 2", open)
	}
}
