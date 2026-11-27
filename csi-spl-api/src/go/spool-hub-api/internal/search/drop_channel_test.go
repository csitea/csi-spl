// SPDX-License-Identifier: AGPL-3.0-only

package search

import (
	"regexp"
	"strconv"
	"testing"
	"time"
	"unicode"
)

// TestDropChannel: a channel move drops the in: terms that name the moved
// channel from a task's query, grammar-aware, and says when that narrowed
// the query (spec 187 8.1, SPL-6692).
func TestDropChannel(t *testing.T) {
	cases := []struct {
		q, out  string
		limited bool
	}{
		{`in:#ops foo`, `foo`, true},
		{`in:#ops`, ``, true},
		{`IN:#OPS foo`, `foo`, true},
		{`channel:ops foo`, `foo`, true},
		{`in=ops foo`, `foo`, true},
		{`in:"#ops" foo`, `foo`, true},
		{`-in:#ops foo`, `foo`, false},
		{`foo -in:#ops "in:#ops stays" bar`, `foo "in:#ops stays" bar`, false},
		{`in:#ops OR in:#dev`, `in:#dev`, false},
		{`foo (in:#ops OR in:#dev)`, `foo in:#dev`, false},
		{`a in:#ops OR b`, `a b`, false},
		{`(in:#ops foo) OR bar`, `foo OR bar`, true},
		{`(in:#ops OR in:#ops) foo`, `foo`, true},
		{`x OR -in:#ops`, `x`, true},
		{`-(in:#ops foo) bar`, `-foo bar`, true},
		{`type:topic in:#ops title:deploy`, `type:topic title:deploy`, true},
		{`(a b) OR in:#ops-team in:#opsx`, `(a b) OR in:#ops-team in:#opsx`, false},
		// R7 W1 (a-744): a group of negated terms collapses to true, which
		// an OR or a NOT does not keep
		{`-(-in:#ops -in:#ops) foo`, `foo`, true},
		{`(-in:#ops -in:#ops) OR foo`, `foo`, true},
		{`(-in:#ops -in:#ops) foo`, `foo`, false},
		{`-(in:#ops OR in:#ops) foo`, `foo`, false},
		{`-in:#ops`, ``, false},
		// R7 W2: a negated term that starts with '-' keeps its parentheses
		{`-(--foo -in:#ops)`, `-(--foo)`, false},
		// an OR left with one AND inside an AND is one AND
		{`foo (in:#ops OR (a b))`, `foo a b`, false},
		{`x OR ((-in:#ops) (a OR b))`, `x OR a OR b`, false},
	}
	for _, c := range cases {
		out, limited, err := DropChannel(c.q, "ops")
		if err != nil || out != c.out || limited != c.limited {
			t.Errorf("DropChannel(%q) = %q, %v, %v; want %q, %v", c.q, out, limited, err, c.out, c.limited)
		}
		if out != "" {
			if _, err := Parse(out, time.Now()); err != nil {
				t.Errorf("DropChannel(%q) = %q does not parse: %v", c.q, out, err)
			}
		}
	}
}

// TestDropChannelUnchanged: no such term, an unparsable query or no
// channel leaves the text exactly as typed.
func TestDropChannelUnchanged(t *testing.T) {
	for _, q := range []string{`  foo   AND  in:#dev `, `"unterminated in:#ops`, `ops in:#opsx #ops`, ``} {
		if out, limited, err := DropChannel(q, "ops"); out != q || limited || err != nil {
			t.Errorf("DropChannel(%q) = %q, %v, %v; want it unchanged", q, out, limited, err)
		}
	}
	// R7 W3: in:contacts / in:file-streams pick a section, not the channels
	// #contacts / #file-streams
	for _, c := range []string{"contacts", "file-streams"} {
		q := `in:` + c + ` foo`
		if out, limited, err := DropChannel(q, c); out != q || limited || err != nil {
			t.Errorf("DropChannel(%q, %q) = %q, %v, %v; want it unchanged", q, c, out, limited, err)
		}
		if out, limited, err := DropChannel(`in:#`+c+` foo`, c); out != `foo` || !limited || err != nil {
			t.Errorf("DropChannel(in:#%s foo) = %q, %v, %v; want foo, true", c, out, limited, err)
		}
	}
	if out, _, _ := DropChannel(`in:#ops`, " "); out != `in:#ops` {
		t.Errorf("an empty channel changed the query: %q", out)
	}
}

// TestSQLSpacesIsTokenizerSpace: the space class of ChannelTermSQL holds
// exactly the runes the tokenizer skips, so the move's SQL finds a term the
// grammar reads next to U+00A0 or U+202F (R7 c-815, SPL-6692).
func TestSQLSpacesIsTokenizerSpace(t *testing.T) {
	in := map[rune]bool{}
	esc := `\\u([0-9a-f]{4})`
	for _, m := range regexp.MustCompile(esc+`(?:-`+esc+`)?`).FindAllStringSubmatch(sqlSpaces, -1) {
		lo, _ := strconv.ParseUint(m[1], 16, 32)
		hi := lo
		if m[2] != "" {
			hi, _ = strconv.ParseUint(m[2], 16, 32)
		}
		for r := lo; r <= hi; r++ {
			in[rune(r)] = true
		}
	}
	for r := rune(0); r <= unicode.MaxRune; r++ {
		if unicode.IsSpace(r) != in[r] {
			t.Errorf("U+%04X: IsSpace %v, in sqlSpaces %v (%s)", r, unicode.IsSpace(r), in[r], sqlSpaces)
		}
	}
}
