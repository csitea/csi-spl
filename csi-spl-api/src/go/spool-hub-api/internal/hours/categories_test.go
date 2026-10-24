// SPDX-License-Identifier: AGPL-3.0-only

package hours

import (
	"fmt"
	"strings"
	"testing"
)

// The T024 tests (spec 107 FR-28): a day's minutes split into rate categories
// from its start and end, and a week's overtime and extra flags. 2026-10-05
// is a Monday, 2026-10-10 a Saturday, all in Europe/Stockholm.

// catRules is the workspace default (18:00-22:00, 22:00-06:00) in Stockholm
// with the given holidays.
func catRules(t *testing.T, holidays ...string) CategoryRules {
	t.Helper()
	r, err := DefaultCategoryRules(stockholm(t))
	if err != nil {
		t.Fatal(err)
	}
	r.Holidays = map[string]bool{}
	for _, d := range holidays {
		r.Holidays[d] = true
	}
	return r
}

// catString prints a split in precedence order, zero categories left out.
func catString(c CategoryMinutes) string {
	var parts []string
	for _, k := range CategoryOrder {
		if c[k] != 0 {
			parts = append(parts, fmt.Sprintf("%s=%d", k, c[k]))
		}
	}
	return strings.Join(parts, " ")
}

func split(t *testing.T, from, to string, minutes int, r CategoryRules) string {
	t.Helper()
	loc := stockholm(t)
	got, err := SplitCategories(at(t, loc, from), at(t, loc, to), minutes, r)
	if err != nil {
		t.Fatal(err)
	}
	if got.Total() != minutes {
		t.Fatalf("total %d, want %d", got.Total(), minutes)
	}
	return catString(got)
}

func TestParseClockWindow(t *testing.T) {
	for _, tc := range []struct {
		in       string
		from, to int
	}{
		{"18:00-22:00", 18 * 60, 22 * 60},
		{"22:00-06:00", 22 * 60, 6 * 60},
		{" 07:30 - 09:15 ", 7*60 + 30, 9*60 + 15},
		{"20:00-24:00", 20 * 60, 24 * 60},
	} {
		w, err := ParseClockWindow(tc.in)
		if err != nil {
			t.Fatalf("%q: %v", tc.in, err)
		}
		if w.From != tc.from || w.To != tc.to {
			t.Fatalf("%q = %+v, want %d-%d", tc.in, w, tc.from, tc.to)
		}
	}
	for _, bad := range []string{"", "18:00", "18-22", "25:00-06:00", "18:60-22:00", "18:00-18:00", "24:00-06:00", "x:00-06:00", "18:00-22:00-23:00", "8:00-9:00"} {
		if _, err := ParseClockWindow(bad); err == nil {
			t.Fatalf("%q accepted", bad)
		}
	}
}

func TestClockWindowContainsOverMidnight(t *testing.T) {
	w, _ := ParseClockWindow("22:00-06:00")
	for m, want := range map[int]bool{22 * 60: true, 23*60 + 59: true, 0: true, 5*60 + 59: true, 6 * 60: false, 21*60 + 59: false, 12 * 60: false} {
		if got := w.Contains(m); got != want {
			t.Fatalf("Contains(%d) = %v, want %v", m, got, want)
		}
	}
}

// One row per category, then the precedence between them.
func TestSplitCategoriesPerCategory(t *testing.T) {
	for _, tc := range []struct {
		name, from, to string
		minutes        int
		holidays       []string
		want           string
	}{
		{"normal weekday", "2026-10-05 08:00", "2026-10-05 16:00", 480, nil, "normal=480"},
		{"evening", "2026-10-05 14:00", "2026-10-05 20:00", 360, nil, "evening=120 normal=240"},
		{"evening into the night", "2026-10-05 17:00", "2026-10-05 23:00", 360, nil, "night=60 evening=240 normal=60"},
		{"early morning is night", "2026-10-05 05:00", "2026-10-05 09:00", 240, nil, "night=60 normal=180"},
		{"weekend", "2026-10-10 08:00", "2026-10-10 16:00", 480, nil, "weekend=480"},
		{"weekend beats evening", "2026-10-10 16:00", "2026-10-10 20:00", 240, nil, "weekend=240"},
		{"night beats weekend", "2026-10-10 20:00", "2026-10-10 23:00", 180, nil, "night=60 weekend=120"},
		{"holiday beats everything", "2026-10-06 04:00", "2026-10-06 23:00", 1140, []string{"2026-10-06"}, "holiday=1140"},
		{"holiday on a weekend", "2026-10-10 08:00", "2026-10-10 12:00", 240, []string{"2026-10-10"}, "holiday=240"},
		{"empty row", "2026-10-05 08:00", "2026-10-05 08:00", 0, nil, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if s := split(t, tc.from, tc.to, tc.minutes, catRules(t, tc.holidays...)); s != tc.want {
				t.Fatalf("got %q, want %q", s, tc.want)
			}
		})
	}
}

