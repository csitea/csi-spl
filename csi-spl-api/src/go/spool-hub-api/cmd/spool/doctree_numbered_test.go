package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Spec 137 T012a and the import's verbs (T012, T014, T032): an unnumbered
// item exports with no outline number and its branch is found by depth; add
// --unnumbered and edit --field attrs.<key> write attrs; export --from
// renders a saved read answer with no hub, the root's body first as the
// preamble (SPL-1612). Red before: the heading carried
// a blank outline (two spaces), the branch of an unnumbered item was the
// item alone, and the three flags did not exist.

func TestDocTreeMarkdownUnnumbered(t *testing.T) {
	items := []dtItem{
		{ID: "o", Depth: 1, Title: "Overview", Body: "Why."},
		{ID: "d", Depth: 2, Title: "Details"},
		{ID: "a", Outline: "1", Depth: 1, Title: "Goals"},
		{ID: "b", Outline: "1.1", Depth: 2, Title: "First"},
	}
	whole, _ := docTreeMarkdown(items, "d1", "")
	if want := "# Overview\n\nWhy.\n\n## Details\n\n# 1 Goals\n\n## 1.1 First\n"; whole != want {
		t.Errorf("whole:\n got %q\nwant %q", whole, want)
	}
	branch, _ := docTreeMarkdown(items, "d1", "o")
	if want := "# Overview\n\nWhy.\n\n## Details\n"; branch != want {
		t.Errorf("branch of an unnumbered item:\n got %q\nwant %q", branch, want)
	}
	if branch, _ := docTreeMarkdown(items, "d1", "a"); branch != "# 1 Goals\n\n## 1.1 First\n" {
		t.Errorf("branch of a numbered item: %q", branch)
	}
}

func TestDocTreeUnnumberedAndAttrs(t *testing.T) {
	h := newDTHub(t)
	root := dtOK(t, "create", "--title", "T")["root"].(string)
	a := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "Overview", "--unnumbered")["item"].(string)
	b := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "Goals")["item"].(string)
	fm := filepath.Join(t.TempDir(), "fm.yml")
	if err := os.WriteFile(fm, []byte("title: x\ntags: [a, b]"), 0o600); err != nil {
		t.Fatal(err)
	}
	dtOK(t, "edit", dtDocID, root, "--field", "attrs.front_matter", "--file", fm)
	dtOK(t, "edit", dtDocID, b, "--field", "attrs.numbered", "--value", "false", "--json")
	dtOK(t, "edit", dtDocID, b, "--field", "attrs.numbered", "--value", "null", "--json")
	d := h.doc(t)
	if v, ok := d.items[a].Attrs["numbered"]; !ok || v != false {
		t.Errorf("add --unnumbered: attrs %v", d.items[a].Attrs)
	}
	if v := d.items[root].Attrs["front_matter"]; v != "title: x\ntags: [a, b]" {
		t.Errorf("edit attrs.front_matter: attrs %v", d.items[root].Attrs)
	}
	if _, ok := d.items[b].Attrs["numbered"]; ok {
		t.Errorf("edit attrs.numbered null did not drop the key: %v", d.items[b].Attrs)
	}
}

func TestDocTreeExportFrom(t *testing.T) {
	t.Setenv("SPOOL_HUB_URL", "")
	dir := t.TempDir()
	read := filepath.Join(dir, "read.json")
	body := `{"rev":3,"items":[{"id":"r","parent":"","depth":0,"body":"preamble"},` +
		`{"id":"x","parent":"r","outline":"","depth":1,"title":"Overview","body":"Why."},` +
		`{"id":"y","parent":"r","outline":"1","depth":1,"title":"Goals"}]}`
	if err := os.WriteFile(read, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	rc, md, errOut := captureRun(t, []string{"doctree", "export", "d1", "--from", read})
	if rc != 0 || md != "preamble\n\n# Overview\n\nWhy.\n\n# 1 Goals\n" {
		t.Fatalf("export --from: rc %d %q %s", rc, md, errOut)
	}
	if rc, _, errOut := captureRun(t, []string{"doctree", "export", "d1", "--from", filepath.Join(dir, "none")}); rc == 0 ||
		!strings.Contains(errOut, "no such file") {
		t.Errorf("export --from a missing file: rc %d %q", rc, errOut)
	}
}
