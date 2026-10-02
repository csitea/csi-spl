package store

import "testing"

// Spec 061 T011: every store validation site takes both grammars, the new
// c-004 and the legacy CLE-77952, and refuses a malformed id.
func TestAgentIDSitesTakeBothGrammars(t *testing.T) {
	for _, id := range []string{"c-004", "a-999", "CLE-77952", "GRK-3"} {
		if !ValidFleetAgent(id) || !ValidAskAgent(id) || !ValidAskAgent(id+"@box-desk") || !ValidFleetHolder(id+"@box-desk") {
			t.Errorf("%q refused by a fleet site", id)
		}
		l := FleetLane{Fleet: "f", AgentID: id, AgentBox: "box-a", State: "live"}
		if why := CheckFleetLane(l); why != "" {
			t.Errorf("lane %q: %s", id, why)
		}
	}
	for _, id := range []string{"c-000", "c-4", "C-004", "CLE-1234567890", "c-004@", "c-004@Box"} {
		if ValidAskAgent(id) && ValidFleetHolder(id) {
			t.Errorf("%q accepted", id)
		}
	}
	if ValidFleetHolder("c-004") {
		t.Error("a holder needs @<box>")
	}
}
