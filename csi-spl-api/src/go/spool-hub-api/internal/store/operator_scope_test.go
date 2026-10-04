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
	"Sweep":                "retention sweeper (hub goroutine), global by design; no route",
	"pruneCommitted":       "Sweep's committed-delivery prune (spec 059 S4), global by design; no route",
	"ConsumerLag":          "consumer lag report (spec 059 S4), fleet-wide by design; no route",
	"SweepClones":          "act-as clone expiry (hub sweeper goroutine), global by design; no route",
	"SweepMemberActivity":  "Activity-log auth-row retention sweep (hub sweeper goroutine), global by design; no route",
	"PruneLifecycleEvents": "agent_lifecycle_events 90-day retention (hub sweeper goroutine, spec 063 12), global by design; no route",
	"PrunePerfSamples":     "wui_perf_samples 30-day retention (hub sweeper goroutine, spec 066 4), global by design; no route",
	"SetTenantHost":        "tenant host reconciler (operator action / hub-tenant); no route",
	"Memberships":          "auth session (026 tenant from identity): the SESSION's own human_id, across that human's tenants",
	"LiveInviteTenants":    "sign-in that named no tenant (SPL-1230): the SESSION's own provider-verified address, its live invites across tenants",
	"HoldCheckout":         "POST /v1/checkout: the tenant does not exist yet (slug hold)",
	"checkoutAsOperator":   "GetCheckout / CheckoutByProviderRef: unguessable checkout id or a verified webhook's provider ref",
	"ApplyPayment":         "verified payment webhook (signature checked before the store)",
	"SetClaimLink":         "paid webhook / claim mail, keyed by the checkout id",
	"ClaimCheckout":        "POST /v1/checkout/claim: checkout id + the claim secret's hash",
	"ListWorkspaces":       "GET /v1/operator/workspaces (spec 074): every workspace by design; only an admin of the operator workspace reaches it",
	"OperatorTenant":       "which workspace is the operator one (rdb 0116, spec 074): one flagged row of the instance, unknown until read; returns its id only",
	"ClaimOperatorTenant":  "hub start (spec 074): flags the cnf operator workspace while no row is flagged; no route",
}

// operatorEntries are the only functions that set the operator scope:
// asOperator (a transaction) and asOperatorQuery (one read as one batch).
// A caller of either is an operator caller.
var operatorEntries = map[string]bool{"asOperator": true, "asOperatorQuery": true}

// TestOperatorScopeCallers: the set of functions in this package that call
// an operatorEntries function equals operatorCallers. CONTROL: the parse finds
// every entry's own definition, so an empty result cannot pass for "no callers".
func TestOperatorScopeCallers(t *testing.T) {
	fset := token.NewFileSet()
	files, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	defined := map[string]bool{}
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
			if operatorEntries[fd.Name.Name] {
				defined[fd.Name.Name] = true
				continue
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if sel, ok := n.(*ast.SelectorExpr); ok && operatorEntries[sel.Sel.Name] {
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
	for entry := range operatorEntries {
		if !defined[entry] {
			t.Fatalf("control: %s's definition was not found - the scan reads the wrong files", entry)
		}
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
