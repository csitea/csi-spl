// SPDX-License-Identifier: AGPL-3.0-only

package hours

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

// Every test pairs its case with a control that differs in one input and must
// come out differently, so a test cannot pass on an engine that ignores the
// rule it names. Days are 2026-10-07 in Europe/Stockholm (CEST, +02:00)
// unless a test says otherwise.

func stockholm(t *testing.T) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation("Europe/Stockholm")
	if err != nil {
		t.Skipf("no tz database: %v", err)
	}
	return loc
}

// at is a local wall-clock time "2006-01-02 15:04" in loc.
func at(t *testing.T, loc *time.Location, s string) time.Time {
	t.Helper()
	v, err := time.ParseInLocation("2006-01-02 15:04", s, loc)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// hm is a local time on the default day.
func hm(t *testing.T, loc *time.Location, s string) time.Time {
	t.Helper()
	return at(t, loc, "2026-10-07 "+s)
}

func post(t *testing.T, loc *time.Location, s, target string) Minute {
	t.Helper()
	return Minute{At: hm(t, loc, s), Target: target, Src: SrcPost}
}

// tabs is one tab minute per minute in [from, to], both local on the default day.
func tabs(t *testing.T, loc *time.Location, from, to, target string) []Minute {
	t.Helper()
	var out []Minute
	for m := hm(t, loc, from); !m.After(hm(t, loc, to)); m = m.Add(time.Minute) {
		out = append(out, Minute{At: m, Target: target, Src: SrcTab})
	}
	return out
}

func run(t *testing.T, in Input) []Day {
	t.Helper()
	days, err := Suggest(in)
	if err != nil {
		t.Fatal(err)
	}
	return days
}

// summary is "date total: target=min ... | date ...", for compact asserts.
func summary(days []Day) string {
	var parts []string
	for _, d := range days {
		var rows []string
		for _, r := range d.Rows {
			rows = append(rows, fmt.Sprintf("%s=%d", r.Target, r.Minutes))
		}
		parts = append(parts, fmt.Sprintf("%s %d: %s", d.Date, d.Minutes, strings.Join(rows, " ")))
	}
	return strings.Join(parts, " | ")
}

func expect(t *testing.T, name string, in Input, want string) {
	t.Helper()
	if got := summary(run(t, in)); got != want {
		t.Errorf("%s:\n got  %s\n want %s", name, got, want)
	}
}

// workedExample is spec 1.1's: posts 09:00 and 09:04, reading 09:05..09:20,
// nothing until 09:45, a glance at 09:46 (a tab, or a post with glancePost).
func workedExample(t *testing.T, loc *time.Location, glancePost bool) []Minute {
	t.Helper()
	in := []Minute{post(t, loc, "09:00", "t:a"), post(t, loc, "09:04", "t:a")}
	in = append(in, tabs(t, loc, "09:05", "09:20", "t:a")...)
	glance := Minute{At: hm(t, loc, "09:46"), Target: "t:b", Src: SrcTab}
	if glancePost {
		glance.Src = SrcPost
	}
	return append(in, glance)
}

func TestWorkedExample(t *testing.T) {
	loc := stockholm(t)
	expect(t, "09:46 a tab glance: 0:21",
		Input{Minutes: workedExample(t, loc, false), IdleMinutes: 10, Loc: loc},
		"2026-10-07 21: t:a=21")
	expect(t, "control, 09:46 a reply: 0:21 + 0:01",
		Input{Minutes: workedExample(t, loc, true), IdleMinutes: 10, Loc: loc},
		"2026-10-07 22: t:a=21 ws=1")
	expect(t, "control, N = 30 bridges the 25-minute gap to t:a",
		Input{Minutes: workedExample(t, loc, false), IdleMinutes: 30, Loc: loc},
		"2026-10-07 47: t:a=46 ws=1")
	days := run(t, Input{Minutes: workedExample(t, loc, false), IdleMinutes: 10, Loc: loc})
	want := []Span{{hm(t, loc, "09:00").UTC(), hm(t, loc, "09:21").UTC()}}
	if !reflect.DeepEqual(days[0].Rows[0].Blocks, want) {
		t.Errorf("blocks %v, want %v (no idle tail past 09:21)", days[0].Rows[0].Blocks, want)
	}
}

func TestGapAtMostNBridgedNoIdleTail(t *testing.T) {
	loc := stockholm(t)
	pair := func(second string) Input {
		return Input{Minutes: []Minute{post(t, loc, "10:00", "t:a"), post(t, loc, second, "t:a")}, IdleMinutes: 10, Loc: loc}
	}
	expect(t, "one post: 1 minute, no tail", Input{Minutes: []Minute{post(t, loc, "10:00", "t:a")}, IdleMinutes: 10, Loc: loc},
		"2026-10-07 1: ws=1")
	expect(t, "gap of 10 = N: bridged", pair("10:11"), "2026-10-07 12: t:a=12")
	expect(t, "control, gap of 11 > N: two 1-minute blocks", pair("10:12"), "2026-10-07 2: ws=2")
}

func TestFloorTabOnly(t *testing.T) {
	loc := stockholm(t)
	expect(t, "tab-only 2 minutes: dropped",
		Input{Minutes: tabs(t, loc, "11:00", "11:01", "t:a"), IdleMinutes: 10, Loc: loc}, "")
	expect(t, "control, tab-only 3 minutes: kept",
		Input{Minutes: tabs(t, loc, "11:00", "11:02", "t:a"), IdleMinutes: 10, Loc: loc}, "2026-10-07 3: ws=3")
	expect(t, "control, 1 minute with a post: kept",
		Input{Minutes: []Minute{post(t, loc, "11:00", "t:a")}, IdleMinutes: 10, Loc: loc}, "2026-10-07 1: ws=1")
	expect(t, "control, 1 minute in a meeting: kept",
		Input{Meetings: []Meeting{{EventID: "e1", Start: hm(t, loc, "11:00"), End: hm(t, loc, "11:01")}}, IdleMinutes: 10, Loc: loc},
		"2026-10-07 1: ws=1")
}

func TestPostOverTab(t *testing.T) {
	loc := stockholm(t)
	in := tabs(t, loc, "12:00", "12:09", "t:a")
	in = append(in, post(t, loc, "12:05", "t:b"))
	// 12:05 goes to t:b; 12:06..12:09 stay t:a (owned minutes, not a gap).
	expect(t, "the post wins its minute",
		Input{Minutes: in, IdleMinutes: 10, Loc: loc}, "2026-10-07 10: t:a=9 ws=1")
	ctl := append(tabs(t, loc, "12:00", "12:09", "t:a"), Minute{At: hm(t, loc, "12:05"), Target: "t:b", Src: SrcTab})
	expect(t, "control, a second tab row does not take the minute",
		Input{Minutes: ctl, IdleMinutes: 10, Loc: loc}, "2026-10-07 10: t:a=10")
}

func TestOverlappingMeetingsNeverExceedWallClock(t *testing.T) {
	loc := stockholm(t)
	late := Meeting{EventID: "e2", Start: hm(t, loc, "10:30"), End: hm(t, loc, "11:30")}
	early := Meeting{EventID: "e1", Start: hm(t, loc, "10:00"), End: hm(t, loc, "11:00")}
	expect(t, "overlap: 1:30 wall clock, earliest start wins",
		Input{Meetings: []Meeting{late, early}, IdleMinutes: 10, Loc: loc},
		"2026-10-07 90: cal:e1=60 cal:e2=30")
	late.Start, late.End = hm(t, loc, "11:00"), hm(t, loc, "12:00")
	expect(t, "control, back to back: 2:00",
		Input{Meetings: []Meeting{late, early}, IdleMinutes: 10, Loc: loc},
		"2026-10-07 120: cal:e1=60 cal:e2=60")
}

func TestPostInsideMeetingGoesToMeeting(t *testing.T) {
	loc := stockholm(t)
	mt := []Meeting{{EventID: "e1", Start: hm(t, loc, "14:00"), End: hm(t, loc, "15:00")}}
	in := tabs(t, loc, "14:20", "14:40", "t:x")
	in = append(in, post(t, loc, "14:30", "t:x"))
	expect(t, "a post and reading inside the meeting",
		Input{Minutes: in, Meetings: mt, IdleMinutes: 10, Loc: loc}, "2026-10-07 60: cal:e1=60")
	ctl := []Minute{post(t, loc, "15:30", "t:x"), post(t, loc, "15:35", "t:x")}
	expect(t, "control, posts after the meeting keep their topic",
		Input{Minutes: ctl, Meetings: mt, IdleMinutes: 10, Loc: loc}, "2026-10-07 66: cal:e1=60 t:x=6")
}

func TestTopicMeeting(t *testing.T) {
	loc := stockholm(t)
	mt := Meeting{EventID: "e1", TopicID: "task-9", Start: hm(t, loc, "09:00"), End: hm(t, loc, "09:30")}
	expect(t, "a meeting with a topic", Input{Meetings: []Meeting{mt}, IdleMinutes: 10, Loc: loc}, "2026-10-07 30: t:task-9=30")
	mt.TopicID = ""
	expect(t, "control, no topic", Input{Meetings: []Meeting{mt}, IdleMinutes: 10, Loc: loc}, "2026-10-07 30: cal:e1=30")
}

func TestBridgedMinutesGoToThePreviousTarget(t *testing.T) {
	loc := stockholm(t)
	in := append(tabs(t, loc, "09:00", "09:05", "t:a"), tabs(t, loc, "09:12", "09:17", "t:b")...)
	expect(t, "the 6-minute gap goes to t:a",
		Input{Minutes: in, IdleMinutes: 10, Loc: loc}, "2026-10-07 18: t:a=12 t:b=6")
	ctl := append(tabs(t, loc, "09:00", "09:05", "t:b"), tabs(t, loc, "09:12", "09:17", "t:a")...)
	expect(t, "control, swapped targets: the gap follows t:b",
		Input{Minutes: ctl, IdleMinutes: 10, Loc: loc}, "2026-10-07 18: t:b=12 t:a=6")
}

func TestFloorBeforeFold(t *testing.T) {
	loc := stockholm(t)
	build := func(glanceTo string) Input {
		in := tabs(t, loc, "08:00", glanceTo, "t:a")
		in = append(in, post(t, loc, "09:00", "t:b"), post(t, loc, "09:02", "t:b"))
		in = append(in, tabs(t, loc, "10:00", "10:09", "t:c")...)
		return Input{Minutes: in, IdleMinutes: 10, Loc: loc}
	}
	expect(t, "the dropped 2-minute glance is not folded into ws",
		build("08:01"), "2026-10-07 13: t:c=10 ws=3")
	expect(t, "control, a 3-minute glance survives the floor and folds",
		build("08:02"), "2026-10-07 16: t:c=10 ws=6")
}

func TestFoldUnderFive(t *testing.T) {
	loc := stockholm(t)
	in := append(tabs(t, loc, "09:00", "09:04", "t:a"), tabs(t, loc, "09:05", "09:08", "t:b")...)
	in = append(in, tabs(t, loc, "09:09", "09:10", TargetWS)...)
	expect(t, "4 minutes fold into the existing ws row; 5 stay",
		Input{Minutes: in, IdleMinutes: 10, Loc: loc}, "2026-10-07 11: ws=6 t:a=5")
	ctl := append(tabs(t, loc, "09:00", "09:04", "t:a"), tabs(t, loc, "09:05", "09:09", "t:b")...)
	expect(t, "control, 5 minutes do not fold",
		Input{Minutes: ctl, IdleMinutes: 10, Loc: loc}, "2026-10-07 10: t:a=5 t:b=5")
}

func TestMidnightSplit(t *testing.T) {
	loc := stockholm(t)
	var in []Minute
	for m := at(t, loc, "2026-10-07 23:55"); m.Before(at(t, loc, "2026-10-08 00:05")); m = m.Add(time.Minute) {
		in = append(in, Minute{At: m, Target: "t:a", Src: SrcTab})
	}
	expect(t, "23:55..00:05 splits at local midnight",
		Input{Minutes: in, IdleMinutes: 10, Loc: loc}, "2026-10-07 5: t:a=5 | 2026-10-08 5: t:a=5")
	expect(t, "control, in UTC (21:55..22:05) the same block is one day",
		Input{Minutes: in, IdleMinutes: 10, Loc: time.UTC}, "2026-10-07 10: t:a=10")
	// The floor sees the whole block, not its halves: 23:59..00:01 is 3 minutes.
	short := []Minute{
		{At: at(t, loc, "2026-10-07 23:59"), Target: "t:a", Src: SrcTab},
		{At: at(t, loc, "2026-10-08 00:01"), Target: "t:a", Src: SrcTab},
	}
	expect(t, "a 3-minute block over midnight is kept, then split",
		Input{Minutes: short, IdleMinutes: 10, Loc: loc}, "2026-10-07 1: ws=1 | 2026-10-08 2: ws=2")
}

// allDay is one tab minute per real minute from local midnight of date to the
// next local midnight.
func allDay(t *testing.T, loc *time.Location, date string) []Minute {
	t.Helper()
	from := at(t, loc, date+" 00:00")
	to := from.AddDate(0, 0, 1)
	var out []Minute
	for m := from; m.Before(to); m = m.Add(time.Minute) {
		out = append(out, Minute{At: m, Target: "t:a", Src: SrcTab})
	}
	return out
}

func TestDSTDays(t *testing.T) {
	loc := stockholm(t)
	expect(t, "spring forward: a 23 h day",
		Input{Minutes: allDay(t, loc, "2026-03-29"), IdleMinutes: 10, Loc: loc}, "2026-03-29 1380: t:a=1380")
	expect(t, "fall back: a 25 h day",
		Input{Minutes: allDay(t, loc, "2026-10-25"), IdleMinutes: 10, Loc: loc}, "2026-10-25 1500: t:a=1500")
	expect(t, "control, an ordinary day: 24 h",
		Input{Minutes: allDay(t, loc, "2026-10-07"), IdleMinutes: 10, Loc: loc}, "2026-10-07 1440: t:a=1440")
	// 01:00..04:00 on the clock is 2, 4 and 3 real hours.
	clock := func(date string) Input {
		mt := Meeting{EventID: "e1", Start: at(t, loc, date+" 01:00"), End: at(t, loc, date+" 04:00")}
		return Input{Meetings: []Meeting{mt}, IdleMinutes: 10, Loc: loc}
	}
	expect(t, "01:00..04:00 on the 23 h day", clock("2026-03-29"), "2026-03-29 120: cal:e1=120")
	expect(t, "01:00..04:00 on the 25 h day", clock("2026-10-25"), "2026-10-25 240: cal:e1=240")
	expect(t, "control, 01:00..04:00 on an ordinary day", clock("2026-10-07"), "2026-10-07 180: cal:e1=180")
}

func TestSecondsTruncatedAndOrderFree(t *testing.T) {
	loc := stockholm(t)
	in := workedExample(t, loc, true)
	in[0].At = in[0].At.Add(42 * time.Second)
	rev := make([]Minute, len(in))
	for i := range in {
		rev[len(in)-1-i] = in[i]
	}
	a := run(t, Input{Minutes: in, IdleMinutes: 10, Loc: loc})
	b := run(t, Input{Minutes: rev, IdleMinutes: 10, Loc: loc})
	if !reflect.DeepEqual(a, b) {
		t.Errorf("input order changed the result:\n%v\n%v", a, b)
	}
	if got := summary(a); got != "2026-10-07 22: t:a=21 ws=1" {
		t.Errorf("09:00:42 is the 09:00 minute: got %s", got)
	}
}

func TestBadInput(t *testing.T) {
	loc := stockholm(t)
	ok := []Minute{post(t, loc, "09:00", "t:a")}
	if _, err := Suggest(Input{Minutes: ok, IdleMinutes: 10, Loc: loc}); err != nil {
		t.Fatalf("control: %v", err)
	}
	for name, in := range map[string]Input{
		"no zone":     {Minutes: ok, IdleMinutes: 10},
		"negative N":  {Minutes: ok, IdleMinutes: -1, Loc: loc},
		"bad src":     {Minutes: []Minute{{At: hm(t, loc, "09:00"), Target: "t:a", Src: "read"}}, IdleMinutes: 10, Loc: loc},
		"no target":   {Minutes: []Minute{{At: hm(t, loc, "09:00"), Src: SrcTab}}, IdleMinutes: 10, Loc: loc},
		"no event id": {Meetings: []Meeting{{Start: hm(t, loc, "09:00"), End: hm(t, loc, "10:00")}}, IdleMinutes: 10, Loc: loc},
	} {
		if _, err := Suggest(in); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
	expect(t, "an inverted meeting counts nothing",
		Input{Meetings: []Meeting{{EventID: "e1", Start: hm(t, loc, "10:00"), End: hm(t, loc, "09:00")}}, IdleMinutes: 10, Loc: loc}, "")
}
