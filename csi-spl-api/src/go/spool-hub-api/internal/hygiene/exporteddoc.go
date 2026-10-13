// Package hygiene holds source-tree gates that run as ordinary Go tests, so
// `go test ./...` (and with it run-all-tests.sh and CI) enforces them with no
// extra tool to download. The first is SPL-1049: every exported identifier in
// non-test Go carries a doc comment.
package hygiene

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"sort"
	"strings"
)

// UndocumentedExports walks every non-test .go file under root and returns one
// "<slash path relative to root>:<Name>" per exported identifier that has no
// doc comment, sorted. Methods are named "<Type>.<Method>" and are checked
// only when their receiver type is exported too. A const, var or type inside
// a grouped declaration counts as documented by the group's comment.
// Generated files and vendor/, testdata/ and dot directories are skipped.
func UndocumentedExports(root string) ([]string, error) {
	var out []string
	fset := token.NewFileSet()
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := d.Name()
		if d.IsDir() {
			if path != root && (name == "vendor" || name == "testdata" || strings.HasPrefix(name, ".")) {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			return nil
		}
		f, err := parser.ParseFile(fset, path, nil, parser.ParseComments|parser.SkipObjectResolution)
		if err != nil {
			return err
		}
		if ast.IsGenerated(f) {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		for _, n := range fileUndocumented(f) {
			out = append(out, filepath.ToSlash(rel)+":"+n)
		}
		return nil
	})
	sort.Strings(out)
	return out, err
}

// fileUndocumented names the undocumented exported identifiers of one file.
func fileUndocumented(f *ast.File) []string {
	var out []string
	for _, decl := range f.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if n, ok := funcName(d); ok && d.Doc == nil {
				out = append(out, n)
			}
		case *ast.GenDecl:
			out = append(out, genUndocumented(d)...)
		}
	}
	return out
}

// funcName is the checked name of a func or method, and whether it is
// exported (a method: both it and its receiver type).
func funcName(d *ast.FuncDecl) (string, bool) {
	if !d.Name.IsExported() {
		return "", false
	}
	if d.Recv == nil || len(d.Recv.List) == 0 {
		return d.Name.Name, true
	}
	recv := receiverType(d.Recv.List[0].Type)
	if !ast.IsExported(recv) {
		return "", false
	}
	return recv + "." + d.Name.Name, true
}

// receiverType strips pointers and type parameters off a receiver.
func receiverType(e ast.Expr) string {
	for {
		switch t := e.(type) {
		case *ast.StarExpr:
			e = t.X
		case *ast.IndexExpr:
			e = t.X
		case *ast.IndexListExpr:
			e = t.X
		case *ast.Ident:
			return t.Name
		default:
			return ""
		}
	}
}

// genUndocumented checks the types, consts and vars of one declaration: a
// spec is documented by its own comment or by the declaration's.
func genUndocumented(d *ast.GenDecl) []string {
	if d.Doc != nil {
		return nil
	}
	var out []string
	for _, spec := range d.Specs {
		switch s := spec.(type) {
		case *ast.TypeSpec:
			if s.Name.IsExported() && s.Doc == nil {
				out = append(out, s.Name.Name)
			}
		case *ast.ValueSpec:
			if s.Doc != nil {
				continue
			}
			for _, n := range s.Names {
				if n.IsExported() {
					out = append(out, n.Name)
				}
			}
		}
	}
	return out
}
