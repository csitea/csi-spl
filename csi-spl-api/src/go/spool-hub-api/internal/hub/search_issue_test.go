package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Grammar 1.2 (CLE-34992, spec 039): the issue section. CONTROLS: another
// tenant's issues never appear; a plain query does not search issues (opt-in);
// assignee:me is the reader, and no reader matches nobody.
func TestSearchIssues(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.SearchRatePerMin = 1000
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) { return r.Header.Get("X-Test-Human"), nil }
	})
	ctx, now := context.Background(), time.Now().UTC()
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	is := e.st.(store.Issues)
	for _, tn := range []string{ta, tb} {
		if _, err := is.CreateIssueLabel(ctx, store.IssueLabel{TenantID: tn, LabelID: "perf", Name: "perf", CreatedBy: "HUM-1"}, now); err != nil {
			t.Fatal(err)
		}
	}
	// SPL-18: every issue has a parent epic. One per tenant, priority 2 and
	// assigned to HUM-9 so the priority:0 / assignee:none rows stay the issues'.
	epics := map[string]store.Issue{}
	for _, tn := range []string{ta, tb} {
		if _, err := is.CreateIssueLabel(ctx, store.IssueLabel{TenantID: tn, LabelID: store.IssueEpicLabel, Name: store.IssueEpicLabel, CreatedBy: "HUM-1"}, now); err != nil {
			t.Fatal(err)
		}
		ep, err := is.CreateIssue(ctx, store.Issue{TenantID: tn, Title: "Epic", Priority: 2, Assignee: "HUM-9",
			Labels: []string{store.IssueEpicLabel}, TaskID: uuidV4(), CreatedBy: "HUM-1"}, now)
		if err != nil {
			t.Fatal(err)
		}
		epics[tn] = ep
	}
	mk := func(tn, title, desc, status, assignee string, prio int, labels ...string) store.Issue {
		t.Helper()
		it, err := is.CreateIssue(ctx, store.Issue{TenantID: tn, Title: title, Description: desc, Status: status, Priority: prio,
			Assignee: assignee, Labels: labels, TaskID: uuidV4(), CreatedBy: "HUM-1", Parent: epics[tn].Number}, now)
		if err != nil {
			t.Fatal(err)
		}
		return it
	}
	slow := mk(ta, "Search is slow", "the topic section scans the tenant", store.IssueInProgress, "HUM-3", 1, "perf")
	cafe := mk(ta, "Café menu", "", store.IssueTodo, "", 0)
	mk(tb, "Search is slow in tenant B", "", store.IssueInProgress, "HUM-3", 1, "perf") // CONTROL: other tenant

	keys := func(q, who string) []string {
		t.Helper()
		code, _, r, _ := searchGet(t, e, ta, q, "", "X-Test-Human", who)
		if code != http.StatusOK {
			t.Fatalf("%q: %d", q, code)
		}
		var out []string
		for _, row := range r.Groups["issues"].Results {
			out = append(out, row["key"].(string))
		}
		return out
	}
	want := func(q, who string, exp ...string) {
		t.Helper()
		got := keys(q, who)
		if len(got) != len(exp) {
			t.Fatalf("%q as %q: %v, want %v", q, who, got, exp)
		}
		for i := range exp {
			if got[i] != exp[i] {
				t.Fatalf("%q as %q: %v, want %v", q, who, got, exp)
			}
		}
	}
	want("type:issue", "HUM-3", cafe.Key(), slow.Key(), epics[ta].Key()) // newest number first, tenant A only
	want("type:issue scans", "HUM-3", slow.Key())                        // the description is content
	want("type:issue cafe", "HUM-3", cafe.Key())                         // folded
	want("type:issue name:"+slow.Key(), "HUM-3", slow.Key())
	want("status:in_progress", "HUM-3", slow.Key()) // implies type:issue
	want("priority:0", "HUM-3", cafe.Key())
	want("assignee:me", "HUM-3", slow.Key())
	want("assignee:me", "HUM-4")
	want("assignee:none", "HUM-3", cafe.Key())
	want("label:PERF", "HUM-3", slow.Key())
	// CONTROL: plain words do not search issues
	if _, _, r, _ := searchGet(t, e, ta, "slow", "", "X-Test-Human", "HUM-3"); len(r.Groups["issues"].Results) != 0 {
		t.Fatalf("plain query searched issues: %+v", r.Groups["issues"])
	}
	// the row
	_, _, r, _ := searchGet(t, e, ta, "type:issue slow", "", "X-Test-Human", "HUM-3")
	row := r.Groups["issues"].Results[0]
	if row["status"] != store.IssueInProgress || row["priority"] != float64(1) || row["assignee"] != "HUM-3" || row["task_id"] != slow.TaskID {
		t.Fatalf("issue row: %+v", row)
	}
	// 400 bad_query for a status outside the workflow
	if code, _, _, raw := searchGet(t, e, ta, "status:open", "", "X-Test-Human", "HUM-3"); code != http.StatusBadRequest || raw["error"] != "bad_query" {
		t.Fatalf("status:open: %d %v", code, raw)
	}
}
