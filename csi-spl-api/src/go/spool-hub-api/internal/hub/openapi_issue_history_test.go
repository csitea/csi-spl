package hub_test

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// openapi.json names every event the History tab returns, and no other
// (SPL-6507, R7 N1 of SPL-6480): the events are read from the IssueEvent*
// string constants of the store's non-test sources, so a new one that the
// reference does not list fails here without touching this test.
func TestOpenAPIIssueHistoryEvents(t *testing.T) {
	want := storeIssueEvents(t)
	listed := strings.Split(openapiIssueHistoryEvent(t), ", ")
	slices.Sort(listed)
	if !slices.Equal(listed, want) {
		t.Errorf("openapi.json history event lists %q, the store's IssueEvent* constants are %q", listed, want)
	}
}

// storeIssueEvents is the sorted values of every IssueEvent* string constant
// in internal/store.
func storeIssueEvents(t *testing.T) []string {
	t.Helper()
	names, err := filepath.Glob(filepath.Join("..", "store", "*.go"))
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	fset := token.NewFileSet()
	for _, n := range names {
		if strings.HasSuffix(n, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, n, nil, parser.SkipObjectResolution)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, issueEventConsts(f)...)
	}
	if len(out) == 0 {
		t.Fatal("no IssueEvent* constant found in internal/store")
	}
	slices.Sort(out)
	return out
}

func issueEventConsts(f *ast.File) []string {
	var out []string
	for _, d := range f.Decls {
		g, ok := d.(*ast.GenDecl)
		if !ok || g.Tok != token.CONST {
			continue
		}
		for _, s := range g.Specs {
			vs := s.(*ast.ValueSpec)
			for i, id := range vs.Names {
				if !strings.HasPrefix(id.Name, "IssueEvent") || i >= len(vs.Values) {
					continue
				}
				if lit, ok := vs.Values[i].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					v, _ := strconv.Unquote(lit.Value)
					out = append(out, v)
				}
			}
		}
	}
	return out
}

// openapiIssueHistoryEvent is the description of the history row's event.
func openapiIssueHistoryEvent(t *testing.T) string {
	t.Helper()
	var doc struct {
		Paths map[string]map[string]struct {
			Responses map[string]struct {
				Content map[string]struct {
					Schema struct {
						Properties map[string]struct {
							Items struct {
								Properties map[string]struct {
									Description string `json:"description"`
								} `json:"properties"`
							} `json:"items"`
						} `json:"properties"`
					} `json:"schema"`
				} `json:"content"`
			} `json:"responses"`
		} `json:"paths"`
	}
	if err := json.Unmarshal(openapiJSON, &doc); err != nil {
		t.Fatal(err)
	}
	d := doc.Paths["/v1/view/issues/{ref}/history"]["get"].Responses["200"].
		Content["application/json"].Schema.Properties["events"].Items.Properties["event"].Description
	if d == "" {
		t.Fatal("openapi.json has no history event description")
	}
	return d
}
