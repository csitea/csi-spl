package hub

import (
	"encoding/json"
	"os"
	"slices"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// costLabelKeepEnglish is the values of the WUI's keep-English list, which
// the hub's image does not carry: the copy must not drift.
func TestCostLabelKeepEnglishInStep(t *testing.T) {
	raw, err := os.ReadFile("../../../../../../csi-spl-wui/i18n/i18n-keep-english.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Values map[string]string `json:"values"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	want := make([]string, 0, len(f.Values))
	for v := range f.Values {
		want = append(want, v)
	}
	slices.Sort(want)
	got := slices.Sorted(slices.Values(costLabelKeepEnglish))
	if !slices.Equal(got, want) {
		t.Errorf("costLabelKeepEnglish %q\nwant the JSON's values %q", got, want)
	}
}

// 16.6.6: a token left or lost, a span, an empty or long text and the
// master text itself (unless a brand name) are refused.
func TestCostLabelAnswerWhy(t *testing.T) {
	long := string(make([]rune, 101))
	for _, c := range []struct {
		text, source string
		lost         []string
		want         string
	}{
		{"Palkka", "Salary", nil, ""},
		{"Salary", "Salary", nil, "same_as_master"},
		{"Claude", "Claude", nil, ""},
		{"Palkka [NAME_1]", "Salary", nil, "token_left"},
		{"Palkka", "Salary x", []string{"[NAME_1]"}, "token_lost"},
		{`Palkka <span translate="no">x</span>`, "Salary", nil, "span_left"},
		{" ", "Salary", nil, "length"},
		{long, "Salary", nil, "length"},
	} {
		if got := costLabelAnswerWhy(c.text, c.source, c.lost); got != c.want {
			t.Errorf("%q: %q, want %q", c.text, got, c.want)
		}
	}
}

// stale_locales lists the stale HAND rows only: a stale machine row is
// missing and re-made (16.6.4).
func TestCostEntryMarks(t *testing.T) {
	origins, stale := costEntryMarks(map[string]store.CostLabelMark{
		"en": {Origin: store.CostLabelHand}, "fi": {Origin: store.CostLabelHand, Stale: true},
		"bg": {Origin: store.CostLabelMachine, Stale: true}, "sv": {Origin: store.CostLabelReviewed},
	})
	if len(origins) != 4 || origins["sv"] != "reviewed" || !slices.Equal(stale, []string{"fi"}) {
		t.Errorf("origins %v stale %v", origins, stale)
	}
}
