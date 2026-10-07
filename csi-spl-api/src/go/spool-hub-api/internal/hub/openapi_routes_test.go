package hub_test

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// The route gate (spec 104 §4.3): every /v1 operation the hub registers has
// exactly one operation in openapi.json, and every operation there has a
// route. The standard ServeMux cannot list its patterns, so the gate reads
// the source: the pattern of every .Handle / .HandleFunc call and of every
// marketingRoute call in the non-test files of internal/hub. A pattern is a
// string literal or a constant expression of literals and string constants
// (internal/hub's own, or an imported internal package's, e.g. edge.PathProbe).

//go:embed openapi.json
var openapiJSON []byte

const modulePath = "github.com/csitea/csi-spl/spool-hub-api/"

// knownHelper is the one non-constant registration allowed: the HandleFunc
// inside marketingRoute, whose callers pass a literal the gate reads instead.
const knownHelper = "marketingRoute"

// Exclusions, listed explicitly (spec 104 §2.1): every OPTIONS preflight, the
// methodless /v1/view/ catch-all (it answers only 404 / 405), and every
// pattern outside /v1 (/auth, checkout, /, /healthz, /version, /probe).
const (
	excludedMethod   = "OPTIONS"
	excludedCatchAll = "/v1/view/"
	includedPrefix   = "/v1/"
)

var wildcardRest = regexp.MustCompile(`\{([A-Za-z0-9_]+)\.\.\.\}`)

var openapiMethods = []string{"delete", "get", "head", "options", "patch", "post", "put", "trace"}

// registrations collects the pattern literals of one parsed file, and an
// error for each non-literal pattern outside the known helper.
func registrations(fset *token.FileSet, tab constTable, f *ast.File) (pats, errs []string) {
	for _, d := range f.Decls {
		fn, ok := d.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			p, err := registration(fset, tab, fn.Name.Name, n)
			if p != "" {
				pats = append(pats, p)
			}
			if err != "" {
				errs = append(errs, err)
			}
			return true
		})
	}
	return pats, errs
}

// registration answers the pattern of one call node, or why it is unreadable.
func registration(fset *token.FileSet, tab constTable, fn string, n ast.Node) (string, string) {
	call, ok := n.(*ast.CallExpr)
	if !ok {
		return "", ""
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return "", ""
	}
	arg := -1
	switch sel.Sel.Name {
	case "Handle", "HandleFunc":
		arg = 0
	case knownHelper:
		arg = 1
	}
	if arg < 0 || len(call.Args) <= arg {
		return "", ""
	}
	if s, ok := tab.eval(call.Args[arg], ""); ok {
		return s, ""
	}
	if id, ok := call.Args[arg].(*ast.Ident); ok && fn == knownHelper && id.Name == "pattern" {
		return "", ""
	}
	return "", fmt.Sprintf("%s: non-literal pattern in %s.%s: register routes with a string literal or teach the gate the helper",
		fset.Position(call.Pos()), fn, sel.Sel.Name)
}

// constTable maps a string constant to its expression: "name" for one of
// internal/hub, "pkg.name" for one of an imported internal package.
type constTable map[string]ast.Expr

// add records every const of f with a value, under prefix ("" or "pkg.").
func (tab constTable) add(prefix string, f *ast.File) {
	for _, d := range f.Decls {
		g, ok := d.(*ast.GenDecl)
		if !ok || g.Tok != token.CONST {
			continue
		}
		for _, sp := range g.Specs {
			vs := sp.(*ast.ValueSpec)
			for i, name := range vs.Names {
				if i < len(vs.Values) {
					tab[prefix+name.Name] = vs.Values[i]
				}
			}
		}
	}
}

// eval folds a string constant expression; pkg is the package e was written
// in ("" for internal/hub). false = not a constant the gate can read.
func (tab constTable) eval(e ast.Expr, pkg string) (string, bool) {
	switch x := e.(type) {
	case *ast.BasicLit:
		s, err := strconv.Unquote(x.Value)
		return s, x.Kind == token.STRING && err == nil
	case *ast.ParenExpr:
		return tab.eval(x.X, pkg)
	case *ast.BinaryExpr:
		l, okL := tab.eval(x.X, pkg)
		r, okR := tab.eval(x.Y, pkg)
		return l + r, x.Op == token.ADD && okL && okR
	case *ast.Ident:
		key := x.Name
		if pkg != "" {
			key = pkg + "." + x.Name
		}
		if v, ok := tab[key]; ok {
			return tab.eval(v, pkg)
		}
	case *ast.SelectorExpr:
		if id, ok := x.X.(*ast.Ident); ok && tab[id.Name+"."+x.Sel.Name] != nil {
			return tab.eval(tab[id.Name+"."+x.Sel.Name], id.Name)
		}
	}
	return "", false
}

