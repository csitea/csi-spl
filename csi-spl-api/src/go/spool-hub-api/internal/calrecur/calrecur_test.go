// SPDX-License-Identifier: AGPL-3.0-only

package calrecur

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func helsinki(t *testing.T) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation("Europe/Helsinki")
	if err != nil {
		t.Fatalf("load zone: %v", err)
	}
	return loc
}

func mustSeries(t *testing.T, rule string, start time.Time, dur time.Duration, zone string) Series {
	t.Helper()
	s, err := NewSeries("ev1", rule, start, start.Add(dur), zone)
	if err != nil {
		t.Fatalf("NewSeries(%q): %v", rule, err)
	}
	return s
}

func starts(occ []Occurrence, loc *time.Location) []string {
	out := make([]string, len(occ))
	for i, o := range occ {
		out[i] = o.Start.In(loc).Format("2006-01-02 15:04 MST")
	}
	return out
}

func TestParseSubset(t *testing.T) {
	ok := []string{
		"FREQ=DAILY",
		"FREQ=DAILY;INTERVAL=2;COUNT=10",
		"FREQ=WEEKLY;BYDAY=MO,WE",
		"FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;UNTIL=20261231T215959Z",
		"FREQ=MONTHLY;BYDAY=2TU",
		"FREQ=MONTHLY;BYDAY=-1FR;COUNT=3",
		"FREQ=MONTHLY;BYMONTHDAY=15",
		"FREQ=MONTHLY;BYMONTHDAY=-1",
		"FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=14",
		"FREQ=YEARLY;UNTIL=20301231",
		"COUNT=4;FREQ=DAILY",
	}
	for _, s := range ok {
		if _, err := Parse(s); err != nil {
			t.Errorf("Parse(%q) = %v, want accepted", s, err)
		}
	}
	refused := []string{
		"",
		"RRULE:FREQ=DAILY",
		"FREQ=HOURLY",
		"FREQ=SECONDLY",
		"freq=daily",
		"INTERVAL=2",
		"FREQ=DAILY;",
		"FREQ=DAILY;FREQ=WEEKLY",
		"FREQ=DAILY;COUNT=3;UNTIL=20261231T000000Z",
		"FREQ=DAILY;COUNT=0",
		"FREQ=DAILY;COUNT=+3",
		"FREQ=DAILY;COUNT=5001",
		"FREQ=DAILY;INTERVAL=0",
		"FREQ=DAILY;BYHOUR=9",
		"FREQ=DAILY;BYSETPOS=1",
		"FREQ=WEEKLY;WKST=SU",
		"FREQ=DAILY;BYDAY=MO",
		"FREQ=YEARLY;BYDAY=1MO",
		"FREQ=WEEKLY;BYDAY=-1FR",
		"FREQ=WEEKLY;BYDAY=MO,MO",
		"FREQ=WEEKLY;BYDAY=XX",
		"FREQ=MONTHLY;BYDAY=TU",
		"FREQ=MONTHLY;BYDAY=6TU",
		"FREQ=MONTHLY;BYDAY=0TU",
		"FREQ=MONTHLY;BYDAY=2TU;BYMONTHDAY=3",
		"FREQ=MONTHLY;BYMONTHDAY=0",
		"FREQ=MONTHLY;BYMONTHDAY=32",
		"FREQ=WEEKLY;BYMONTHDAY=1",
		"FREQ=MONTHLY;BYMONTH=3",
		"FREQ=YEARLY;BYMONTH=13",
		"FREQ=YEARLY;BYMONTH=-1",
		"FREQ=DAILY;UNTIL=2026-12-31",
		"FREQ=DAILY;UNTIL=20261231T000000",
		"FREQ=DAILY;UNTIL=20261332",
		"FREQ=DAILY;COUNT=2" + strings.Repeat(";INTERVAL=1", 50),
	}
	for _, s := range refused {
		if _, err := Parse(s); !errors.Is(err, ErrBadRule) {
			t.Errorf("Parse(%q) = %v, want ErrBadRule", s, err)
		}
	}
}

