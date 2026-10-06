package repodocs

import (
	"regexp"
	"strings"
	"testing"
)

// denyRows are the 13 deny rows of spec §5.2: the globs (cnf
// env.docs.repo_edit.deny), the row's measuring regex, and one sample path.
var denyRows = []struct {
	globs  []string
	regex  string
	sample string
}{
	{[]string{"**/CLAUDE.md", "**/GEMINI.md", "**/AGENTS.md"}, `(^|/)(CLAUDE|GEMINI|AGENTS)\.md$`, "csi-spl-orc/AGENTS.md"},
	{[]string{"**/.*", "**/.*/**"}, `(^|/)\.`, ".github/workflows/README.md"},
	{[]string{"csi-spl-wui/**"}, `^csi-spl-wui/`, "csi-spl-wui/README.md"},
	{[]string{"csi-spl-api/**"}, `^csi-spl-api/`, "csi-spl-api/README.md"},
	{[]string{"csi-spl-rdb/**"}, `^csi-spl-rdb/`, "csi-spl-rdb/src/sql/postgres/spool-hub/README.md"},
	{[]string{"csi-spl-cnf/**"}, `^csi-spl-cnf/`, "csi-spl-cnf/README.md"},
	{[]string{"csi-spl-iac/src/terraform/**"}, `^csi-spl-iac/src/terraform/`, "csi-spl-iac/src/terraform/README.md"},
	{[]string{"csi-spl-orc/src/bash/features/*/assets/**", "**/*.tpl.md"}, `^csi-spl-orc/src/bash/features/[^/]+/assets/|\.tpl\.md$`, "csi-spl-orc/src/bash/features/spawn-agents/assets/skill.md"},
	{[]string{"csi-spl-doc/doc/md/lane-integration-rules.md"}, `^csi-spl-doc/doc/md/lane-integration-rules\.md$`, "csi-spl-doc/doc/md/lane-integration-rules.md"},
	{[]string{"csi-spl-doc/doc/help/**"}, `^csi-spl-doc/doc/help/`, "csi-spl-doc/doc/help/how-to-post.md"},
	{[]string{"csi-spl-doc/specs/**/tasks.md"}, `^csi-spl-doc/specs/.+/tasks\.md$`, "csi-spl-doc/specs/075-docs-section/repo-edit/tasks.md"},
	{[]string{"**/tests/**", "**/fixtures/**", "**/testdata/**", "**/*.fixture.md"}, `/(tests|fixtures|testdata)/|\.fixture\.md$`, "csi-spl-orc/src/bash/tests/sample.md"},
	{[]string{"**/node_modules/**", "tpl-gen/**", "**/bin/**", "**/secrets/**"}, `(^|/)(node_modules|tpl-gen|bin|secrets)/`, "csi-spl-iac/bin/notes.md"},
}

func denyList() []string {
	var out []string
	for _, r := range denyRows {
		out = append(out, r.globs...)
	}
	return out
}

// testTree is a published tree holding every row's sample (a deny beats a
// publish), plus editable docs in csi-spl-doc/doc/md/ and at the root.
func testTree() map[string]bool {
	t := map[string]bool{
		"README.md":                             true,
		"csi-spl-doc/doc/md/csi-spl.feature.md": true,
		"csi-spl-doc/specs/075-docs-section/repo-edit/tasks.md": true,
	}
	for _, r := range denyRows {
		t[r.sample] = true
	}
	return t
}

func TestEditableDeniesOneSamplePerRow(t *testing.T) {
	tree, deny := testTree(), denyList()
	for i, r := range denyRows {
		if !regexp.MustCompile(r.regex).MatchString(r.sample) {
			t.Errorf("row %d: sample %q is not in the row's spec regex %s", i+1, r.sample, r.regex)
		}
		if ok, why := Editable(r.sample, tree, deny); ok {
			t.Errorf("row %d: %q editable (%s), want denied", i+1, r.sample, why)
		}
		// each row's own globs deny its sample, not only the union
		if ok, why := Editable(r.sample, tree, r.globs); ok {
			t.Errorf("row %d: %q editable under its own globs %v (%s)", i+1, r.sample, r.globs, why)
		}
	}
}

func TestEditableDenyReasonNamesTheGlob(t *testing.T) {
	ok, why := Editable("csi-spl-wui/README.md", testTree(), denyList())
	if ok || why != ReasonDeniedBy+"csi-spl-wui/**" {
		t.Fatalf("got %v %q", ok, why)
	}
}

func TestEditableAllows(t *testing.T) {
	tree, deny := testTree(), denyList()
	for p, want := range map[string]string{
		"csi-spl-doc/doc/md/csi-spl.feature.md": ReasonPublished,
		"README.md":                             ReasonPublished,
		"csi-spl-doc/doc/md/a-new-page.md":      ReasonNewInDir,
		"CHANGES.md":                            ReasonNewInDir,
	} {
		if ok, why := Editable(p, tree, deny); !ok || why != want {
			t.Errorf("Editable(%q) = %v %q, want true %q", p, ok, why, want)
		}
	}
}

func TestEditableRefuses(t *testing.T) {
	tree, deny := testTree(), denyList()
	for p, want := range map[string]string{
		"../etc/passwd.md":                 ReasonInvalidPath,
		"csi-spl-doc/../CLAUDE.md":         ReasonInvalidPath,
		"csi-spl-doc/./doc/x.md":           ReasonInvalidPath,
		"/README.md":                       ReasonInvalidPath,
		"csi-spl-doc//x.md":                ReasonInvalidPath,
		"csi-spl-doc/doc/md/x.txt":         ReasonInvalidPath,
		"tree.json":                        ReasonInvalidPath,
		"csi-spl-doc/a b.md":               ReasonInvalidPath,
		strings.Repeat("a/", 256) + "x.md": ReasonInvalidPath,
		// a new file where no editable doc lives yet
		"csi-spl-doc/no-such-dir/x.md": ReasonNotInTree,
		// a new file beside a denied doc only (the dir holds tasks.md alone)
		"csi-spl-doc/specs/075-docs-section/repo-edit/notes.md": ReasonNotInTree,
		// a new file in a denied dir
		"csi-spl-wui/new.md": ReasonDeniedBy + "csi-spl-wui/**",
	} {
		if ok, why := Editable(p, tree, deny); ok || why != want {
			t.Errorf("Editable(%q) = %v %q, want false %q", p, ok, why, want)
		}
	}
}

func TestGlobRegexp(t *testing.T) {
	for _, c := range []struct {
		glob, p string
		want    bool
	}{
		{"**/CLAUDE.md", "CLAUDE.md", true},
		{"**/CLAUDE.md", "a/b/CLAUDE.md", true},
		{"**/CLAUDE.md", "a/xCLAUDE.md", false},
		{"csi-spl-wui/**", "csi-spl-wui/a/b.md", true},
		{"csi-spl-wui/**", "csi-spl-wuix/a.md", false},
		{"a/*/c/**", "a/b/c/d.md", true},
		{"a/*/c/**", "a/b/x/c/d.md", false},
		{"**/*.tpl.md", "x/y.tpl.md", true},
		{"**/*.tpl.md", "x/ytplxmd", false},
		{"a?.md", "ab.md", true},
		{"a?.md", "a/.md", false},
	} {
		re, err := globRegexp(c.glob)
		if err != nil || re.MatchString(c.p) != c.want {
			t.Errorf("glob %q on %q: err=%v want %v", c.glob, c.p, err, c.want)
		}
	}
}
