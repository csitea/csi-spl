package hub

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

// InviteIDForTest is inviteID for the hub_test package (spec 025 section 13)
// on a hub with no InviteIDKey (the per-process key).
func InviteIDForTest(tenant, email string) string {
	return inviteIDWith(processInviteKey(), tenant, email)
}

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
	k1, k2 := []byte("key-one"), []byte("key-two")
	id := inviteIDWith(k1, "t1", "Open@Example.com")
	if !isInviteID(id) || id != inviteIDWith(k1, "t1", "open@example.com") || id == inviteIDWith(k1, "t2", "open@example.com") {
		t.Errorf("inviteID %q: want stable per address, distinct per workspace", id)
	}
	// R7 W2: keyed, so the tenant and a guessed address do not give the id.
	unkeyed := sha256.Sum256([]byte("t1\x00open@example.com"))
	if id == "INV-"+hex.EncodeToString(unkeyed[:8]) || id == inviteIDWith(k2, "t1", "open@example.com") {
		t.Errorf("inviteID %q: want an id only the key holder can compute", id)
	}
	s := &Server{}
	if s.inviteID("t1", "open@example.com") != s.inviteID("t1", "open@example.com") || len(s.inviteIDKey()) != 32 {
		t.Errorf("no InviteIDKey: want a stable per-process key")
	}
	for _, bad := range []string{"INV-", "INV-zzzzzzzzzzzzzzzz", "HUM-1", "open@example.com", id + "0"} {
		if isInviteID(bad) {
			t.Errorf("isInviteID(%q) = true", bad)
		}
	}
}