// A night shift 22:00-06:00 crosses midnight: all of it is night; from a
// Friday into a Saturday it stays night (night > weekend); the minutes after
// midnight into a holiday are holiday, the ones before it are not.
func TestSplitCategoriesNightShiftOverMidnight(t *testing.T) {
	r := catRules(t)
	if s := split(t, "2026-10-05 22:00", "2026-10-06 06:00", 480, r); s != "night=480" {
		t.Fatalf("Mon night shift = %q", s)
	}
	if s := split(t, "2026-10-09 20:00", "2026-10-10 04:00", 480, r); s != "night=360 evening=120" {
		t.Fatalf("Fri into Sat = %q", s)
	}
	if s := split(t, "2026-12-24 22:00", "2026-12-25 06:00", 480, catRules(t, "2026-12-25")); s != "holiday=360 night=120" {
		t.Fatalf("into a holiday = %q", s)
	}
}

// The windows are the workspace's keys: other windows move the minutes.
func TestSplitCategoriesWorkspaceWindows(t *testing.T) {
	r := catRules(t)
	var err error
	if r.Night, err = ParseClockWindow("23:00-05:00"); err != nil {
		t.Fatal(err)
	}
	if r.Evening, err = ParseClockWindow("19:00-23:00"); err != nil {
		t.Fatal(err)
	}
	if s := split(t, "2026-10-05 18:00", "2026-10-06 00:00", 360, r); s != "night=60 evening=240 normal=60" {
		t.Fatalf("got %q", s)
	}
}

// A row whose minutes are under its start..end (the break, FR-26) is scaled
// down across its categories by the largest remainder; a row above its
// estimate (an activity day over the standard day, FR-15) runs on past the
// end.
func TestSplitCategoriesMinutesAgainstTheSpan(t *testing.T) {
	r := catRules(t)
	// 510 span minutes: normal 240, evening 240, night 30; scaled to 480.
	if s := split(t, "2026-10-05 14:00", "2026-10-05 22:30", 480, r); s != "night=28 evening=226 normal=226" {
		t.Fatalf("with a break = %q", s)
	}
	if s := split(t, "2026-10-05 08:00", "2026-10-05 16:30", 660, r); s != "evening=60 normal=600" {
		t.Fatalf("over the estimate = %q", s)
	}
}

// The local clock decides: the DST night of 2026-10-25 in Stockholm has 9
// real hours between 22:00 and 06:00, all of them night.
func TestSplitCategoriesDST(t *testing.T) {
	if s := split(t, "2026-10-24 22:00", "2026-10-25 06:00", 540, catRules(t)); s != "night=540" {
		t.Fatalf("got %q", s)
	}
}

func TestSplitCategoriesRefuses(t *testing.T) {
	loc := stockholm(t)
	r := catRules(t)
	for _, tc := range []struct {
		name, from, to string
		minutes        int
		rules          CategoryRules
	}{
		{"end before start", "2026-10-05 10:00", "2026-10-05 09:00", 60, r},
		{"over 24 hours", "2026-10-05 08:00", "2026-10-06 08:01", 60, r},
		{"negative minutes", "2026-10-05 08:00", "2026-10-05 09:00", -1, r},
		{"over a day of minutes", "2026-10-05 08:00", "2026-10-05 09:00", 1441, r},
		{"minutes with no span", "2026-10-05 08:00", "2026-10-05 08:00", 30, r},
		{"no zone", "2026-10-05 08:00", "2026-10-05 09:00", 60, CategoryRules{Evening: r.Evening, Night: r.Night}},
		{"no windows", "2026-10-05 08:00", "2026-10-05 09:00", 60, CategoryRules{Zone: loc}},
	} {
		if _, err := SplitCategories(at(t, loc, tc.from), at(t, loc, tc.to), tc.minutes, tc.rules); err == nil {
			t.Fatalf("%s: accepted", tc.name)
		}
	}
}

// flagsString prints the days that carry a flag.
func flagsString(fs []DayFlags) string {
	var parts []string
	for _, f := range fs {
		if f.Extra != 0 || f.Overtime != 0 {
			parts = append(parts, fmt.Sprintf("%s extra=%d overtime=%d", f.Day, f.Extra, f.Overtime))
		}
	}
	return strings.Join(parts, "; ")
}

// week is a week from Monday 2026-10-05, one value per day.
func week(minutes ...int) []WeekDay {
	out := make([]WeekDay, len(minutes))
	for i, m := range minutes {
		out[i] = WeekDay{Day: fmt.Sprintf("2026-10-%02d", 5+i), Minutes: m}
	}
	return out
}

