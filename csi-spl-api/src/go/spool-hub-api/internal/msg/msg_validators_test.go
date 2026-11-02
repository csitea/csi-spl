package msg

import (
	"sort"
	"strings"
	"testing"
)

// mvKinds is KindList split on its separator: the accepted kinds as help text
// and error messages name them.
func mvKinds() []string { return strings.Split(KindList, "|") }

func TestValidKindAcceptsEveryKindOfKindList(t *testing.T) {
	for _, k := range mvKinds() {
		if !ValidKind(k) {
			t.Errorf("ValidKind(%q) = false, want true", k)
		}
	}
}

func TestValidKindRefusesOthers(t *testing.T) {
	for _, k := range []string{"", "Task", "task ", "other"} {
		if ValidKind(k) {
			t.Errorf("ValidKind(%q) = true, want false", k)
		}
	}
}

func TestKindListEqualsTheAcceptedSet(t *testing.T) {
	listed := mvKinds()
	sort.Strings(listed)
	accepted := make([]string, 0, len(validKinds))
	for k, on := range validKinds {
		if on {
			accepted = append(accepted, k)
		}
	}
	sort.Strings(accepted)
	if got, want := strings.Join(listed, "|"), strings.Join(accepted, "|"); got != want {
		t.Errorf("KindList has %q, the accepted set is %q", got, want)
	}
}

func TestValidBoxID(t *testing.T) {
	cases := []struct {
		name string
		id   string
		want bool
	}{
		{"1 char", "a", true},
		{"32 chars", strings.Repeat("a", 32), true},
		{"empty", "", false},
		{"leading dash", "-box", false},
		{"upper case", "Box-a", false},
		{"33 chars", strings.Repeat("a", 33), false},
		{"slash", "a/b", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ValidBoxID(c.id); got != c.want {
				t.Errorf("ValidBoxID(%q) = %v, want %v", c.id, got, c.want)
			}
		})
	}
}
