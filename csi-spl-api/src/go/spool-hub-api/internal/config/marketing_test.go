package config

import (
	"slices"
	"testing"
)

// spec 090 §15: SPOOL_HUB_MARKETING_WORKSPACES is workspace ids or the one
// entry "all"; anything else stops the hub at boot. Unset = off everywhere.
func TestMarketingWorkspacesFailFast(t *testing.T) {
	for _, tc := range []struct {
		list []string
		ok   bool
	}{
		{nil, true},
		{[]string{"t1"}, true},
		{[]string{"t1", "spool"}, true},
		{[]string{"all"}, true},
		{[]string{"all", "t1"}, false}, // "all" stands alone
		{[]string{"T1"}, false},        // not a tenant id
		{[]string{"t1 spool"}, false},
	} {
		h := &Hub{MarketingWorkspaces: tc.list}
		if err := h.validateMarketing(); (err == nil) != tc.ok {
			t.Errorf("%q: err %v, want ok=%v", tc.list, err, tc.ok)
		}
	}
}

// The env value the 030 template renders (a comma list) parses to the ids.
func TestMarketingWorkspacesFromEnv(t *testing.T) {
	setHubBase(t)
	t.Setenv("SPOOL_HUB_MARKETING_WORKSPACES", "t1,spool")
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(h.MarketingWorkspaces, []string{"t1", "spool"}) {
		t.Fatalf("parsed %q, want [t1 spool]", h.MarketingWorkspaces)
	}
}
