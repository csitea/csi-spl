package hub

import (
	"fmt"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-2080: box_beat_list names every box whose rows reached the per-box cap
// (its read may be cut), and no box under it. CONTROL: one row short of the
// cap is not flagged.
func TestBoxBeatsAtCap(t *testing.T) {
	var rows []store.BoxBeat
	add := func(box string, n int) {
		for i := 0; i < n; i++ {
			rows = append(rows, store.BoxBeat{Box: box, PID: 1})
		}
	}
	if got := boxBeatsAtCap(nil); got == nil || len(got) != 0 {
		t.Fatalf("no rows: %#v, want []", got)
	}
	add("box-z", store.BoxBeatsMax)
	add("box-a", store.BoxBeatsMax)
	add("box-m", store.BoxBeatsMax-1)
	add("box-q", 3)
	if got := fmt.Sprint(boxBeatsAtCap(rows)); got != "[box-a box-z]" {
		t.Fatalf("at cap = %s, want [box-a box-z]", got)
	}
}
