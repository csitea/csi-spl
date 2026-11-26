package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Grammar 1.2 (spec 039): the issue section. CONTROLS: another
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
		ep, err := is.CreateIssue(ctx, store.Issue{Discussions: []string{testDiscussion}, TenantID: tn, Title: "Epic", Priority: 2, Assignee: "HUM-9",
			Labels: []string{store.IssueEpicLabel}, TaskID: uuidV4(), CreatedBy: "HUM-1"}, now)
		if err != nil {
			t.Fatal(err)
		}
		epics[tn] = ep
	}
	mk := func(tn, title, desc, status, assignee string, prio int, labels ...string) store.Issue {
		t.Helper()
		it, err := is.CreateIssue(ctx, store.Issue{Discussions: []string{testDiscussion}, TenantID: tn, Title: title, Description: desc, Status: status, Priority: prio,
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
	want("status:wip", "HUM-3", slow.Key())         // implies type:issue
	want("status:in_progress", "HUM-3", slow.Key()) // an older name still finds it (store.NormalizeIssueStatus)
	want("priority:5", "HUM-3", cafe.Key())         // prio 1..5 (rdb 0054): an unset priority is 5
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

// The status: row of the operators endpoint names the store's CURRENT
// workflow (SPL-966 adds blocked and onhold), so it cannot go stale.
// CONTROL: the static row in search.Operators does not list them.
func TestSearchOperatorsStatusDocFollowsStore(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	ta, _ := e.tenant()
	code, _, b := viewGet(t, e, ta, "/v1/view/search/operators")
	var ops struct {
		Operators []struct{ Name, Doc string } `json:"operators"`
	}
	if code != http.StatusOK || json.Unmarshal(b, &ops) != nil {
		t.Fatalf("operators: %d %s", code, b)
	}
	doc := ""
	for _, o := range ops.Operators {
		if o.Name == search.OpStatus {
			doc = o.Doc
		}
	}
	for _, s := range store.IssueStatuses {
		if !strings.Contains(doc, s) {
			t.Errorf("status: doc %q lacks %q", doc, s)
		}
	}
	for _, o := range search.Operators {
		if o.Name == search.OpStatus && strings.Contains(o.Doc, store.IssueStatuses[0]) {
			t.Errorf("control: the static row should not list the workflow: %q", o.Doc)
		}
	}
}

// Grammar 1.8 (spec 187 row S2, D23): key: is exactly one issue, epic: the
// issues and subtasks under a level-1 row (not the row itself), idle: /
// changed: an issue's last change. CONTROLS: key:<P>-1 is not <P>-10 or
// <P>-11; epic: never lists the epic; the other epic's issues stay out;
// key: on topics is a 400 bad_query.
func TestSearchIssuesKeyEpicIdle(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.SearchRatePerMin = 1000
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) { return r.Header.Get("X-Test-Human"), nil }
	})
	ctx, now := context.Background(), time.Now().UTC()
	ta, _ := e.tenant()
	is := e.st.(store.Issues)
	if _, err := is.CreateIssueLabel(ctx, store.IssueLabel{TenantID: ta, LabelID: store.IssueEpicLabel, Name: store.IssueEpicLabel, CreatedBy: "HUM-1"}, now); err != nil {
		t.Fatal(err)
	}
	mk := func(parent int, at time.Time, labels ...string) store.Issue {
		t.Helper()
		it, err := is.CreateIssue(ctx, store.Issue{Discussions: []string{testDiscussion}, TenantID: ta, Title: "work", Labels: labels,
			TaskID: uuidV4(), CreatedBy: "HUM-1", Parent: parent}, at)
		if err != nil {
			t.Fatal(err)
		}
		return it
	}
	day := 24 * time.Hour
	ep := mk(0, now, store.IssueEpicLabel) // #1
	var under []store.Issue                // #2..#11
	for range 10 {
		under = append(under, mk(ep.Number, now))
	}
	sub := mk(under[0].Number, now)                      // #12, a subtask: its epic is still #1
	ep2 := mk(0, now.Add(-31*day), store.IssueEpicLabel) // #13, not changed for 31 days
	old := mk(ep2.Number, now.Add(-31*day))              // #14
	if under[8].Number != 10 || sub.Number != 12 {
		t.Fatalf("numbering: %d %d", under[8].Number, sub.Number)
	}
	keys := func(q string) []string {
		t.Helper()
		code, _, r, raw := searchGet(t, e, ta, q, "", "X-Test-Human", "HUM-3")
		if code != http.StatusOK {
			t.Fatalf("%q: %d %v", q, code, raw)
		}
		out := []string{}
		for _, row := range r.Groups["issues"].Results {
			out = append(out, row["key"].(string))
		}
		return out
	}
	var underKeys []string
	for i := len(under) - 1; i >= 0; i-- { // newest number first
		underKeys = append(underKeys, under[i].Key())
	}
	for q, want := range map[string][]string{
		"key:" + ep.Key():                            {ep.Key()},
		"key:" + strings.ToLower(under[0].Key()):     {under[0].Key()},
		"epic:" + ep.Key():                           append([]string{sub.Key()}, underKeys...),
		"epic:" + ep2.Key():                          {old.Key()},
		"epic:" + ep2.Key() + " OR key:" + ep2.Key(): {old.Key(), ep2.Key()},
		"type:issue idle:30d":                        {old.Key(), ep2.Key()},
		"epic:" + ep.Key() + " idle:30d":             {},
		"epic:" + ep2.Key() + " idle:30d":            {old.Key()},
		"key:" + ep2.Key() + " changed:7d":           {},
		"key:" + sub.Key() + " changed:7d":           {sub.Key()},
	} {
		if got := keys(q); strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("%q: %v, want %v", q, got, want)
		}
	}
	// CONTROL: refused on a type they do not apply to
	for _, q := range []string{"type:topic key:" + ep.Key(), "type:message epic:" + ep.Key(), "type:message idle:30d"} {
		if code, _, _, raw := searchGet(t, e, ta, q, "", "X-Test-Human", "HUM-3"); code != http.StatusBadRequest || raw["error"] != "bad_query" {
			t.Errorf("%q: %d %v, want 400 bad_query", q, code, raw)
		}
	}
}
