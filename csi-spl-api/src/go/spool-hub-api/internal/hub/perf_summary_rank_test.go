package hub

import (
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Refactor r2 #5: rankPerfSummary is a stable sort, p75 descending, a nil
// p75 last. Equal p75 and two nil rows keep the store's order.
func TestRankPerfSummaryTies(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	in := []store.PerfSummaryRow{
		{View: "1"},
		{View: "2", P75: f(100)},
		{View: "3", P75: f(300)},
		{View: "4"},
		{View: "5", P75: f(100)},
		{View: "6", P75: f(300)},
		{View: "7", P75: f(0)},
	}
	var got []string
	for _, r := range rankPerfSummary(in) {
		got = append(got, r.View)
	}
	if want := "3 6 2 5 7 1 4"; strings.Join(got, " ") != want {
		t.Fatalf("order = %v, want %s", got, want)
	}
}
