package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-4451: GET /v1/view/me says operator_admin exactly when GET
// /v1/operator/fleet-load would answer the caller 200, so the WUI reads the
// fleet load only then instead of probing it into a 403. Every role of the
// operator workspace and of another workspace is checked against the route
// itself: the flag and the route's own answer must agree.
// CONTROL: the operator workspace's admin reads true and gets the 200, so
// the false rows are the role rule, not a flag that never turns on.
func TestViewMeOperatorAdminMatchesFleetLoad(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	type caller struct{ name, tenant, hum, role string }
	var all []caller
	for _, r := range rbac.RoleIDs {
		all = append(all, caller{"operator " + r, op, who[r], r}, caller{"other-workspace " + r, other, whoOther[r], r})
	}
	trues := 0
	for _, c := range all {
		code, me := call(t, e, c.tenant, http.MethodGet, "/v1/view/me", c.hum, nil)
		if code != http.StatusOK {
			t.Fatalf("%s: /v1/view/me = %d %v", c.name, code, me)
		}
		flag, present := me["operator_admin"].(bool)
		if !present {
			t.Fatalf("%s: /v1/view/me has no boolean operator_admin: %v", c.name, me)
		}
		fl, _ := call(t, e, c.tenant, http.MethodGet, "/v1/operator/fleet-load", c.hum, nil)
		if flag != (fl == http.StatusOK) {
			t.Errorf("%s: operator_admin = %v but GET /v1/operator/fleet-load = %d", c.name, flag, fl)
		}
		want := c.tenant == op && c.role == rbac.Admin
		if flag != want {
			t.Errorf("%s: operator_admin = %v, want %v", c.name, flag, want)
		}
		if flag {
			trues++
		}
	}
	if trues != 1 {
		t.Errorf("operator_admin true for %d callers, want exactly 1 (the operator admin)", trues)
	}
}

// With no operator workspace on the hub every caller reads false.
func TestViewMeOperatorAdminOffWithoutOperatorWorkspace(t *testing.T) {
	e, op, _, who, _ := operatorEnv(t, func(_, _ string) string { return "" })
	code, me := call(t, e, op, http.MethodGet, "/v1/view/me", who[rbac.Admin], nil)
	if code != http.StatusOK || me["operator_admin"] != false {
		t.Fatalf("no operator workspace: /v1/view/me = %d operator_admin=%v, want 200 false", code, me["operator_admin"])
	}
}
