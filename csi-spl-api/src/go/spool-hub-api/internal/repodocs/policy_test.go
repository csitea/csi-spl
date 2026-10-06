package repodocs

import "testing"

// The compiled Policy answers exactly as Editable, for every deny row's
// sample, editable docs, new files in editable and denied dirs, traversal,
// and a deny glob that does not compile (both fail closed).
func TestPolicyMatchesEditable(t *testing.T) {
	tree := testTree()
	paths := []string{"README.md", "NEW.md", "csi-spl-doc/doc/md/csi-spl.feature.md", "csi-spl-doc/doc/md/new.md",
		"csi-spl-wui/new.md", "nowhere/new.md", "../x.md", "a//b.md", ".edits/x.md", "x.txt"}
	for _, r := range denyRows {
		paths = append(paths, r.sample)
	}
	for _, deny := range [][]string{denyList(), nil, {"[bad"}} {
		pol := NewPolicy(deny)
		for _, p := range paths {
			okE, whyE := Editable(p, tree, deny)
			okP, whyP := pol.Editable(p, tree)
			if okE != okP || whyE != whyP {
				t.Errorf("deny %v, %q: Editable %v %q, Policy %v %q", deny, p, okE, whyE, okP, whyP)
			}
		}
	}
}
