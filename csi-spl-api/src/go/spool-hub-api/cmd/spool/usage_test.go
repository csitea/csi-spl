package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"testing"
)

// TestUsageNamesEveryVerb is specs/047 W17: `spool` with no arguments names
// every verb run() dispatches. The verbs are read from main.go's switch
// statements, so a new case without a usage line turns this red.
func TestUsageNamesEveryVerb(t *testing.T) {
	f, err := parser.ParseFile(token.NewFileSet(), "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var verbs []string
	ast.Inspect(f, func(n ast.Node) bool {
		fn, ok := n.(*ast.FuncDecl)
		if !ok || fn.Name.Name != "run" {
			return true
		}
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			if cc, ok := n.(*ast.CaseClause); ok {
				for _, e := range cc.List {
					if lit, ok := e.(*ast.BasicLit); ok && lit.Kind == token.STRING {
						v, _ := strconv.Unquote(lit.Value)
						verbs = append(verbs, v)
					}
				}
			}
			return true
		})
		return false
	})
	if len(verbs) < 25 {
		t.Fatalf("read only %d verbs out of run(): %v", len(verbs), verbs)
	}
	verbs = append(verbs, "version") // the early return before the switch
	for _, v := range verbs {
		if !usageNames(v) {
			t.Errorf("usage does not name the verb %q", v)
		}
	}
	// control: a verb run() does not know is not found either
	if usageNames("hub-nosuch") {
		t.Error("usageNames matched a verb that is not in usage")
	}
}

// usageNames reports whether a usage line lists verb as a word (not as the
// prefix of a longer verb: hub-tenant vs hub-tenant-billing).
func usageNames(verb string) bool {
	for _, line := range strings.Split(usage, "\n") {
		if !strings.HasPrefix(line, "  ") || strings.HasPrefix(line, "    ") {
			continue
		}
		head, _, _ := strings.Cut(strings.TrimSpace(line), "  ")
		for _, w := range strings.Split(head, ",") {
			if strings.TrimSpace(w) == verb {
				return true
			}
		}
	}
	return false
}

// TestRunUsageExit pins the exit codes: no verb is an error, help is not.
func TestRunUsageExit(t *testing.T) {
	if rc := run(nil); rc != 1 {
		t.Errorf("spool with no args: rc %d, want 1", rc)
	}
	for _, h := range []string{"help", "-h", "--help"} {
		if rc := run([]string{h}); rc != 0 {
			t.Errorf("spool %s: rc %d, want 0", h, rc)
		}
	}
}
