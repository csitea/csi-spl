package hub_test

import (
	"context"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-5181 (owner HUM-10, t1 8426e63e msgs b17ead41 and 573da484, t1 36406a93
// msg 97bab339): the operator workspace's product owner reads what its admin
// reads on Costs, Expenses and Monitoring -> Lanes, and nothing more.

// operatorReadPaths are the reads the one gate opens.
var operatorReadPaths = []string{
	"/v1/operator/cost-entries?type=hr",
	"/v1/operator/fleet-tokens?window=1h",
	"/v1/operator/fleet-tokens/paid",
	"/v1/operator/fleet-tokens/effective",
	"/v1/operator/fleet-lanes",
}

// TestOperatorReadGate: the operator product owner and admin read every route
// and the estate; a developer there, and the product owner and admin of
// another workspace, are refused each route and get no estate. /v1/view/me
// says operator_reader for exactly the two who pass. CONTROL: the admin's 200s
// and the estate answer show each 403 is the rule, not a broken route.
func TestOperatorReadGate(t *testing.T) {
	e, op, other, who, whoOther, _ := costReadEnv(t)
	pov := estatePov(t, e, op, who[rbac.Admin])
	cloud := "/v1/tenant/costs/cloud?month=2011-03&project=" + url.QueryEscape(pov)
	paths := append([]string{cloud}, operatorReadPaths...)
	for _, hum := range []string{who[rbac.Admin], who[rbac.ProductOwner]} {
		for _, p := range paths {
			if code, body := call(t, e, op, http.MethodGet, p, hum, nil); code != http.StatusOK {
				t.Errorf("reader %s on %s: %d %v, want 200", hum, p, code, body)
			}
		}
		if _, body := call(t, e, op, http.MethodGet, costPath, hum, nil); body["scope"] != "estate" {
			t.Errorf("reader %s: month scope %v, want estate", hum, body["scope"])
		}
		if _, me := call(t, e, op, http.MethodGet, "/v1/view/me", hum, nil); me["operator_reader"] != true {
			t.Errorf("reader %s: operator_reader %v, want true", hum, me["operator_reader"])
		}
	}
	for _, c := range []struct{ tid, hum string }{
		{op, who[rbac.Developer]}, {other, whoOther[rbac.ProductOwner]}, {other, whoOther[rbac.Admin]},
	} {
		for _, p := range paths {
			if code, body := call(t, e, c.tid, http.MethodGet, p, c.hum, nil); code != http.StatusForbidden {
				t.Errorf("%s of %s on %s: %d %v, want 403", c.hum, c.tid, p, code, body)
			}
		}
		if _, body := call(t, e, c.tid, http.MethodGet, costPath, c.hum, nil); body["scope"] == "estate" {
			t.Errorf("%s of %s: month scope estate", c.hum, c.tid)
		}
		if _, me := call(t, e, c.tid, http.MethodGet, "/v1/view/me", c.hum, nil); me["operator_reader"] != false {
			t.Errorf("%s of %s: operator_reader %v, want false", c.hum, c.tid, me["operator_reader"])
		}
	}
}

// TestOperatorProductOwnerWritesRefused: read only. Every write route of the
// paid items and the cost entries still answers the product owner 403.
func TestOperatorProductOwnerWritesRefused(t *testing.T) {
	e, op, _, who, _, _ := costReadEnv(t)
	for _, c := range []struct {
		method, path string
		body         any
	}{
		{http.MethodPost, "/v1/operator/cost-entries", map[string]any{"type": "hr", "label": "x", "amount": 1, "currency": "EUR", "period": "2011-03"}},
		{http.MethodDelete, "/v1/operator/cost-entries/00000000-0000-4000-8000-000000000000", nil},
		{http.MethodPost, "/v1/operator/fleet-tokens/paid", map[string]any{"vendor": "claude"}},
		{http.MethodPatch, "/v1/operator/fleet-tokens/paid/00000000-0000-4000-8000-000000000000", map[string]any{"note": "x"}},
		{http.MethodDelete, "/v1/operator/fleet-tokens/paid/00000000-0000-4000-8000-000000000000", nil},
	} {
		if code, body := call(t, e, op, c.method, c.path, who[rbac.ProductOwner], c.body); code != http.StatusForbidden {
			t.Errorf("%s %s: %d %v, want 403", c.method, c.path, code, body)
		}
	}
}

// TestOperatorReadActAsClone: a live clone of the operator product owner or
// admin is refused the gated reads and reads the workspace month, never the
// estate (SPL-4187). CONTROL: the person cloned reads the estate.
func TestOperatorReadActAsClone(t *testing.T) {
	e, op, _, who, _, _ := costReadEnv(t)
	cs, ok := e.st.(dmCloneStore)
	if !ok {
		t.Skip("act-as clone store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	for _, role := range []string{rbac.ProductOwner, rbac.Admin} {
		target := who[role]
		if _, body := call(t, e, op, http.MethodGet, costPath, target, nil); body["scope"] != "estate" {
			t.Fatalf("CONTROL: %s month scope %v, want estate", role, body["scope"])
		}
		cl, err := cs.StartClone(context.Background(), store.CloneStart{TenantID: op, TargetHum: target, AdminName: "Admin",
			CreatedBy: who[rbac.Admin], ExpiresAt: now.Add(time.Hour)}, now)
		if err != nil {
			t.Fatal(err)
		}
		for _, p := range operatorReadPaths {
			if code, body := call(t, e, op, http.MethodGet, p, cl.CloneHum, nil); code != http.StatusForbidden {
				t.Errorf("the clone of %s on %s: %d %v, want 403", role, p, code, body)
			}
		}
		if _, body := call(t, e, op, http.MethodGet, costPath, cl.CloneHum, nil); body["scope"] != "workspace" {
			t.Errorf("the clone of %s: month scope %v, want workspace", role, body["scope"])
		}
	}
}
