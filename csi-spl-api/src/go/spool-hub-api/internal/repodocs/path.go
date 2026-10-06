// Package repodocs holds the hub's rules for editing Repo Docs (spec 075
// repo-edit): which paths a member may edit (spec §5.2) and the text gates a
// save must pass before it reaches the docs bucket (spec §5.1).
package repodocs

import (
	"path"
	"regexp"
	"strings"
)

// Reasons Editable answers with. A denial by the deny list names the glob.
const (
	ReasonPublished   = "published"
	ReasonNewInDir    = "new_in_editable_dir"
	ReasonInvalidPath = "invalid_path"
	ReasonNotInTree   = "not_published"
	ReasonDeniedBy    = "denied:"
)

// docPathRe is the .md half of hub.ValidDocsPath (TestValidPathMatchesHub
// pins the two together): segments of [A-Za-z0-9._-], none starting with a
// dot, ending in .md. The hub imports this package, so it cannot import hub.
var docPathRe = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\.md$`)

func validPath(p string) bool { return len(p) <= 512 && docPathRe.MatchString(p) }

// Editable reports whether a member may save p (spec §5.2): a valid doc path,
// matched by no deny glob, and either published (in tree, the env's
// tree.json paths) or a new file in a directory that already holds an
// editable doc. The reason says which rule decided.
func Editable(p string, tree map[string]bool, deny []string) (bool, string) {
	if !validPath(p) {
		return false, ReasonInvalidPath
	}
	if g := deniedBy(p, deny); g != "" {
		return false, ReasonDeniedBy + g
	}
	if tree[p] {
		return true, ReasonPublished
	}
	dir := path.Dir(p)
	for q := range tree {
		if path.Dir(q) == dir && validPath(q) && deniedBy(q, deny) == "" {
			return true, ReasonNewInDir
		}
	}
	return false, ReasonNotInTree
}

// deniedBy returns the first glob of deny that matches p, "" for none. A glob
// that does not compile denies everything: a broken deny list fails closed.
func deniedBy(p string, deny []string) string {
	for _, g := range deny {
		re, err := globRegexp(g)
		if err != nil || re.MatchString(p) {
			return g
		}
	}
	return ""
}

// globRegexp turns a deny glob into an anchored regexp: "**" as a whole
// segment is any number of segments, "*" is any run inside one segment, "?"
// one character of it; everything else is literal.
func globRegexp(g string) (*regexp.Regexp, error) {
	segs := strings.Split(g, "/")
	var b strings.Builder
	b.WriteString("^")
	for i, s := range segs {
		last := i == len(segs)-1
		switch {
		case s == "**" && last:
			b.WriteString(".*")
		case s == "**":
			b.WriteString("(?:[^/]+/)*")
		default:
			b.WriteString(globSegment(s))
			if !last {
				b.WriteString("/")
			}
		}
	}
	b.WriteString("$")
	return regexp.Compile(b.String())
}

func globSegment(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '*':
			b.WriteString("[^/]*")
		case '?':
			b.WriteString("[^/]")
		default:
			b.WriteString(regexp.QuoteMeta(string(r)))
		}
	}
	return b.String()
}
