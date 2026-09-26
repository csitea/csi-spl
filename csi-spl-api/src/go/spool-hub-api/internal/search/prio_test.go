package search

import (
	"reflect"
	"testing"
)

// Grammar 1.3 (owner, 2026-09-26, topic d81cbf47: "/search type:issue
// prio=1"): prio is the priority operator's name, and op=value means op:value
// for a KNOWN operator. CONTROLS: any other a=b stays text, with no warning.
func TestPrioAndEquals(t *testing.T) {
	issueFixture(t)
	iss := Entity{Type: TypeIssue, Name: "SPL-12 Search is slow", Text: []string{"SPL-12", "Search is slow"}, Status: "done", Priority: 1}
	for _, q := range []string{"prio:1", "prio=1", "PRIO=1", "type:issue prio=1", `prio="1"`, "priority=1", "kind=issue prio=1", "status=done prio=1"} {
		p, err := Parse(q, now)
		if err != nil {
			t.Errorf("%q: %v", q, err)
			continue
		}
		if !reflect.DeepEqual(p.Types, []Type{TypeIssue}) || !MatchEntity(p.Root, iss) {
			t.Errorf("%q: types %v, match %v", q, p.Types, MatchEntity(p.Root, iss))
		}
		if len(p.Warnings) != 0 {
			t.Errorf("%q: warnings %v", q, p.Warnings)
		}
	}
	if p, err := Parse("prio=2", now); err != nil || MatchEntity(p.Root, iss) {
		t.Errorf("prio=2 must parse and not match priority 1: %v", err)
	}
	// from=, in= work like from:, in:
	if p, err := Parse("from=CLE-07 in=#tasks", now); err != nil || !MatchMsg(p.Root, mTask) {
		t.Errorf("from= in=: %v", err)
	}
	// CONTROLS: a=b with an unknown name is text, and no warning (= is common in content)
	for _, q := range []string{"x=1", "a=b", "deploy=done", "k=v"} {
		p, err := Parse(q, now)
		if err != nil {
			t.Errorf("%q: %v", q, err)
			continue
		}
		if p.Root == nil || p.Root.Kind != Leaf || p.Root.Term.Op != OpText || len(p.Warnings) != 0 {
			t.Errorf("%q must be plain text with no warning: %+v %v", q, p.Root, p.Warnings)
		}
		if !reflect.DeepEqual(p.Types, DefaultTypes) {
			t.Errorf("%q: types %v", q, p.Types)
		}
	}
	// CONTROLS: the range comes from the store's sets
	for _, bad := range []string{"prio=6", "prio=0", "prio=-1", "prio=x", "prio="} {
		if _, err := Parse(bad, now); err == nil {
			t.Errorf("%q must be a bad query", bad)
		}
	}
	IssuePriorityMin, IssuePriorityMax = 1, 5 // the owner's 1..5, once the store says so
	t.Cleanup(func() { IssuePriorityMin = 0 })
	if _, err := Parse("prio=5", now); err != nil {
		t.Errorf("prio=5 with a 1..5 store: %v", err)
	}
	if _, err := Parse("prio=0", now); err == nil {
		t.Error("prio=0 with a 1..5 store must be a bad query")
	}
}
