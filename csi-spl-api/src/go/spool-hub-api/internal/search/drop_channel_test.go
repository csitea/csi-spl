// SPDX-License-Identifier: AGPL-3.0-only

package search

import (
	"testing"
	"time"
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
	if out, _, _ := DropChannel(`in:#ops`, " "); out != `in:#ops` {
		t.Errorf("an empty channel changed the query: %q", out)
	}
}