// documented maps raw patterns to the "METHOD /v1/path" keys the reference
// must carry, after the exclusions and {x...} -> {x}.
func documented(pats []string) (map[string]bool, []string) {
	out := map[string]bool{}
	var errs []string
	for _, p := range pats {
		method, path, ok := strings.Cut(p, " ")
		if !ok {
			method, path = "", p
		}
		switch {
		case method == excludedMethod, p == excludedCatchAll, !strings.HasPrefix(path, includedPrefix):
			continue
		case method == "":
			errs = append(errs, fmt.Sprintf("methodless /v1 pattern %q: give it a method or list it as an exclusion", p))
			continue
		}
		out[method+" "+wildcardRest.ReplaceAllString(path, "{$1}")] = true
	}
	return out, errs
}

// specOperations reads the "METHOD /v1/path" keys of an OpenAPI document and
// fails on a missing or duplicate operationId.
func specOperations(raw []byte) (map[string]bool, []string) {
	var doc struct {
		Paths map[string]map[string]json.RawMessage `json:"paths"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, []string{"openapi.json does not parse: " + err.Error()}
	}
	out := map[string]bool{}
	ids := map[string]string{}
	var errs []string
	for path, item := range doc.Paths {
		for _, m := range openapiMethods {
			op, ok := item[m]
			if !ok {
				continue
			}
			key := strings.ToUpper(m) + " " + path
			out[key] = true
			if e := claimOperationID(ids, key, op); e != "" {
				errs = append(errs, e)
			}
		}
	}
	slices.Sort(errs)
	return out, errs
}

// claimOperationID records op's operationId under key, or says why it cannot.
func claimOperationID(ids map[string]string, key string, op json.RawMessage) string {
	var o struct {
		OperationID string `json:"operationId"`
	}
	_ = json.Unmarshal(op, &o)
	if o.OperationID == "" {
		return "operation without operationId: " + key
	}
	if prev, dup := ids[o.OperationID]; dup {
		return fmt.Sprintf("duplicate operationId %q: %s and %s", o.OperationID, prev, key)
	}
	ids[o.OperationID] = key
	return ""
}

// compareRoutes fails both directions, naming each route or operation.
func compareRoutes(routes, ops map[string]bool) []string {
	var errs []string
	for r := range routes {
		if !ops[r] {
			errs = append(errs, "route without an openapi.json operation: "+r)
		}
	}
	for o := range ops {
		if !routes[o] {
			errs = append(errs, "openapi.json operation without a route: "+o)
		}
	}
	slices.Sort(errs)
	return errs
}

// canonicalJSON is the `jq -S .` form: sorted keys, 2-space indent, no HTML
// escaping, numbers as written, one trailing newline.
func canonicalJSON(raw []byte) ([]byte, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// gate runs the whole check over parsed files and an OpenAPI document.
func gate(fset *token.FileSet, files []*ast.File, tab constTable, spec []byte) (int, []string) {
	var pats, errs []string
	for _, f := range files {
		p, e := registrations(fset, tab, f)
		pats, errs = append(pats, p...), append(errs, e...)
	}
	routes, e := documented(pats)
	errs = append(errs, e...)
	ops, e := specOperations(spec)
	errs = append(errs, e...)
	return len(routes), append(errs, compareRoutes(routes, ops)...)
}

// parseDir parses every non-test .go file of dir.
func parseDir(t *testing.T, fset *token.FileSet, dir string) []*ast.File {
	t.Helper()
	names, err := filepath.Glob(filepath.Join(dir, "*.go"))
	if err != nil {
		t.Fatal(err)
	}
	var files []*ast.File
	for _, n := range names {
		if strings.HasSuffix(n, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, n, nil, parser.SkipObjectResolution)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, f)
	}
	return files
}

// parseHub parses internal/hub and the constants of every internal package
// it imports.
func parseHub(t *testing.T) (*token.FileSet, []*ast.File, constTable) {
	t.Helper()
	fset := token.NewFileSet()
	files := parseDir(t, fset, ".")
	tab := constTable{}
	dirs := map[string]bool{}
	for _, f := range files {
		tab.add("", f)
		for _, im := range f.Imports {
			if p, ok := strings.CutPrefix(strings.Trim(im.Path.Value, `"`), modulePath); ok {
				dirs[p] = true
			}
		}
	}
	for d := range dirs {
		for _, f := range parseDir(t, fset, filepath.Join("..", "..", d)) {
			tab.add(f.Name.Name+".", f)
		}
	}
	return fset, files, tab
}

func TestOpenAPIRoutes(t *testing.T) {
	fset, files, tab := parseHub(t)
	n, errs := gate(fset, files, tab, openapiJSON)
	for _, e := range errs {
		t.Error(e)
	}
	if n < 100 {
		t.Errorf("gate found %d /v1 operations; the scan is broken (spec 104 §2.1 measured ~124)", n)
	}
	t.Logf("%d /v1 operations, each documented once", n)
}

