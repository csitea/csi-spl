package hub

import "testing"

// InviteIDForTest is inviteID for the hub_test package (spec 025 section 13).
var InviteIDForTest = inviteID

// The masked label keeps the first letter and the domain only; the id has
// one shape and never carries the address.
func TestInviteLabelAndID(t *testing.T) {
	for in, want := range map[string]string{"open@example.com": "o…@example.com", "ä.b@example.com": "ä…@example.com", "@x": "…", "nodomain": "…"} {
		if got, masked := inviteLabel(in, false); got != want || !masked {
			t.Errorf("inviteLabel(%q) = %q %v, want %q masked", in, got, masked, want)
		}
	}
	if got, masked := inviteLabel("open@example.com", true); got != "open@example.com" || masked {
		t.Errorf("shown = %q %v", got, masked)
	}
	id := inviteID("t1", "Open@Example.com")
	if !isInviteID(id) || id != inviteID("t1", "open@example.com") || id == inviteID("t2", "open@example.com") {
		t.Errorf("inviteID %q: want stable per address, distinct per workspace", id)
	}
	for _, bad := range []string{"INV-", "INV-zzzzzzzzzzzzzzzz", "HUM-1", "open@example.com", id + "0"} {
		if isInviteID(bad) {
			t.Errorf("isInviteID(%q) = true", bad)
		}
	}
}
