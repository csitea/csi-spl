package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// SPL-1900 (Qto gaps G1 + G2): the export gives back the md file as the
// author wrote it. testdata/doctree-export-fidelity.json is the one fixture
// every exporter is held to (this one, the WUI's branchToMarkdown in
// tests/unit/doctree-export-md.test.mjs, spl-doctree-md.py in
// csi-spl-orc doctree-export-md.tst.sh): a "## 1." heading keeps its dot
// (attrs.outline_dot), an indented first line keeps its indent, a run of
// blank lines at a section's edge stays (6 under one heading), text right
// under a heading or right above the next stays tight (attrs.tight,
// attrs.tight_end). Red before: "# 1 The job", the indent and the blank runs
// trimmed away, a blank line added under "# Overview".

type dtFidelityFixture struct {
	Doc    string   `json:"doc"`
	Items  []dtItem `json:"items"`
	Export string   `json:"export"`
}

func loadDTFidelity(t *testing.T) dtFidelityFixture {
	t.Helper()
	b, err := os.ReadFile("testdata/doctree-export-fidelity.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx dtFidelityFixture
	if err := json.Unmarshal(b, &fx); err != nil {
		t.Fatal(err)
	}
	return fx
}

func TestDocTreeMarkdownFidelity(t *testing.T) {
	fx := loadDTFidelity(t)
	got, err := docTreeMarkdown(fx.Items, fx.Doc, "")
	if err != nil {
		t.Fatal(err)
	}
	if got != fx.Export {
		t.Errorf("export:\n got %q\nwant %q", got, fx.Export)
	}
	for _, want := range []string{"\n# 1. The job\n", "\n## 1.1 Read\n\n    SPOOL_ROOT=", "\n## 1.2. Blank run\n\n\n\n\n\n\n# 2.", "\n# Overview\nRight under.\n# 3 Last\n"} {
		if !strings.Contains(got, want) {
			t.Errorf("export lacks %q", want)
		}
	}
}

// A body stored the old way (trimmed, no trailing newline, as the WUI and
// the import before SPL-1900 wrote it) exports as before: one blank line
// under the heading and one after the text.
func TestDocTreeMarkdownLegacyBody(t *testing.T) {
	items := []dtItem{
		{ID: "a", Outline: "1", Depth: 1, Title: "A", Body: "Text."},
		{ID: "b", Outline: "2", Depth: 1, Title: "B", Body: "More.\n"},
		{ID: "c", Outline: "3", Depth: 1, Title: "C"},
	}
	if got, _ := docTreeMarkdown(items, "d1", ""); got != "# 1 A\n\nText.\n\n# 2 B\n\nMore.\n\n# 3 C\n" {
		t.Errorf("legacy bodies: %q", got)
	}
}

func TestDocTreeAddFidelityFlags(t *testing.T) {
	h := newDTHub(t)
	dtOK(t, "create", "--title", "T")
	a := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "Job", "--dotted", "--tight", "--tight-end")["item"].(string)
	b := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "Plain")["item"].(string)
	d := h.doc(t)
	for _, k := range []string{"outline_dot", "tight", "tight_end"} {
		if v := d.items[a].Attrs[k]; v != true {
			t.Errorf("add --dotted --tight --tight-end: attrs.%s = %v (%v)", k, v, d.items[a].Attrs)
		}
	}
	if len(d.items[b].Attrs) != 0 {
		t.Errorf("a plain add wrote attrs %v", d.items[b].Attrs)
	}
}

// SPL-2024 (Qto gaps G3, G4): --outline keeps the md author's number in
// attrs.outline_author; a number the hub would not read back is refused.
func TestDocTreeAddAuthorOutline(t *testing.T) {
	h := newDTHub(t)
	dtOK(t, "create", "--title", "T")
	a := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "Zero", "--outline", "0", "--dotted")["item"].(string)
	b := dtOK(t, "add", dtDocID, "--kind", "heading", "--title", "Gap", "--outline", "3.1")["item"].(string)
	d := h.doc(t)
	if v := d.items[a].Attrs["outline_author"]; v != "0" {
		t.Errorf("add --outline 0: attrs.outline_author = %v (%v)", v, d.items[a].Attrs)
	}
	if v := d.items[b].Attrs["outline_author"]; v != "3.1" {
		t.Errorf("add --outline 3.1: attrs.outline_author = %v (%v)", v, d.items[b].Attrs)
	}
	for _, bad := range [][]string{{"--outline", "1."}, {"--outline", "x"}, {"--outline", "2", "--unnumbered"}} {
		args := append([]string{"add", dtDocID, "--kind", "heading", "--title", "Bad"}, bad...)
		if rc, _, errOut := captureRun(t, append([]string{"doctree"}, args...)); rc == 0 || !strings.Contains(errOut, "--outline") {
			t.Errorf("add %v: rc %d, stderr %q, want the --outline refusal", bad, rc, errOut)
		}
	}
}
