package repodocs

import (
	"path"
	"regexp"
)

// Policy is Editable with its deny globs compiled once: the hub judges every
// path of tree.json per request (the "editable" flag), where Editable would
// compile each glob again for each path. TestPolicyMatchesEditable pins the
// two together.
type Policy struct {
	globs []string
	res   []*regexp.Regexp // nil entry: the glob does not compile, it denies everything
}

// NewPolicy compiles deny.
func NewPolicy(deny []string) *Policy {
	p := &Policy{globs: append([]string(nil), deny...)}
	for _, g := range deny {
		re, err := globRegexp(g)
		if err != nil {
			re = nil
		}
		p.res = append(p.res, re)
	}
	return p
}

// deniedBy is deniedBy over the compiled globs.
func (p *Policy) deniedBy(q string) string {
	for i, re := range p.res {
		if re == nil || re.MatchString(q) {
			return p.globs[i]
		}
	}
	return ""
}

// Editable is Editable(q, tree, deny) for the policy's deny list.
func (p *Policy) Editable(q string, tree map[string]bool) (bool, string) {
	if !validPath(q) {
		return false, ReasonInvalidPath
	}
	if g := p.deniedBy(q); g != "" {
		return false, ReasonDeniedBy + g
	}
	if tree[q] {
		return true, ReasonPublished
	}
	dir := path.Dir(q)
	for o := range tree {
		if path.Dir(o) == dir && validPath(o) && p.deniedBy(o) == "" {
			return true, ReasonNewInDir
		}
	}
	return false, ReasonNotInTree
}
