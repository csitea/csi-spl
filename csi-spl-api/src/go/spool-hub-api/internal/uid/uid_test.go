package uid

import (
	"regexp"
	"testing"
)

var v4 = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func TestNewIsARandomV4(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 10000; i++ {
		id := New()
		if !v4.MatchString(id) {
			t.Fatalf("New() = %q, not a v4 UUID", id)
		}
		if seen[id] {
			t.Fatalf("New() repeated %q", id)
		}
		seen[id] = true
	}
}

// The golden values were computed by spool.deterministicUUID before SPL-1030
// moved it here: legacy .md messages must keep the ids they already have.
func TestFromSeedKeepsTheLegacyIDs(t *testing.T) {
	for seed, want := range map[string]string{
		"":           "e3b0c442-98fc-4c14-9afb-f4c8996fb924",
		"task:hello": "e7e08b1d-7149-47f5-8600-d552e6fba7a7",
		"msg:20260928T055424Z--CLE-01--x.md:body": "2a275c10-904f-4eb0-a42f-61880926a2c3",
	} {
		if got := FromSeed(seed); got != want {
			t.Errorf("FromSeed(%q) = %s, want %s", seed, got, want)
		}
	}
}

func TestHexLength(t *testing.T) {
	for _, n := range []int{0, 6, 16} {
		if got := Hex(n); len(got) != 2*n || !regexp.MustCompile(`^[0-9a-f]*$`).MatchString(got) {
			t.Errorf("Hex(%d) = %q", n, got)
		}
	}
	if Hex(16) == Hex(16) {
		t.Error("Hex(16) repeated")
	}
}