func TestNewSeriesRefuses(t *testing.T) {
	start := time.Date(2026, 10, 19, 6, 0, 0, 0, time.UTC)
	cases := []struct {
		name, rule, zone string
		end              time.Time
	}{
		{"until before start", "FREQ=DAILY;UNTIL=20261001T000000Z", "UTC", start.Add(time.Hour)},
		{"unknown zone", "FREQ=DAILY", "Mars/Olympus", start.Add(time.Hour)},
		{"host zone", "FREQ=DAILY", "Local", start.Add(time.Hour)},
		{"end before start", "FREQ=DAILY", "UTC", start.Add(-time.Hour)},
		{"refused rule", "FREQ=MINUTELY", "UTC", start.Add(time.Hour)},
		{"never reached", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30", "UTC", start.Add(time.Hour)},
	}
	for _, c := range cases {
		if _, err := NewSeries("ev1", c.rule, start, c.end, c.zone); !errors.Is(err, ErrBadRule) {
			t.Errorf("%s: NewSeries = %v, want ErrBadRule", c.name, err)
		}
	}
}

// AC-04: FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6 in Europe/Helsinki across the
// October daylight-saving change (2026-10-25) gives six occurrences, all at
// 09:00 local, and the UTC hour moves from 06 to 07.
func TestAC04DaylightSaving(t *testing.T) {
	loc := helsinki(t)
	start := time.Date(2026, 10, 19, 9, 0, 0, 0, loc)
	s := mustSeries(t, "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6", start, time.Hour, "Europe/Helsinki")
	from := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC)
	occ, err := s.Expand(nil, from, to, MaxOccurrences)
	if err != nil {
		t.Fatalf("Expand: %v", err)
	}
	want := []string{
		"2026-10-19 09:00 EEST", "2026-10-21 09:00 EEST",
		"2026-10-26 09:00 EET", "2026-10-28 09:00 EET",
		"2026-11-02 09:00 EET", "2026-11-04 09:00 EET",
	}
	if got := starts(occ, loc); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("starts = %v, want %v", got, want)
	}
	if occ[1].Start.Hour() != 6 || occ[2].Start.Hour() != 7 {
		t.Errorf("UTC hours = %d, %d, want 6, 7", occ[1].Start.Hour(), occ[2].Start.Hour())
	}
	until, ok := s.RecurUntil()
	if wantUntil := time.Date(2026, 11, 4, 8, 0, 0, 0, time.UTC); !ok || !until.Equal(wantUntil) {
		t.Errorf("RecurUntil = %v %v, want %v true", until, ok, wantUntil)
	}
}

// AC-04 continued, at the package level: "this" moves one occurrence (an
// exception row), a cancelled exception drops one, and an exception whose
// original start the (truncated) rule no longer produces is ignored.
func TestExpandExceptions(t *testing.T) {
	loc := helsinki(t)
	start := time.Date(2026, 10, 19, 9, 0, 0, 0, loc)
	s := mustSeries(t, "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6", start, time.Hour, "Europe/Helsinki")
	second := time.Date(2026, 10, 21, 9, 0, 0, 0, loc)
	moved := time.Date(2026, 10, 22, 14, 0, 0, 0, loc)
	fifth := time.Date(2026, 11, 2, 9, 0, 0, 0, loc)
	exc := []Exception{
		{EventID: "x1", OriginalStart: second, Start: moved, End: moved.Add(30 * time.Minute)},
		{EventID: "x2", OriginalStart: fifth, Cancelled: true},
		{EventID: "x3", OriginalStart: time.Date(2026, 10, 20, 9, 0, 0, 0, loc), Start: moved, End: moved},
	}
	from := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC)
	occ, err := s.Expand(exc, from, to, MaxOccurrences)
	if err != nil {
		t.Fatalf("Expand: %v", err)
	}
	want := []string{
		"2026-10-19 09:00 EEST", "2026-10-22 14:00 EEST",
		"2026-10-26 09:00 EET", "2026-10-28 09:00 EET", "2026-11-04 09:00 EET",
	}
	if got := starts(occ, loc); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("starts = %v, want %v", got, want)
	}
	m := occ[1]
	if m.ExceptionID != "x1" || !m.OriginalStart.Equal(second) || m.ID != "ev1_20261021T060000Z" {
		t.Errorf("moved occurrence = %+v", m)
	}
	if occ[0].ExceptionID != "" || occ[0].ID != "ev1_20261019T060000Z" {
		t.Errorf("plain occurrence = %+v", occ[0])
	}
}

