package search

import (
	"slices"
	"testing"
	"time"
)

// Spec 100 section 15 (SPL-6251): type:calendar, the workspace's calendar
// entries. Its spellings name it, a plain search leaves it out (opt-in), and
// event stays the event log (owner poll answer B). CONTROL: type:event and
// the event log's aliases never select calendar.
func TestCalendarGrammar(t *testing.T) {
	now := time.Date(2026, 11, 22, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		q     string
		types []Type
	}{
		{"type:calendar SQ323", []Type{TypeCalendar}},
		{"type:cal SQ323", []Type{TypeCalendar}},
		{"type:calendars SQ323", []Type{TypeCalendar}},
		{"kind:CAL SQ323", []Type{TypeCalendar}},
		{"type:calendar,issue SQ323", []Type{TypeIssue, TypeCalendar}}, // response order
		{"type:calendar name:flight", []Type{TypeCalendar}},
		{"type:event SQ323", []Type{TypeEvent}}, // CONTROL
		{"type:log SQ323", []Type{TypeEvent}},   // CONTROL
	}
	for _, c := range cases {
		q, err := Parse(c.q, now)
		if err != nil {
			t.Errorf("%q: %v", c.q, err)
			continue
		}
		if !slices.Equal(q.Types, c.types) {
			t.Errorf("%q: types %v, want %v", c.q, q.Types, c.types)
		}
	}
	if _, err := Parse("type:calendar from:HUM-1 SQ323", now); err == nil {
		t.Errorf("type:calendar from:HUM-1: parsed, want bad_query (from: applies to no calendar entry)")
	}
	for _, plain := range []string{"SQ323", "name:flight"} {
		if q, _ := Parse(plain, now); slices.Contains(q.Types, TypeCalendar) {
			t.Errorf("%q: types %v, want no calendar (opt-in)", plain, q.Types)
		}
	}
	if TypeCalendar.Group() != "calendars" || !slices.Equal(Aliases(TypeCalendar), []string{"cal", "calendars"}) {
		t.Errorf("group %q aliases %v, want calendars / [cal calendars]", TypeCalendar.Group(), Aliases(TypeCalendar))
	}
	e := Entity{Type: TypeCalendar, Name: "Flight SQ323 to Riga", Text: []string{"Flight SQ323 to Riga", "window seat", "Terminal 2"}}
	for q, want := range map[string]bool{
		"sq323": true, "terminal": true, `"window seat"`: true, "name:flight": true, "name:window": false,
		"SQ323 -riga": false, "nowhere": false,
	} {
		p, err := Parse("type:calendar "+q, now)
		if err != nil || MatchEntity(p.Root, e) != want {
			t.Errorf("type:calendar %s: match %v (err %v), want %v", q, !want, err, want)
		}
	}
}
