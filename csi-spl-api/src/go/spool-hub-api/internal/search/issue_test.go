package search

import (
	"reflect"
	"testing"
)

// Grammar 1.2 (CLE-34992, spec 039 issues): type:issue and the issue fields.
// The closed sets come from store's init in the binary; here the fixture sets
// them (store/search_issue_test.go pins store's values onto these vars).
func issueFixture(t *testing.T) {
	s, m := IssueStatuses, IssuePriorityMax
	t.Cleanup(func() { IssueStatuses, IssuePriorityMax = s, m })
	s0, n0, m0 := IssueStatuses, IssueStatusNormalize, IssuePriorityMin
	t.Cleanup(func() { IssueStatuses, IssueStatusNormalize, IssuePriorityMin = s0, n0, m0 })
	// the owner's set (rdb 0055) and prio 1..5 (rdb 0054), as store hands them over
	IssueStatuses = []string{"eval", "todo", "wip", "diss", "qas", "done"}
	IssueStatusNormalize = func(s string) string {
		if n, ok := map[string]string{"backlog": "eval", "in_progress": "wip", "in_review": "qas", "canceled": "diss"}[s]; ok {
			return n
		}
		return s
	}
	IssuePriorityMin, IssuePriorityMax = 1, 5
}

func TestIssueGrammar(t *testing.T) {
	issueFixture(t)
	iss := Entity{Type: TypeIssue, Name: "SPL-12 Search is slow", Text: []string{"SPL-12", "Search is slow", "the topic section scans"},
		Status: "wip", Priority: 1, Assignee: "HUM-3", Labels: []string{"perf", "Search"}, Me: "HUM-3"}
	other := Entity{Type: TypeIssue, Name: "SPL-13 Café menu", Text: []string{"SPL-13", "Café menu"}, Status: "todo", Priority: 5}
	cases := []struct {
		q     string
		types []Type
		a, b  bool
	}{
		{"type:issue", []Type{TypeIssue}, true, true},
		{"kind:tickets slow", []Type{TypeIssue}, true, false},
		{"type:issue scans", []Type{TypeIssue}, true, false}, // the description is content
		{"type:issue name:scans", []Type{TypeIssue}, false, false},
		{"type:issue name:spl-12", []Type{TypeIssue}, true, false},
		{"type:issue cafe", []Type{TypeIssue}, false, true},
		{"status:wip", []Type{TypeIssue}, true, false},         // implies type:issue
		{"status:in_progress", []Type{TypeIssue}, true, false}, // an older name, normalised to wip
		{"status:WIP", []Type{TypeIssue}, true, false},
		{"status:todo OR status:done", []Type{TypeIssue}, false, true},
		{"-status:todo", []Type{TypeIssue}, true, false},
		{"priority:1", []Type{TypeIssue}, true, false},
		{"priority:5", []Type{TypeIssue}, false, true},
		{"assignee:me", []Type{TypeIssue}, true, false},
		{"assignee:none", []Type{TypeIssue}, false, true},
		{"assignee:hum-3", []Type{TypeIssue}, true, false},
		{"label:search", []Type{TypeIssue}, true, false},
		{"label:bug", []Type{TypeIssue}, false, false},
	}
	for _, c := range cases {
		q, err := Parse(c.q, now)
		if err != nil {
			t.Errorf("%q: %v", c.q, err)
			continue
		}
		if !reflect.DeepEqual(q.Types, c.types) {
			t.Errorf("%q: types %v, want %v", c.q, q.Types, c.types)
		}
		if a, b := MatchEntity(q.Root, iss), MatchEntity(q.Root, other); a != c.a || b != c.b {
			t.Errorf("%q: %v %v, want %v %v", c.q, a, b, c.a, c.b)
		}
	}
	// CONTROLS: closed sets, applicability
	for _, bad := range []string{"status:open", "status:backlogs", "priority:0", "priority:6", "priority:x", `assignee:"a b"`, "type:message status:done", "status:done from:CLE-07"} {
		if _, err := Parse(bad, now); err == nil {
			t.Errorf("%q must be a bad query", bad)
		}
	}
	// CONTROL: a plain query does not search issues (opt-in, round-trip budget)
	if q, _ := Parse("slow", now); len(q.Types) != len(DefaultTypes) {
		t.Errorf("plain query types %v", q.Types)
	}
	// CONTROL: unset closed sets refuse every value
	IssueStatuses, IssuePriorityMax = nil, -1
	if _, err := Parse("status:done", now); err == nil {
		t.Error("status: with no workflow wired must refuse")
	}
}
