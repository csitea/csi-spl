package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// SPL-1612: a doc's preamble, the hidden root's body (the text before
// section 1), opens the whole-document export, from the hub and from a
// saved `read <doc> --item <root>` answer; a branch export has none, and a
// picture in the preamble is Figure 1. Red before: the export never read
// the root, so the preamble was lost.

func TestDocTreeMarkdownPreamble(t *testing.T) {
	pic := "![map](/v1/workspace/doctree/d1/images/" + strings.Repeat("0", 64) + ".png)"
	items := []dtItem{
		{ID: "r", Depth: 0, Body: "  Who holds it.\n\n" + pic + "\n"},
		{ID: "a", Parent: "r", Outline: "1", Depth: 1, Title: "Job", Body: "x " + pic},
	}
	whole, _ := docTreeMarkdown(items, "d1", "")
	want := "Who holds it.\n\n" + pic + "\n\n*Figure 1: map*\n\n# 1 Job\n\nx " + pic + "\n\n*Figure 2: map*\n"
	if whole != want {
		t.Errorf("whole:\n got %q\nwant %q", whole, want)
	}
	if branch, _ := docTreeMarkdown(items, "d1", "a"); branch != "# 1 Job\n\nx "+pic+"\n\n*Figure 2: map*\n" {
		t.Errorf("a branch carried the preamble: %q", branch)
	}
	if only, _ := docTreeMarkdown(items[:1], "d1", ""); only != "Who holds it.\n\n"+pic+"\n\n*Figure 1: map*\n" {
		t.Errorf("a doc with a preamble only: %q", only)
	}
	if blank, _ := docTreeMarkdown([]dtItem{{ID: "r", Body: " \n"}, items[1]}, "d1", ""); strings.HasPrefix(blank, "\n") {
		t.Errorf("a blank root body left a gap: %q", blank)
	}
}

func TestDocTreeExportPreambleFromHub(t *testing.T) {
	newDTHub(t)
	root := dtOK(t, "create", "--title", "T")["root"].(string)
	pre := filepath.Join(t.TempDir(), "pre.md")
	if err := os.WriteFile(pre, []byte("For whoever holds the seat.\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	dtOK(t, "edit", dtDocID, root, "--field", "body", "--file", pre)
	dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "Job", "--text", "Run it.")
	rc, md, errOut := captureRun(t, []string{"doctree", "export", dtDocID})
	if want := "For whoever holds the seat.\n\n# 1 Job\n\nRun it.\n"; rc != 0 || md != want {
		t.Fatalf("export: rc %d\n got %q\nwant %q %s", rc, md, want, errOut)
	}
}