func TestOpenAPIRoutesFileForm(t *testing.T) {
	var doc struct {
		OpenAPI string `json:"openapi"`
	}
	if err := json.Unmarshal(openapiJSON, &doc); err != nil {
		t.Fatal(err)
	}
	if doc.OpenAPI != "3.0.3" {
		t.Errorf("openapi = %q, want 3.0.3", doc.OpenAPI)
	}
	want, err := canonicalJSON(openapiJSON)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(want, openapiJSON) {
		t.Error("openapi.json is not in `jq -S .` form: rewrite it with jq -S .")
	}
}

// synthetic parses one source file and runs the gate on it with spec.
func synthetic(t *testing.T, src, spec string) []string {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "synthetic.go", src, parser.SkipObjectResolution)
	if err != nil {
		t.Fatal(err)
	}
	tab := constTable{}
	tab.add("", f)
	_, errs := gate(fset, []*ast.File{f}, tab, []byte(spec))
	return errs
}

const synthSrc = `package hub
const probe = "/v1/" + "probe"
func (s *Server) routeX(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/things/{id}", s.h)
	mux.HandleFunc("OPTIONS /v1/things/{id}", s.h)
	mux.HandleFunc("/v1/view/", s.h)
	mux.Handle("GET /healthz", s.h)
	mux.HandleFunc("PUT /v1/docs/{path...}", s.h)
	s.marketingRoute(mux, "GET /v1/marketing", s.h)
	mux.HandleFunc("GET "+probe, s.h)
}
func (s *Server) marketingRoute(mux *http.ServeMux, pattern string, h marketingHandler) {
	mux.HandleFunc(pattern, s.h)
}
`

// synthSpec is a minimal OpenAPI document with one operation per "METHOD path".
func synthSpec(ops ...string) string {
	paths := map[string]map[string]any{}
	for i, o := range ops {
		m, p, _ := strings.Cut(o, " ")
		if paths[p] == nil {
			paths[p] = map[string]any{}
		}
		paths[p][strings.ToLower(m)] = map[string]any{"operationId": fmt.Sprintf("op%d", i)}
	}
	b, _ := json.Marshal(map[string]any{"openapi": "3.0.3", "paths": paths})
	return string(b)
}

var synthOps = []string{"GET /v1/things/{id}", "PUT /v1/docs/{path}", "GET /v1/marketing", "GET /v1/probe"}

func TestOpenAPIRoutesSyntheticClean(t *testing.T) {
	// OPTIONS, /v1/view/ and /healthz are ignored; {path...} matches {path};
	// a constant pattern is read like a literal.
	if errs := synthetic(t, synthSrc, synthSpec(synthOps...)); len(errs) != 0 {
		t.Fatalf("clean synthetic input failed: %v", errs)
	}
}

func TestOpenAPIRoutesRouteWithoutOperation(t *testing.T) {
	errs := synthetic(t, synthSrc, synthSpec(synthOps[:2]...))
	wantErr(t, errs, "route without an openapi.json operation: GET /v1/marketing")
	wantErr(t, errs, "route without an openapi.json operation: GET /v1/probe")
}

func TestOpenAPIRoutesOperationWithoutRoute(t *testing.T) {
	errs := synthetic(t, synthSrc, synthSpec(append(synthOps, "DELETE /v1/things/{id}")...))
	wantErr(t, errs, "openapi.json operation without a route: DELETE /v1/things/{id}")
}

func TestOpenAPIRoutesDuplicateOperationID(t *testing.T) {
	spec := strings.Replace(synthSpec(synthOps...), `"op1"`, `"op0"`, 1)
	wantErr(t, synthetic(t, synthSrc, spec), `duplicate operationId "op0"`)
}

func TestOpenAPIRoutesNonLiteralPattern(t *testing.T) {
	src := synthSrc + `func (s *Server) routeY(mux *http.ServeMux) {
	p := "GET /v1/hidden"
	mux.HandleFunc(p, s.h)
}
`
	wantErr(t, synthetic(t, src, synthSpec(synthOps...)), "non-literal pattern in routeY.HandleFunc")
}

func TestOpenAPIRoutesIgnoresOptionsAndCatchAll(t *testing.T) {
	// an excluded pattern is no route: documenting it fails as an orphan operation
	for _, op := range []string{"OPTIONS /v1/things/{id}", "GET /v1/view/", "GET /healthz"} {
		errs := synthetic(t, synthSrc, synthSpec(append(synthOps, op)...))
		wantErr(t, errs, "openapi.json operation without a route: "+op)
	}
}

// wantErr fails unless one of errs contains want.
func wantErr(t *testing.T, errs []string, want string) {
	t.Helper()
	for _, e := range errs {
		if strings.Contains(e, want) {
			return
		}
	}
	t.Errorf("want an error containing %q, got %q", want, errs)
}
