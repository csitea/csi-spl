package repodocs_test

import (
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/repodocs"
)

// TestValidPathMatchesHub pins the path rule to hub.ValidDocsPath: a doc the
// read route serves is a doc Editable accepts, and the reverse (tree.json,
// the index, is served but never edited).
func TestValidPathMatchesHub(t *testing.T) {
	for _, p := range []string{
		"README.md", "csi-spl-doc/specs/072-rapid-deployability/spec.md", "a_b-c.d.md",
		"x.txt", "../a.md", "a/./b.md", "/a.md", "a/.git/b.md", "a b.md", ".a.md", "a//b.md", "a/..md",
	} {
		ok, _ := repodocs.Editable(p, map[string]bool{p: true}, nil)
		if ok != hub.ValidDocsPath(p) {
			t.Errorf("%q: Editable %v, hub.ValidDocsPath %v", p, ok, hub.ValidDocsPath(p))
		}
	}
	if ok, _ := repodocs.Editable(hub.DocsIndex, map[string]bool{hub.DocsIndex: true}, nil); ok {
		t.Error("tree.json is editable")
	}
}
