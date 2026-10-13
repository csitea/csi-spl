package main

import "testing"

// TestWalkThrough runs the demo's built-in walk-through: every provider
// signs in against the fake IdP, end to end on loopback.
func TestWalkThrough(t *testing.T) {
	if err := run(false, "127.0.0.1:0", "", ""); err != nil {
		t.Fatal(err)
	}
}
