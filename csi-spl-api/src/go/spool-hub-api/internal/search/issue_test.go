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
	IssueStatuses = []string{"backlog", "todo", "in_progress", "in_review", "done", "canceled"}
	IssuePriorityMax = 4
}

func TestIssueGrammar(t *testing.T) {
	issueFixture(t)
	iss := Entity{Type: TypeIssue, Name: "SPL-12 Search is slow", Text: []string{"SPL-12", "Search is slow", "the topic section scans"},
		Status: "in_progress", Priority: 1, Assignee: "HUM-3", Labels: []string{"perf", "Search"}, Me: "HUM-3"}
	other := Entity{Type: TypeIssue, Name: "SPL-13 Café menu", Text: []string{"SPL-13", "Café menu"}, Status: "todo", Priority: 0}
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
		{"status:in_progress", []Type{TypeIssue}, true, false}, // implies type:issue
		{"status:todo OR status:done", []Type{TypeIssue}, false, true},
		{"-status:todo", []Type{TypeIssue}, true, false},
		{"priority:1", []Type{TypeIssue}, true, false},
		{"priority:0", []Type{TypeIssue}, false, true},
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
	for _, bad := range []string{"status:open", "priority:5", "priority:x", `assignee:"a b"`, "type:message status:done", "status:done from:CLE-07"} {
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
