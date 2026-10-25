package search

import (
	"reflect"
	"slices"
	"testing"
	"time"
)

// Spec 100 section 14 (SPL-3337): type:doc, the Qto documents. Its spellings
// name it, a plain search includes it (owner HUM-10 t1 4e06a219: search must
// include the Qto documents), and the operators that cannot apply to a doc
// section leave it out. CONTROL: from: (a message party) never selects doc.
func TestDocGrammar(t *testing.T) {
	now := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		q     string
		types []Type
	}{
		{"type:doc", []Type{TypeDoc}},
		{"type:docs runbook", []Type{TypeDoc}},
		{"kind:documents runbook", []Type{TypeDoc}},
		{"type:qto runbook", []Type{TypeDoc}},
		{"type:doc,issue runbook", []Type{TypeIssue, TypeDoc}},
		{"type:doc title:runbook", []Type{TypeDoc}},
		{"type:doc name:runbook", []Type{TypeDoc}},
		{"type:doc after:7d", []Type{TypeDoc}},
		{"title:runbook", []Type{TypeTopic, TypeDoc}},
		{"from:HUM-3 runbook", []Type{TypeMessage, TypeTopic, TypeFile}}, // CONTROL: a party is no doc's
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
	}
	if q, _ := Parse("runbook", now); !slices.Contains(q.Types, TypeDoc) {
		t.Errorf("a plain search leaves the docs out: %v", q.Types)
	}
	if TypeDoc.Group() != "docs" {
		t.Errorf("group %q, want docs", TypeDoc.Group())
	}
	for _, bad := range []string{"type:doc from:HUM-3", "type:doc in:#ops", "type:doc is:task"} {
		if _, err := Parse(bad, now); err == nil {
			t.Errorf("%q parsed; an operator no doc carries must be refused with type:doc", bad)
		}
	}
}
