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
// limited reports a dropped term that narrowed the query: without it the
// query reads more than it did (a positive term ANDed with the rest, or the
// last branch of an OR), so the task is paused, not widened. A term whose
// removal keeps the meaning (a negated term the rest is ANDed with, or one
// OR branch among others) is only dropped. A query that does not parse, or
// names no such term, comes back unchanged; out is "" when nothing is left.
func DropChannel(q, channel string) (out string, limited bool, err error) {
	ch := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(channel), "#"))
	root, ok := parseTree(q)
	if _, perr := Parse(q, time.Now()); !ok || perr != nil || ch == "" {
		return q, false, nil
	}
	d := &dropper{ch: ch}
	kept := d.node(root, And)
	if d.hits == 0 {
		return q, false, nil
	}
	out = render(kept, And)
	if strings.TrimSpace(out) != "" {
		if _, err := Parse(out, time.Now()); err != nil {
			return q, true, fmt.Errorf("drop #%s from %q: %q does not parse: %w", ch, q, out, err)
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

// names: n is an in: leaf for the channel, as typed (#x, x, any case).
func (d *dropper) names(n *Node) bool {
	return n != nil && n.Kind == Leaf && n.Term.Op == OpIn &&
		strings.ToLower(strings.TrimPrefix(strings.TrimSpace(n.Term.Value), "#")) == d.ch
}

// node answers n without the channel's terms; parent is the kind of the
// node n sits in (And at the root).
func (d *dropper) node(n *Node, parent NodeKind) *Node {
	switch {
	case d.names(n):
		d.drop(false, parent)
		return nil
	case n.Kind == Not && d.names(n.Kids[0]):
		d.drop(true, parent)
		return nil
	case n.Kind == Leaf:
		return n
	case n.Kind == Not:
		if kid := d.node(n.Kids[0], Not); kid != nil {
			return &Node{Kind: Not, Kids: []*Node{kid}}
		}
		return nil
	}
	var kids []*Node
	hits := d.hits
	for _, k := range n.Kids {
		if nk := d.node(k, n.Kind); nk != nil {
			kids = append(kids, nk)
		}
	}
	if n.Kind == Or && d.hits > hits && len(kids) == 0 {
		d.limited = true // every branch named the channel
	}
	return mk(n.Kind, kids)
}

// drop counts one dropped term; it was true in <SRC> after the move when
// negated, false otherwise. Removing true from an AND or false from an OR
// keeps the meaning; anything else changes what the query reads.
func (d *dropper) drop(neg bool, parent NodeKind) {
	d.hits++
	if (parent == And && neg) || (parent == Or && !neg) {
		return
	}
	d.limited = true
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
		if k := n.Kids[0]; k.Kind == Leaf {
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