// A moved occurrence shows where it was moved to: in a range that holds only
// its new time, not in a range that holds only its original one.
func TestExpandMovedAcrossRange(t *testing.T) {
	start := time.Date(2026, 1, 5, 9, 0, 0, 0, time.UTC)
	s := mustSeries(t, "FREQ=WEEKLY;BYDAY=MO", start, time.Hour, "")
	orig := time.Date(2026, 1, 12, 9, 0, 0, 0, time.UTC)
	to := time.Date(2026, 2, 20, 9, 0, 0, 0, time.UTC)
	exc := []Exception{{EventID: "x", OriginalStart: orig, Start: to, End: to.Add(time.Hour)}}
	day := 24 * time.Hour
	if occ, _ := s.Expand(exc, orig, orig.Add(day), MaxOccurrences); len(occ) != 0 {
		t.Errorf("original day: %d occurrences, want 0", len(occ))
	}
	occ, _ := s.Expand(exc, to, to.Add(day), MaxOccurrences)
	if len(occ) != 1 || occ[0].ExceptionID != "x" {
		t.Errorf("moved-to day: %+v, want the exception", occ)
	}
}

func TestMonthlyLastFriday(t *testing.T) {
	start := time.Date(2026, 10, 30, 15, 0, 0, 0, time.UTC)
	s := mustSeries(t, "FREQ=MONTHLY;BYDAY=-1FR;COUNT=4", start, time.Hour, "UTC")
	occ, err := s.Expand(nil, start, start.AddDate(1, 0, 0), MaxOccurrences)
	if err != nil {
		t.Fatalf("Expand: %v", err)
	}
	want := "2026-10-30 15:00 UTC|2026-11-27 15:00 UTC|2026-12-25 15:00 UTC|2027-01-29 15:00 UTC"
	if got := strings.Join(starts(occ, time.UTC), "|"); got != want {
		t.Errorf("starts = %s, want %s", got, want)
	}
}

// COUNT and the equivalent UNTIL give the same occurrences and the same
// recur_until; a date UNTIL is inclusive of that local day; no end = NULL.
func TestCountVersusUntil(t *testing.T) {
	loc := helsinki(t)
	start := time.Date(2026, 3, 27, 9, 0, 0, 0, loc)
	from, to := start.AddDate(0, 0, -1), start.AddDate(0, 1, 0)
	rules := []string{
		"FREQ=DAILY;COUNT=5",
		"FREQ=DAILY;UNTIL=20260331",
		"FREQ=DAILY;UNTIL=20260331T060000Z",
	}
	var first string
	var firstUntil time.Time
	for i, r := range rules {
		s := mustSeries(t, r, start, 30*time.Minute, "Europe/Helsinki")
		occ, err := s.Expand(nil, from, to, MaxOccurrences)
		if err != nil {
			t.Fatalf("%s: %v", r, err)
		}
		got := strings.Join(starts(occ, loc), "|")
		until, ok := s.RecurUntil()
		if !ok || len(occ) != 5 {
			t.Fatalf("%s: %d occurrences, bounded %v; want 5, true", r, len(occ), ok)
		}
		if i == 0 {
			first, firstUntil = got, until
			continue
		}
		if got != first || !until.Equal(firstUntil) {
			t.Errorf("%s: %s until %v, want %s until %v", r, got, until, first, firstUntil)
		}
	}
	if !strings.Contains(first, "2026-03-29 09:00 EEST") || !strings.HasPrefix(first, "2026-03-27 09:00 EET") {
		t.Errorf("spring change lost the wall clock: %s", first)
	}
	early := mustSeries(t, "FREQ=DAILY;UNTIL=20260331T055959Z", start, time.Hour, "Europe/Helsinki")
	if occ, _ := early.Expand(nil, from, to, MaxOccurrences); len(occ) != 4 {
		t.Errorf("UNTIL one second before the 5th: %d occurrences, want 4", len(occ))
	}
	if _, ok := mustSeries(t, "FREQ=DAILY", start, time.Hour, "UTC").RecurUntil(); ok {
		t.Error("unbounded series has a recur_until")
	}
}

