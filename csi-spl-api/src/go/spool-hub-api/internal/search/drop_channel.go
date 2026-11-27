// SPDX-License-Identifier: AGPL-3.0-only

package search

import (
	"fmt"
	"strings"
	"time"
)

// DropChannel removes every in: (channel:) term that names channel from the
// query q, as a channel move does to a staying scheduled task (spec 187 8.1,
// SPL-6692; owner HUM-10 answer A, msg b65adfcd). It reads q with the
// search tokenizer and parser, so quoted text and every other term stay as
// typed; the query is written back from its tree, terms joined by one
// space, AND dropped, parentheses only where the grouping needs them.
//
// limited reports a drop that may change what the query reads, so the task
// is paused, not widened. After the move no message is in the channel, so
// each dropped term was false (true when negated); a part left out of an
// AND stands for true, of an OR for false, and an empty query reads every
// message. A part whose old value is that stand-in (a negated term ANDed
// with the rest, a positive one among other OR branches) is only dropped;
// any other (a positive term ANDed with the rest, a negated OR branch, a
// group that collapses to the wrong constant) sets limited. A query that
// does not parse, or names no such term, comes back unchanged; out is ""
// when nothing is left; an out that does not read back as the dropped
// tree is an error.
func DropChannel(q, channel string) (out string, limited bool, err error) {
	ch := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(channel), "#"))
	root, ok := parseTree(q)
	if _, perr := Parse(q, time.Now()); !ok || perr != nil || ch == "" {
		return q, false, nil
	}
	d := &dropper{ch: ch}
	kept, v := d.node(root)
	if d.hits == 0 {
		return q, false, nil
	}
	if kept == nil && v != vTrue { // an empty query reads every message
		d.limited = true
	}
	out = render(kept, And)
	if strings.TrimSpace(out) != "" {
		back, ok := parseTree(out)
		if _, err := Parse(out, time.Now()); err != nil || !ok || !same(back, kept) {
			return q, true, fmt.Errorf("drop #%s from %q: %q does not read back as the dropped tree: %v", ch, q, out, err)
		}
	}
	return out, d.limited, nil
}

// parseTree is the tree of q before finish (type: stays a leaf).
func parseTree(q string) (*Node, bool) {
	if strings.TrimSpace(q) == "" {
		return nil, false
	}
	toks, err := tokenize(q)
	if err != nil {
		return nil, false
	}
	p := &parser{toks: toks, q: &Query{Raw: q}, end: u16len(q)}
	root, err := p.conj(0)
	if err != nil || p.i < len(p.toks) || root == nil {
		return nil, false
	}
	return root, true
}

type dropper struct {
	ch      string
	hits    int
	limited bool
}

// names: n is an in: leaf for the channel, by the parser's normalized
// channel (in:contacts / in:file-streams pick a section, not #contacts).
func (d *dropper) names(n *Node) bool {
	return n != nil && n.Kind == Leaf && n.Term.Op == OpIn && n.Term.Channel != "" && n.Term.Channel == d.ch
}

// val is what a subtree reads in <SRC> after the move, where no message is
// in the moved channel any more: always false, always true, or it depends.
type val int

const (
	vDepends val = iota
	vFalse
	vTrue
)

// node answers n without the channel's terms (nil: nothing left) and the
// value n read before the drop, with the channel's terms false.
func (d *dropper) node(n *Node) (*Node, val) {
	switch {
	case d.names(n):
		d.hits++
		return nil, vFalse
	case n.Kind == Leaf:
		return n, vDepends
	case n.Kind == Not:
		kid, v := d.node(n.Kids[0])
		if v != vDepends {
			v = vFalse + vTrue - v
		}
		if kid == nil {
			return nil, v
		}
		return &Node{Kind: Not, Kids: []*Node{kid}}, v
	}
	// a kid left out stands for the kind's neutral (true in an AND, false
	// in an OR): exact only when the kid read that value before the drop
	neutral, absorb := vTrue, vFalse
	if n.Kind == Or {
		neutral, absorb = vFalse, vTrue
	}
	var kids []*Node
	v := neutral
	for _, k := range n.Kids {
		nk, kv := d.node(k)
		switch {
		case nk != nil && nk.Kind == n.Kind: // an OR left with one AND in an AND
			kids = append(kids, nk.Kids...)
		case nk != nil:
			kids = append(kids, nk)
		case kv != neutral:
			d.limited = true
		}
		if kv == absorb || (kv == vDepends && v != absorb) {
			v = kv
		}
	}
	return mk(n.Kind, kids), v
}

// render writes n back as query text; in is the kind n sits in.
func render(n *Node, in NodeKind) string {
	if n == nil {
		return ""
	}
	switch n.Kind {
	case Leaf:
		return n.Term.Raw
	case Not:
		// -(--foo): "---foo" would read as the text foo, not as NOT --foo
		if k := n.Kids[0]; k.Kind == Leaf && !strings.HasPrefix(k.Term.Raw, "-") {
			return "-" + k.Term.Raw
		}
		return "-(" + render(n.Kids[0], Not) + ")"
	}
	parts := make([]string, len(n.Kids))
	for i, k := range n.Kids {
		parts[i] = render(k, n.Kind)
	}
	if n.Kind == Or {
		return strings.Join(parts, " OR ")
	}
	s := strings.Join(parts, " ")
	if in == Or {
		return "(" + s + ")"
	}
	return s
}

// same: a and b are one tree (kinds, and each leaf's raw term).
func same(a, b *Node) bool {
	if a == nil || b == nil {
		return a == b
	}
	if a.Kind != b.Kind || len(a.Kids) != len(b.Kids) || (a.Kind == Leaf && a.Term.Raw != b.Term.Raw) {
		return false
	}
	for i := range a.Kids {
		if !same(a.Kids[i], b.Kids[i]) {
			return false
		}
	}
	return true
}

// ChannelTermSQL is a Postgres regex test, for the text column col, that
// finds every in: (channel:) term DropChannel drops for the channel param
// (a SQL expression): in:#x, in:x, in=x, in:"#x", in:" x ", any case, after
// a space, a parenthesis, a phrase or a '-', before a space, a parenthesis
// or a phrase. A superset: DropChannel decides; the channel move's rewrite
// and the catalogue's scheduled_tasks Refs share it (SPL-6692).
func ChannelTermSQL(col, param string) string {
	return col + ` ~* ('(^|[[:space:]()"-])(in|channel)[:=]("[[:space:]]*#?' || ` + param +
		` || '[[:space:]]*"|#?' || ` + param + ` || '($|[[:space:]()"]))')`
}
