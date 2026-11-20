// SPDX-License-Identifier: AGPL-3.0-only

package topicpdf

import (
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Every topicOpening case of csi-spl-wui/tests/unit/view-api.test.mjs.
func TestOpeningMatchesTopicOpening(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", ""},
		{"  hello\nworld  ", "hello world"},
		{strings.Repeat("ä", 101), strings.Repeat("ä", 100) + "..."},
		{strings.Repeat("a", 100), strings.Repeat("a", 100)},
		{strings.Repeat("a", 101), strings.Repeat("a", 100) + "..."},
		{"a\u00a0\u2028b\ufeff", "a b"}, // JS \s
		{"a\u0085b", "a\u0085b"},        // not JS \s
	}
	for _, c := range cases {
		if got := Opening(c.in); got != c.want {
			t.Errorf("Opening(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// The topicTitleFromRows cases without a pinned root: zero rows is "", as
// view-api.test.mjs's topicTitleFromRows([], null) (spec 183 v0.4 7.1.3).
func TestTitleMatchesTopicTitleFromRows(t *testing.T) {
	t1 := time.Date(2026, 11, 20, 8, 0, 0, 0, time.UTC)
	rows := []store.EditableMessage{{TS: t1.Add(time.Minute), Body: "later"}, {TS: t1, Body: "starter"}}
	if got := Title(rows); got != "starter" {
		t.Errorf("Title = %q, want starter", got)
	}
	if got := Title(nil); got != "" {
		t.Errorf("Title(nil) = %q, want \"\"", got)
	}
	if got := Title([]store.EditableMessage{{TS: t1, Body: " \n "}}); got != "" {
		t.Errorf("Title(blank) = %q, want \"\"", got)
	}
	tie := []store.EditableMessage{{TS: t1, Body: "first"}, {TS: t1, Body: "second"}}
	if got := Title(tie); got != "first" {
		t.Errorf("Title(tie) = %q, want first", got)
	}
}
