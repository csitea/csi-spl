package search

import (
	"testing"
	"time"
)

// SPL-2172 (owner 2026-10-16, t1 0495d9a0): a '-' with no term stuck to it
// is plain text, dropped from the terms, never the "'-' must be followed by
// a term" error. A '-' inside a word stays in the word; -word still excludes.

// countNot counts the Not nodes under n.
func countNot(n *Node) int {
	if n == nil {
		return 0
	}
	c := 0
	if n.Kind == Not {
		c = 1
	}
	for _, k := range n.Kids {
		c += countNot(k)
	}
	return c
}

func TestLoneDash(t *testing.T) {
	cases := []struct {
		q        string
		nots     int    // Not nodes in the tree
		dropped  int    // "no letter or digit: ignored" warnings
		positive int    // positive terms
		first    string // Raw of the first positive term, "" = none
	}{
		// the owner's two posts, verbatim
		{"CSI-SPL Robustness - Additional Findings Click to teach CSITEA Mail that this conversation is important Inbox", 0, 1, 15, "CSI-SPL"},
		{"and it should not - one should be able to search with chars having - in the string", 0, 2, 16, "and"},
		{"CSI-SPL", 0, 0, 1, "CSI-SPL"},
		{"a - b", 0, 1, 2, "a"},
		{"a -", 0, 1, 1, "a"},
		{"- ", 0, 1, 0, ""},
		{"-", 0, 1, 0, ""},
		{"--", 0, 1, 0, ""},
		{"a -- b", 0, 1, 2, "a"},
		{"(a -)", 0, 1, 1, "a"},
		{`"a - b"`, 0, 0, 1, `"a - b"`},
		{"-draft", 1, 0, 0, ""},
		{"hub -draft", 1, 0, 1, "hub"},
		{"hub - -draft", 1, 1, 1, "hub"},
	}
	for _, c := range cases {
		q, err := Parse(c.q, now)
		if err != nil {
			t.Errorf("%q: err %v, want none", c.q, err)
			continue
		}
		if n := countNot(q.Root); n != c.nots {
			t.Errorf("%q: %d Not nodes, want %d", c.q, n, c.nots)
		}
		dropped := 0
		for _, w := range q.Warnings {
			if w.Detail == "no letter or digit: ignored" {
				dropped++
			}
		}
		if dropped != c.dropped {
			t.Errorf("%q: %d dropped words %+v, want %d", c.q, dropped, q.Warnings, c.dropped)
		}
		if len(q.Positive) != c.positive {
			t.Errorf("%q: %d positive terms, want %d", c.q, len(q.Positive), c.positive)
			continue
		}
		if c.first != "" && q.Positive[0].Raw != c.first {
			t.Errorf("%q: first positive %q, want %q", c.q, q.Positive[0].Raw, c.first)
		}
	}
}

// TestDashMatches: what the terms find in a body that holds dashes.
func TestDashMatches(t *testing.T) {
	m := Msg{MsgID: "d1", Kind: "note", Body: "CSI-SPL Robustness - Additional Findings", ReceivedAt: now.Add(-time.Hour)}
	other := Msg{MsgID: "d2", Kind: "note", Body: "a draft about robustness", ReceivedAt: now.Add(-time.Hour)}
	cases := []struct {
		q        string
		m, other bool
	}{
		{"CSI-SPL", true, false},
		{"CSI-SPL Robustness - Additional Findings", true, false},
		{"robustness - findings", true, false},
		{"robustness -draft", true, false},
		{`"Robustness - Additional"`, true, false},
	}
	for _, c := range cases {
		q, err := Parse(c.q, now)
		if err != nil {
			t.Errorf("%q: err %v", c.q, err)
			continue
		}
		if got := MatchMsg(q.Root, m); got != c.m {
			t.Errorf("%q vs %q: %v, want %v", c.q, m.Body, got, c.m)
		}
		if got := MatchMsg(q.Root, other); got != c.other {
			t.Errorf("%q vs %q: %v, want %v", c.q, other.Body, got, c.other)
		}
	}
}
