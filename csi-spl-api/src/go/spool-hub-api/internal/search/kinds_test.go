package search

import (
	"slices"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// spec 033 K.2 (T022): is: takes every message kind of msg.KindList, plus
// relay, and nothing else for a message: 14 values. is:bug parses and matches
// a bug message only. CONTROL: drop "bug" from the enum and is:bug is refused.
func TestIsEnumHoldsTheThirteenKinds(t *testing.T) {
	var got []string
	for _, o := range Operators {
		if o.Name != OpIs {
			continue
		}
		for v, ts := range o.Enum {
			if slices.Contains(ts, TypeMessage) {
				got = append(got, v)
			}
		}
	}
	want := append(strings.Split(msg.KindList, "|"), "relay")
	slices.Sort(got)
	slices.Sort(want)
	if len(got) != 14 || !slices.Equal(got, want) {
		t.Fatalf("is: message values %v (%d), want %v (14)", got, len(got), want)
	}
	q, err := Parse("is:bug", now)
	if err != nil {
		t.Fatalf("is:bug: %v", err)
	}
	bug, note := mDM, mDM
	bug.Kind = "bug"
	if !MatchMsg(q.Root, bug) || MatchMsg(q.Root, note) {
		t.Fatalf("is:bug: bug %v, note %v; want true, false", MatchMsg(q.Root, bug), MatchMsg(q.Root, note))
	}
}
