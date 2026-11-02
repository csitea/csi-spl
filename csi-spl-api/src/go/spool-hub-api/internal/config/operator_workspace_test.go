package config

import "testing"

// spec 074: the bootstrap operator workspace is OperatorTenant, else the apex
// workspace, else none. The first row is the order: the explicit one wins.
func TestOperatorWorkspace(t *testing.T) {
	for _, tc := range []struct {
		name, operator, apex, want string
	}{
		{"both set", "ops", "t1", "ops"},
		{"operator only", "ops", "", "ops"},
		{"apex only", "", "t1", "t1"},
		{"both unset", "", "", ""},
	} {
		h := &Hub{OperatorTenant: tc.operator, WUIApexTenant: tc.apex}
		if got := h.OperatorWorkspace(); got != tc.want {
			t.Errorf("%s: OperatorWorkspace(operator=%q, apex=%q) = %q, want %q", tc.name, tc.operator, tc.apex, got, tc.want)
		}
	}
}

// specs/077: the demo workspace is named only while the demo is on; a name
// alone (it has an envDefault) must not open it.
func TestDemoTenantOnlyWhileEnabled(t *testing.T) {
	for _, tc := range []struct {
		name      string
		enabled   bool
		workspace string
		want      string
	}{
		{"off with a name", false, "demo", ""},
		{"off without a name", false, "", ""},
		{"on with a name", true, "demo", "demo"},
	} {
		h := &Hub{DemoEnabled: tc.enabled, DemoWorkspace: tc.workspace}
		if got := h.DemoTenant(); got != tc.want {
			t.Errorf("%s: DemoTenant(enabled=%v, workspace=%q) = %q, want %q", tc.name, tc.enabled, tc.workspace, got, tc.want)
		}
	}
}
