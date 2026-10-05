package store

import (
	"slices"
	"testing"
)

// TestSortedKeysDeterministic pins sortedKeys: ascending, the same on every
// call whatever order the map iterates in, and nil for an empty map (its
// callers never pass one empty to the wire: see IDFact.Channels/Parties).
func TestSortedKeysDeterministic(t *testing.T) {
	m := map[string]bool{"t1": true, "c-002": true, "": true, "C-001": true, "a@sat": false}
	want := []string{"", "C-001", "a@sat", "c-002", "t1"}
	for range 50 {
		if got := sortedKeys(m); !slices.Equal(got, want) {
			t.Fatalf("sortedKeys = %q, want %q", got, want)
		}
	}
	if got := sortedKeys(map[string]bool{}); len(got) != 0 {
		t.Fatalf("empty map: got %q", got)
	}
}
