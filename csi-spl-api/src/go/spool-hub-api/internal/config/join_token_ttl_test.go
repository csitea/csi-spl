package config

import (
	"testing"
	"time"
)

// spec 073 AC12: SPOOL_HUB_JOIN_TOKEN_TTL bounds are 5m..24h inclusive.
// Unset loads 1h (the cnf default). n = 1 load per value: 2 bounds that pass,
// 4 values that refuse startup, 1 unset.
func TestLoadHubJoinTokenTTL(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if h.JoinTokenTTL != time.Hour {
		t.Fatalf("unset: JoinTokenTTL %s, want 1h", h.JoinTokenTTL)
	}
	for v, want := range map[string]time.Duration{"5m": 5 * time.Minute, "24h": 24 * time.Hour} {
		t.Setenv("SPOOL_HUB_JOIN_TOKEN_TTL", v)
		h, err := LoadHub()
		if err != nil || h.JoinTokenTTL != want {
			t.Fatalf("%s: %v %v, want %s", v, err, h, want)
		}
	}
	// CONTROL: just outside each bound, zero and a non-duration refuse.
	for _, bad := range []string{"4m59s", "24h1s", "0s", "an hour"} {
		t.Setenv("SPOOL_HUB_JOIN_TOKEN_TTL", bad)
		if _, err := LoadHub(); err == nil {
			t.Fatalf("SPOOL_HUB_JOIN_TOKEN_TTL=%s was accepted", bad)
		}
	}
}