func TestFlagWeek(t *testing.T) {
	threshold := DefaultOvertimeWeeklyMinutes(480)
	if threshold != 2400 {
		t.Fatalf("default threshold %d", threshold)
	}
	full := WeekRules{OvertimeWeeklyMinutes: threshold, StandardWeeklyMinutes: 2400}
	half := WeekRules{OvertimeWeeklyMinutes: threshold, StandardWeeklyMinutes: 1200}
	for _, tc := range []struct {
		name  string
		days  []WeekDay
		rules WeekRules
		want  string
	}{
		{"a standard week", week(480, 480, 480, 480, 480), full, ""},
		{"overtime on the day it is crossed", week(480, 480, 480, 480, 600), full, "2026-10-09 extra=0 overtime=120"},
		{"overtime on a Saturday", week(480, 480, 480, 480, 480, 240), full, "2026-10-10 extra=0 overtime=240"},
		{"long days up to the threshold", week(600, 600, 600, 600), full, ""},
		{"long days then a fifth", week(600, 600, 600, 600, 120), full, "2026-10-09 extra=0 overtime=120"},
		{"a half-day contract working full days", week(480, 480, 480, 480, 480), half,
			"2026-10-07 extra=240 overtime=0; 2026-10-08 extra=480 overtime=0; 2026-10-09 extra=480 overtime=0"},
		{"a half-day contract into overtime", week(480, 480, 480, 480, 480, 300), half,
			"2026-10-07 extra=240 overtime=0; 2026-10-08 extra=480 overtime=0; 2026-10-09 extra=480 overtime=0; 2026-10-10 extra=0 overtime=300"},
		{"a half-day contract under its standard", week(240, 240), half, ""},
		{"one day across both lines", week(1200, 1300), half, "2026-10-06 extra=1200 overtime=100"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := FlagWeek(tc.days, tc.rules)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != len(tc.days) {
				t.Fatalf("%d flags for %d days", len(got), len(tc.days))
			}
			if s := flagsString(got); s != tc.want {
				t.Fatalf("got %q, want %q", s, tc.want)
			}
		})
	}
}

// A week across two periods: the first period froze with its categories, so
// what its days would have carried lands on the week's last day, freezing
// now. The week's totals equal the unsplit week's.
func TestFlagWeekSplitAcrossPeriods(t *testing.T) {
	rules := WeekRules{OvertimeWeeklyMinutes: 2400, StandardWeeklyMinutes: 1200}
	days := week(480, 480, 480, 480, 480, 300, 0)
	days[0].Frozen, days[1].Frozen, days[2].Frozen = true, true, true
	got, err := FlagWeek(days, rules)
	if err != nil {
		t.Fatal(err)
	}
	want := "2026-10-08 extra=480 overtime=0; 2026-10-09 extra=480 overtime=0; 2026-10-10 extra=0 overtime=300; 2026-10-11 extra=240 overtime=0"
	if s := flagsString(got); s != want {
		t.Fatalf("got %q, want %q", s, want)
	}
	var extra, overtime int
	for _, f := range got {
		if f.Frozen && (f.Extra != 0 || f.Overtime != 0) {
			t.Fatalf("frozen day %s changed: %+v", f.Day, f)
		}
		extra += f.Extra
		overtime += f.Overtime
	}
	if extra != 1200 || overtime != 300 {
		t.Fatalf("week totals extra=%d overtime=%d", extra, overtime)
	}
	// The input order does not matter.
	rev := append([]WeekDay(nil), days...)
	for i, j := 0, len(rev)-1; i < j; i, j = i+1, j-1 {
		rev[i], rev[j] = rev[j], rev[i]
	}
	got2, err := FlagWeek(rev, rules)
	if err != nil {
		t.Fatal(err)
	}
	if s := flagsString(got2); s != want {
		t.Fatalf("reversed input: %q", s)
	}
}

func TestFlagWeekRefuses(t *testing.T) {
	ok := WeekRules{OvertimeWeeklyMinutes: 2400, StandardWeeklyMinutes: 2400}
	frozenLast := week(480, 480)
	frozenLast[1].Frozen = true
	for _, tc := range []struct {
		name  string
		days  []WeekDay
		rules WeekRules
	}{
		{"no days", nil, ok},
		{"no threshold", week(480), WeekRules{StandardWeeklyMinutes: 2400}},
		{"negative standard", week(480), WeekRules{OvertimeWeeklyMinutes: 2400, StandardWeeklyMinutes: -1}},
		{"negative minutes", week(-5), ok},
		{"a day over 1440", week(1441), ok},
		{"a bad date", []WeekDay{{Day: "2026-13-01", Minutes: 60}}, ok},
		{"the same day twice", []WeekDay{{Day: "2026-10-05"}, {Day: "2026-10-05"}}, ok},
		{"more than seven days", []WeekDay{{Day: "2026-10-05"}, {Day: "2026-10-12"}}, ok},
		{"the last day already frozen", frozenLast, ok},
	} {
		if _, err := FlagWeek(tc.days, tc.rules); err == nil {
			t.Fatalf("%s: accepted", tc.name)
		}
	}
}
