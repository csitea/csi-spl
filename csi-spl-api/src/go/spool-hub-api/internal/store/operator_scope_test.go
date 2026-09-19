package store

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strings"
	"testing"
)

// operatorCallers is every store method allowed to run under the operator
// RLS scope (asOperator: every tenant's rows), with why the tenant cannot be
// named first (specs/017 FR-SEC-014). Some ARE reached from an HTTP route;
// each such route is keyed by something other than a tenant id the caller
// could choose. A new asOperator caller fails TestOperatorScopeCallers until
// it is added here with its reason, i.e. until someone has reviewed it.
var operatorCallers = map[string]string{
	"Sweep":              "retention sweeper (hub goroutine), global by design; no route",
	"SetTenantHost":      "tenant host reconciler (operator action / hub-tenant); no route",
	"Memberships":        "auth session (026 tenant from identity): the SESSION's own human_id, across that human's tenants",
	"HoldCheckout":       "POST /v1/checkout: the tenant does not exist yet (slug hold)",
	"checkoutAsOperator": "GetCheckout / CheckoutByProviderRef: unguessable checkout id or a verified webhook's provider ref",
	"ApplyPayment":       "verified payment webhook (signature checked before the store)",
	"SetClaimLink":       "paid webhook / claim mail, keyed by the checkout id",
	"ClaimCheckout":      "POST /v1/checkout/claim: checkout id + the claim secret's hash",
}

// TestOperatorScopeCallers: the set of functions in this package that call
// asOperator equals operatorCallers. CONTROL: the parse finds asOperator's
// own definition, so an empty result cannot pass for "no callers".
func TestOperatorScopeCallers(t *testing.T) {
	fset := token.NewFileSet()
	files, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	defined := false
	for _, f := range files {
		name := f.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			if fd.Name.Name == "asOperator" {
				defined = true
				continue
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if sel, ok := n.(*ast.SelectorExpr); ok && sel.Sel.Name == "asOperator" {
					found[fd.Name.Name] = true
				}
				// The raw operator setting belongs to asOperator and Migrate only.
				if id, ok := n.(*ast.Ident); ok && id.Name == "pgScopeOperator" && fd.Name.Name != "Migrate" {
					t.Errorf("%s sets the operator scope directly (pgScopeOperator): use asOperator and list it in operatorCallers", fd.Name.Name)
				}
				return true
			})
		}
	}
	if !defined {
		t.Fatal("control: asOperator's definition was not found - the scan reads the wrong files")
	}
	var extra, gone []string
	for fn := range found {
		if _, ok := operatorCallers[fn]; !ok {
			extra = append(extra, fn)
		}
	}
	for fn := range operatorCallers {
		if !found[fn] {
			gone = append(gone, fn)
		}
	}
	sort.Strings(extra)
	sort.Strings(gone)
	if len(extra) > 0 {
		t.Errorf("new asOperator caller(s) %v: every tenant's rows - add each to operatorCallers with why it cannot use inTenant", extra)
	}
	if len(gone) > 0 {
		t.Errorf("operatorCallers lists %v, which no longer call asOperator: drop them", gone)
	}
}
