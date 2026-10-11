package main

import (
	"strings"
	"testing"
)

// The thirteen doctree verbs on 2026-10-12; TestDocTreeHelpListsTheDispatchTable
// catches a fourteenth that the help page would miss.
var dtHelpVerbs = []string{"list", "nodes", "folder", "move-node", "create", "head", "read",
	"add", "edit", "move", "delete", "rename", "export"}

// dtHelpPageOK checks one help page: every verb with its usage line, and the
// four-line example (create, add heading, add para, export).
func dtHelpPageOK(t *testing.T, name, page string) {
	t.Helper()
	for _, v := range dtHelpVerbs {
		if !strings.Contains(page, "\n  "+v+" ") {
			t.Errorf("%s: verb %q is not listed", name, v)
		}
		if !strings.Contains(page, "usage: spool doctree "+v) {
			t.Errorf("%s: no usage line for %q", name, v)
		}
	}
	for _, ex := range []string{
		"spool doctree create --title",
		"spool doctree add <doc> --kind heading --title",
		"spool doctree add <doc> --kind para --text",
		"spool doctree export <doc>",
	} {
		if !strings.Contains(page, ex) {
			t.Errorf("%s: the example lacks %q", name, ex)
		}
	}
}

func TestDocTreeHelp(t *testing.T) {
	for _, flag := range []string{"--help", "-h", "help"} {
		rc, out, errOut := captureRun(t, []string{"doctree", flag})
		if rc != 0 {
			t.Errorf("doctree %s: rc %d, want 0; stderr %q", flag, rc, errOut)
		}
		dtHelpPageOK(t, "doctree "+flag, out)
	}
	rc, out, errOut := captureRun(t, []string{"doctree"})
	if rc != 2 {
		t.Errorf("doctree alone: rc %d, want 2", rc)
	}
	if out != "" {
		t.Errorf("doctree alone wrote stdout %q, want the page on stderr", out)
	}
	dtHelpPageOK(t, "doctree alone", errOut)
}

// TestDocTreeHelpListsTheDispatchTable: the page is built from the table the
// dispatcher routes by, and each verb's usage there is what its own -h prints.
func TestDocTreeHelpListsTheDispatchTable(t *testing.T) {
	if len(docTreeVerbs) != len(dtHelpVerbs) {
		t.Errorf("dispatch table has %d verbs, the help test knows %d: add the new one to dtHelpVerbs",
			len(docTreeVerbs), len(dtHelpVerbs))
	}
	page := docTreeHelp()
	for _, v := range docTreeVerbs {
		if v.purpose == "" || !strings.Contains(page, "\n  "+v.name+" ") {
			t.Errorf("verb %q: no purpose line in the help", v.name)
		}
		rc, _, errOut := captureRun(t, []string{"doctree", v.name, "-h"})
		if rc != 1 {
			t.Errorf("doctree %s -h: rc %d, want 1 (unchanged)", v.name, rc)
		}
		if strings.TrimSpace(errOut) != v.usage {
			t.Errorf("doctree %s -h prints %q, the help table says %q", v.name, strings.TrimSpace(errOut), v.usage)
		}
	}
}