// An occurrence that started before the range and is still running at its
// start overlaps it (089's starts_at < to AND ends_at >= from).
func TestExpandOverlapAtRangeStart(t *testing.T) {
	start := time.Date(2026, 6, 1, 22, 0, 0, 0, time.UTC)
	s := mustSeries(t, "FREQ=DAILY", start, 4*time.Hour, "UTC")
	from := time.Date(2026, 6, 3, 0, 0, 0, 0, time.UTC)
	occ, err := s.Expand(nil, from, from.Add(24*time.Hour), MaxOccurrences)
	if err != nil {
		t.Fatalf("Expand: %v", err)
	}
	if len(occ) != 2 || occ[0].Start.Day() != 2 || occ[1].Start.Day() != 3 {
		t.Errorf("got %v, want the 2nd (running) and the 3rd", starts(occ, time.UTC))
	}
}

func TestExpandCap(t *testing.T) {
	start := time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC)
	s := mustSeries(t, "FREQ=DAILY", start, time.Hour, "UTC")
	occ, err := s.Expand(nil, start, start.AddDate(0, 0, MaxOccurrences), MaxOccurrences)
	if err != nil || len(occ) != MaxOccurrences {
		t.Fatalf("exactly the cap: %d, %v; want %d, nil", len(occ), err, MaxOccurrences)
	}
	if _, err := s.Expand(nil, start, start.AddDate(0, 0, MaxOccurrences+1), MaxOccurrences); !errors.Is(err, ErrTooMany) {
		t.Errorf("one past the cap: %v, want ErrTooMany", err)
	}
	if _, err := s.Expand(nil, start, start.AddDate(0, 0, 11), 10); !errors.Is(err, ErrTooMany) {
		t.Errorf("past a remaining budget of 10: %v, want ErrTooMany", err)
	}
}

func TestOccurrenceID(t *testing.T) {
	ev := "3f2b8c1e-0d4a-4c3b-9a51-7e6f00000001"
	at := time.Date(2026, 10, 26, 9, 0, 0, 0, time.FixedZone("EET", 2*3600))
	id := OccurrenceID(ev, at)
	if id != ev+"_20261026T070000Z" {
		t.Fatalf("OccurrenceID = %s", id)
	}
	gotEv, gotAt, err := ParseOccurrenceID(id)
	if err != nil || gotEv != ev || !gotAt.Equal(at) {
		t.Errorf("ParseOccurrenceID = %s %v %v", gotEv, gotAt, err)
	}
	for _, bad := range []string{"", ev, "_20261026T070000Z", ev + "_2026-10-26", ev + "_20261026T070000"} {
		if _, _, err := ParseOccurrenceID(bad); !errors.Is(err, ErrBadOccurrenceID) {
			t.Errorf("ParseOccurrenceID(%q) = %v, want ErrBadOccurrenceID", bad, err)
		}
	}
}
