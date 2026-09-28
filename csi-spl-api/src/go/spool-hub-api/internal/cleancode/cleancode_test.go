package cleancode

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// Limits measured on trunk 2026-09-28 (SPL-1029). Raise one only with a
// reason in the commit; lower it when the code allows.
const (
	maxFuncLines = 80 // a function longer than this is split, or listed below with a reason
	maxDepth     = 4  // nested if / for / switch / select levels (SPL-1032/1033 took it from 6)
	maxParams    = 8  // pass the struct instead (SPL-1039 took the maximum from 10)
)

// longFuncs are the functions over maxFuncLines when the gate landed. The
// list may only shrink: split one and delete its line. A NEW long function
// fails the gate; add it here only with a reason in the commit.
var longFuncs = map[string]bool{
	"internal/auth/cmd/auth-demo/main.go run":                            true,
	"internal/auth/fakeidp/fakeidp.go (*IdP).Handler":                    true,
	"internal/store/channels_postgres.go (*Postgres).ViewChannelStats":   true,
	"internal/store/humans_postgres.go (*Postgres).Admit":                true,
	"internal/store/view_postgres.go viewTopicsSQL":                      true,
	"internal/store/view_topics_batch.go (*Postgres).ViewTopicsMessages": true,
}

// folded are helpers that exist ONCE; the pattern may appear only in the
// named file (SPL-1030, SPL-1031).
var folded = []struct{ pattern, home, why string }{
	{"& 0x0f) | 0x40", "internal/uid/uid.go", "a UUID is minted by internal/uid (SPL-1030)"},
	{"json.NewEncoder(w).Encode(", "internal/wire/http.go", "a JSON answer goes through wire.WriteJSON / wire.WriteError (SPL-1031)"},
}

// banned are patterns no Go source may carry (SPL-1029 round 2).
var banned = []struct {
	re  *regexp.Regexp
	why string
}{
	{regexp.MustCompile(`(?i)\bselect\s+\*\s+from\b`), "name the columns a query reads, not SELECT * (a new column is not dragged through every read)"},
}

type fn struct {
	key                  string
	lines, params, depth int
}

func TestCleanCodeGate(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	fns, srcs := scan(t, root)
	if len(fns) < 1000 {
		t.Fatalf("scanned %d functions under %s: the walk is broken, not the code", len(fns), root)
	}
	seen := map[string]bool{}
	for _, f := range fns {
		if f.lines > maxFuncLines {
			seen[f.key] = true
			if !longFuncs[f.key] {
				t.Errorf("%s is %d lines (> %d): split it into named steps (see SPL-1036, SPL-1040)", f.key, f.lines, maxFuncLines)
			}
		}
		if f.depth > maxDepth {
			t.Errorf("%s nests %d levels (> %d): extract the inner loop body (see SPL-1032, SPL-1033)", f.key, f.depth, maxDepth)
		}
		if f.params > maxParams {
			t.Errorf("%s takes %d parameters (> %d): pass the struct the values belong to (see SPL-1039)", f.key, f.params, maxParams)
		}
	}
	var stale []string
	for k := range longFuncs {
		if !seen[k] {
			stale = append(stale, k)
		}
	}
	sort.Strings(stale)
	for _, k := range stale {
		t.Logf("longFuncs: %q is no longer over %d lines - delete its line", k, maxFuncLines)
	}
	for _, b := range banned {
		for path, src := range srcs {
			if loc := b.re.FindStringIndex(src); loc != nil {
				t.Errorf("%s:%d: %q: %s", path, strings.Count(src[:loc[0]], "\n")+1, src[loc[0]:loc[1]], b.why)
			}
		}
	}
	for _, fd := range folded {
		for path, src := range srcs {
			if path != fd.home && strings.Contains(src, fd.pattern) {
				t.Errorf("%s: %q is back outside %s: %s", path, fd.pattern, fd.home, fd.why)
			}
		}
	}
}

// scan parses every non-test .go file under root: one fn per declared
// function or method ("path Recv.Name"), and each file's source by path.
func scan(t *testing.T, root string) ([]fn, map[string]string) {
	t.Helper()
	fs := token.NewFileSet()
	var out []fn
	srcs := map[string]string{}
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return err
		}
		src, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		f, err := parser.ParseFile(fs, p, src, 0)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		srcs[rel] = string(src)
		for _, d := range f.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Body != nil {
				out = append(out, fn{key: rel + " " + funcName(fd),
					lines:  fs.Position(fd.End()).Line - fs.Position(fd.Pos()).Line + 1,
					params: fd.Type.Params.NumFields(), depth: depth(fd.Body)})
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out, srcs
}

func funcName(fd *ast.FuncDecl) string {
	if fd.Recv == nil || len(fd.Recv.List) == 0 {
		return fd.Name.Name
	}
	return "(" + recvType(fd.Recv.List[0].Type) + ")." + fd.Name.Name
}

func recvType(e ast.Expr) string {
	switch t := e.(type) {
	case *ast.StarExpr:
		return "*" + recvType(t.X)
	case *ast.Ident:
		return t.Name
	case *ast.IndexExpr:
		return recvType(t.X)
	}
	return "?"
}

// depth is the deepest nesting of if / for / range / switch / select in
// body; a func literal is its own scope and is not counted.
func depth(body ast.Node) int {
	deepest := 0
	var walk func(n ast.Node, d int)
	walk = func(n ast.Node, d int) {
		ast.Inspect(n, func(c ast.Node) bool {
			if c == n || c == nil {
				return true
			}
			switch c.(type) {
			case *ast.IfStmt, *ast.ForStmt, *ast.RangeStmt, *ast.SwitchStmt, *ast.TypeSwitchStmt, *ast.SelectStmt:
				deepest = max(deepest, d+1)
				walk(c, d+1)
				return false
			case *ast.FuncLit:
				return false
			}
			return true
		})
	}
	walk(body, 0)
	return deepest
}
