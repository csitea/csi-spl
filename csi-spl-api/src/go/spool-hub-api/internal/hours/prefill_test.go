// SPDX-License-Identifier: AGPL-3.0-only

package hours

// Tests of the v2 prefill chain (spec 107 FR-15, FR-16, FR-17, FR-24,
// FR-26, FR-27; T023). Red on the base tree: this file does not compile
// (Prefill undefined).

import (
	"fmt"
	"strings"
	"testing"
)

const pday = "2026-10-20" // a Tuesday

// pin is the default input: one day, a 480 standard day, the Standard Day
// on, the 098 defaults.
func pin(t *testing.T) PrefillInput {
	t.Helper()
	return PrefillInput{
		Days:              []string{pday},
		Loc:               helsinki(t),
		StandardDay:       map[string]int{pday: DefaultStandardDayMinutes},
		StandardDayOn:     true,
		DayStartMinutes:   DefaultDayStartMinutes,
		BreakAfterMinutes: DefaultBreakAfterMinutes,
		BreakMinutes:      DefaultBreakMinutes,
	}
}

func plan(t *testing.T, in PrefillInput, target, from, to string, explicit bool) PlanRow {
	t.Helper()
	return PlanRow{Target: target, Start: at(t, in.Loc, from), End: at(t, in.Loc, to), Explicit: explicit}
}

func act(date string, rows ...Row) Day {
	d := Day{Date: date, Rows: rows}
	for _, r := range rows {
		d.Minutes += r.Minutes
	}
	return d
}

// rowLine is "target kind source minutes [flags]": E evidence, N no
// activity, P proposed; an absence row adds its type.
func rowLine(r PrefillRow) string {
	s := fmt.Sprintf("%s %s %s %d", r.Target, r.Kind, r.Source, r.Minutes)
	if r.AbsenceType != "" {
		s += " " + r.AbsenceType
	}
	flags := ""
	if r.Evidence {
		flags += "E"
	}
	if r.NoActivity {
		flags += "N"
	}
	if r.Proposed {
		flags += "P"
	}
	if flags != "" {
		s += " " + flags
	}
	return s
}

func dayLine(d PrefillDay) string {
	parts := make([]string, 0, len(d.Rows))
	for _, r := range d.Rows {
		parts = append(parts, rowLine(r))
	}
	return fmt.Sprintf("%s %d: %s", d.Date, d.Minutes, strings.Join(parts, "; "))
}

func prefill(t *testing.T, in PrefillInput) []PrefillDay {
	t.Helper()
	days, err := Prefill(in)
	if err != nil {
		t.Fatal(err)
	}
	return days
}

func expectDays(t *testing.T, in PrefillInput, want ...string) []PrefillDay {
	t.Helper()
	days := prefill(t, in)
	got := make([]string, 0, len(days))
	for _, d := range days {
		got = append(got, dayLine(d))
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	return days
}

func clockTimes(t *testing.T, in PrefillInput, date, from, to string) Clock {
	t.Helper()
	c := Clock{Date: date}
	if from != "" {
		c.In = at(t, in.Loc, date+" "+from)
	}
	if to != "" {
		c.Out = at(t, in.Loc, date+" "+to)
	}
	return c
}

func hhmm(d PrefillDay) string {
	if d.Start.IsZero() {
		return "-"
	}
	return fmt.Sprintf("%s..%s %s/%s break %d", d.Start.Format("15:04"), d.End.Format("15:04"), d.StartSource, d.EndSource, d.BreakMinutes)
}

// TestPrefillChainSteps: one case per FR-17 step, first match wins.
func TestPrefillChainSteps(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, in *PrefillInput)
		want  string
	}{
		{"1 whole-day absence beats the plan and the Standard Day", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{plan(t, *in, "job:a", pday+" 08:00", pday+" 16:30", true)}
			in.Absences = []Absence{{Date: pday, Type: "sick"}}
		}, pday + " 480: ws absence absence 480 sick E"},
		{"1 part-day absence, the Standard Day fills the rest", func(t *testing.T, in *PrefillInput) {
			in.Absences = []Absence{{Date: pday, Type: "vacation", Minutes: 180}}
		}, pday + " 480: job:last work standard 300 N; ws absence absence 180 vacation E"},
		{"1 holiday beats an inherited plan row", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{plan(t, *in, "job:a", pday+" 08:00", pday+" 16:30", false)}
			in.Holidays = []Holiday{{Date: pday, Name: "Founders"}}
		}, pday + " 480: ws absence holiday 480 holiday E"},
		{"1 an explicit plan row beats a holiday", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{plan(t, *in, "job:a", pday+" 08:00", pday+" 16:30", true)}
			in.Holidays = []Holiday{{Date: pday, Name: "Founders"}}
		}, pday + " 480: job:a work plan 480 E"},
		{"1 part-day holiday, the plan fills the rest", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{plan(t, *in, "job:a", pday+" 08:00", pday+" 16:30", false)}
			in.Holidays = []Holiday{{Date: pday, Name: "Eve", Minutes: 240}}
		}, pday + " 480: job:a work plan 240 E; ws absence holiday 240 holiday E"},
		{"1 whole-day absence on a non-working day adds nothing", func(t *testing.T, in *PrefillInput) {
			in.StandardDay = map[string]int{}
			in.Absences = []Absence{{Date: pday, Type: "sick"}}
		}, pday + " 0: "},
		{"2 foreman rows beat the plan, proposed", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{plan(t, *in, "job:a", pday+" 08:00", pday+" 16:30", true)}
			in.Foreman = []ForemanRow{{Date: pday, Target: "job:b", Minutes: 300}, {Date: pday, Target: "job:b", Kind: KindTravel, Minutes: 45}}
		}, pday + " 345: job:b work foreman 300 EP; job:b travel foreman 45 EP"},
		{"3 the plan: net of the break", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{plan(t, *in, "job:a", pday+" 08:00", pday+" 16:30", false)}
		}, pday + " 480: job:a work plan 480 E"},
		{"4 the Standard Day", func(t *testing.T, in *PrefillInput) {}, pday + " 480: job:last work standard 480 N"},
		{"5 a clock in and out only, Standard Day off", func(t *testing.T, in *PrefillInput) {
			in.StandardDayOn = false
			in.Clocks = []Clock{clockTimes(t, *in, pday, "07:00", "15:00")}
			in.Activity = []Day{act(pday, Row{Target: "t:x", Minutes: 50})}
		}, pday + " 450: job:last work clock 450 E"},
		{"6 activity only, Standard Day off", func(t *testing.T, in *PrefillInput) {
			in.StandardDayOn = false
			in.Activity = []Day{act(pday, Row{Target: "t:x", Minutes: 50}, Row{Target: "t:y", Minutes: 20})}
		}, pday + " 70: t:x work activity 50 E; t:y work activity 20 E"},
		{"6 activity on a non-working day, Standard Day on", func(t *testing.T, in *PrefillInput) {
			in.StandardDay = map[string]int{}
			in.Activity = []Day{act(pday, Row{Target: "t:x", Minutes: 50})}
		}, pday + " 50: t:x work activity 50 E"},
		{"6 nothing at all", func(t *testing.T, in *PrefillInput) {
			in.StandardDayOn = false
		}, pday + " 0: "},
	} {
		t.Run(tc.name, func(t *testing.T) {
			in := pin(t)
			in.DefaultTarget = "job:last"
			tc.setup(t, &in)
			expectDays(t, in, tc.want)
		})
	}
}

// TestPrefillStandardDay: the FR-15 cases.
func TestPrefillStandardDay(t *testing.T) {
	for _, tc := range []struct {
		name string
		std  int
		act  []Row
		want string
	}{
		{"3 h on two topics scale 2:1 to 480", 480, []Row{{Target: "t:a", Minutes: 120}, {Target: "t:b", Minutes: 60}},
			pday + " 480: t:a work standard 320 E; t:b work standard 160 E"},
		{"600 of activity is kept, never cut", 480, []Row{{Target: "t:a", Minutes: 400}, {Target: "t:b", Minutes: 200}},
			pday + " 600: t:a work activity 400 E; t:b work activity 200 E"},
		{"no activity: one open row without evidence", 480, nil,
			pday + " 480: ws work standard 480 N"},
		{"largest remainder to whole minutes", 100, []Row{{Target: "t:a", Minutes: 1}, {Target: "t:b", Minutes: 1}, {Target: "t:c", Minutes: 1}},
			pday + " 100: t:a work standard 34 E; t:b work standard 33 E; t:c work standard 33 E"},
		{"a 7.5 h standard day", 450, []Row{{Target: "t:a", Minutes: 100}, {Target: "t:b", Minutes: 50}},
			pday + " 450: t:a work standard 300 E; t:b work standard 150 E"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			in := pin(t)
			in.StandardDay[pday] = tc.std
			if tc.act != nil {
				in.Activity = []Day{act(pday, tc.act...)}
			}
			expectDays(t, in, tc.want)
		})
	}
	// Q19: the start and end of a Standard Day are day start + minutes + break.
	in := pin(t)
	days := prefill(t, in)
	if got, want := hhmm(days[0]), "08:00..16:30 standard/standard break 30"; got != want {
		t.Fatalf("frame %q, want %q", got, want)
	}
}

// TestPrefillBreak: the FR-26 cases.
func TestPrefillBreak(t *testing.T) {
	for _, tc := range []struct {
		name  string
		std   int
		from  string
		to    string
		brk   bool
		want  string
		frame string
	}{
		{"a span of exactly the threshold keeps every minute", 480, "08:00", "14:00", false, pday + " 360: job:a work plan 360 E", "08:00..14:00 plan/plan break 0"},
		{"a minute over the threshold loses the break", 480, "08:00", "14:01", false, pday + " 331: job:a work plan 331 E", "08:00..14:01 plan/plan break 30"},
		{"No break", 480, "08:00", "16:30", true, pday + " 510: job:a work plan 510 E", "08:00..16:30 plan/plan break 0"},
		{"never on a half day from the prefill", 240, "08:00", "15:00", false, pday + " 420: job:a work plan 420 E", "08:00..15:00 plan/plan break 0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			in := pin(t)
			in.StandardDay[pday] = tc.std
			in.Plan = []PlanRow{plan(t, in, "job:a", pday+" "+tc.from, pday+" "+tc.to, true)}
			if tc.brk {
				in.NoBreak = map[string]bool{pday: true}
			}
			days := expectDays(t, in, tc.want)
			if got := hhmm(days[0]); got != tc.frame {
				t.Fatalf("frame %q, want %q", got, tc.frame)
			}
		})
	}
	t.Run("deducted once, from the longest row; travel between two plan rows", func(t *testing.T) {
		in := pin(t)
		in.Plan = []PlanRow{
			plan(t, in, "job:a", pday+" 07:00", pday+" 11:00", true),
			plan(t, in, "job:b", pday+" 11:30", pday+" 16:00", true),
		}
		days := expectDays(t, in, pday+" 510: job:a work plan 240 E; job:b work plan 240 E; job:b travel plan 30 E")
		if got, want := hhmm(days[0]), "07:00..16:00 plan/plan break 30"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
	t.Run("two back-to-back plan rows have no travel row", func(t *testing.T) {
		in := pin(t)
		in.Plan = []PlanRow{
			plan(t, in, "job:a", pday+" 08:00", pday+" 12:00", true),
			plan(t, in, "job:b", pday+" 12:00", pday+" 14:00", true),
		}
		expectDays(t, in, pday+" 360: job:a work plan 240 E; job:b work plan 120 E")
	})
	t.Run("a clock-only day loses the break", func(t *testing.T) {
		in := pin(t)
		in.StandardDayOn = false
		in.Clocks = []Clock{clockTimes(t, in, pday, "06:00", "16:00")}
		expectDays(t, in, pday+" 570: ws work clock 570 E")
	})
}

// TestPrefillClock: the FR-24 cases.
func TestPrefillClock(t *testing.T) {
	t.Run("clock in replaces the planned start", func(t *testing.T) {
		in := pin(t)
		in.Plan = []PlanRow{plan(t, in, "job:a", pday+" 08:00", pday+" 16:30", true)}
		in.Clocks = []Clock{clockTimes(t, in, pday, "09:00", "")}
		in.Clocks[0].Out = at(t, in.Loc, pday+" 16:30")
		days := expectDays(t, in, pday+" 420: job:a work plan 420 E")
		if got, want := hhmm(days[0]), "09:00..16:30 clock/clock break 30"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
	t.Run("two plan rows: in moves the first start, out the last end", func(t *testing.T) {
		in := pin(t)
		in.Plan = []PlanRow{
			plan(t, in, "job:a", pday+" 07:00", pday+" 11:00", true),
			plan(t, in, "job:b", pday+" 11:30", pday+" 16:00", true),
		}
		in.Clocks = []Clock{clockTimes(t, in, pday, "07:30", "18:00")}
		days := expectDays(t, in, pday+" 600: job:b work plan 360 E; job:a work plan 210 E; job:b travel plan 30 E")
		if got, want := hhmm(days[0]), "07:30..18:00 clock/clock break 30"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
	t.Run("the Standard Day with a clock in and out", func(t *testing.T) {
		in := pin(t)
		in.Activity = []Day{act(pday, Row{Target: "t:a", Minutes: 120}, Row{Target: "t:b", Minutes: 60})}
		in.Clocks = []Clock{clockTimes(t, in, pday, "09:00", "13:00")}
		days := expectDays(t, in, pday+" 240: t:a work standard 160 E; t:b work standard 80 E")
		if got, want := hhmm(days[0]), "09:00..13:00 clock/clock break 0"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
	t.Run("a clock time is evidence for a no-activity day", func(t *testing.T) {
		in := pin(t)
		in.Clocks = []Clock{clockTimes(t, in, pday, "07:00", "17:00")}
		expectDays(t, in, pday+" 570: ws work standard 570 EN")
	})
	t.Run("a foreman row with a clock out", func(t *testing.T) {
		in := pin(t)
		in.Foreman = []ForemanRow{{Date: pday, Target: "job:b", Minutes: 300}}
		in.Clocks = []Clock{clockTimes(t, in, pday, "", "18:00")}
		days := expectDays(t, in, pday+" 570: job:b work foreman 570 EP")
		if got, want := hhmm(days[0]), "08:00..18:00 foreman/clock break 30"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
}

// TestPrefillForgottenClockOut: the day ends at the planned end, else start
// + standard day + break, and goes to the foreman (FR-24).
func TestPrefillForgottenClockOut(t *testing.T) {
	t.Run("at the planned end", func(t *testing.T) {
		in := pin(t)
		in.Plan = []PlanRow{plan(t, in, "job:a", pday+" 08:00", pday+" 16:30", true)}
		in.Clocks = []Clock{clockTimes(t, in, pday, "08:30", "")}
		days := expectDays(t, in, pday+" 450: job:a work plan 450 EP")
		if !days[0].ForgottenClockOut {
			t.Fatal("not marked for the foreman")
		}
		if got, want := hhmm(days[0]), "08:30..16:30 clock/plan break 30"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
	t.Run("no plan: start + standard day + break", func(t *testing.T) {
		in := pin(t)
		in.StandardDayOn = false
		in.Clocks = []Clock{clockTimes(t, in, pday, "07:00", "")}
		days := expectDays(t, in, pday+" 480: ws work clock 480 EP")
		if !days[0].ForgottenClockOut {
			t.Fatal("not marked for the foreman")
		}
		if got, want := hhmm(days[0]), "07:00..15:30 clock/standard break 30"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
	t.Run("the Standard Day: start + standard day + break", func(t *testing.T) {
		in := pin(t)
		in.Clocks = []Clock{clockTimes(t, in, pday, "07:00", "")}
		days := expectDays(t, in, pday+" 480: ws work standard 480 ENP")
		if got, want := hhmm(days[0]), "07:00..15:30 clock/standard break 30"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
	t.Run("a clock in and out is not forgotten", func(t *testing.T) {
		in := pin(t)
		in.Clocks = []Clock{clockTimes(t, in, pday, "07:00", "15:30")}
		if prefill(t, in)[0].ForgottenClockOut {
			t.Fatal("marked")
		}
	})
}

// TestPrefillNightShift: a 22:00-06:00 shift splits at the member's local
// midnight into two days' rows (FR-16), the break once from the longer part.
func TestPrefillNightShift(t *testing.T) {
	in := pin(t)
	next := "2026-10-21"
	in.Days = []string{next, pday}
	in.StandardDay[next] = 480
	in.Plan = []PlanRow{plan(t, in, "job:n", pday+" 22:00", next+" 06:00", true)}
	days := expectDays(t, in,
		pday+" 120: job:n work plan 120 E",
		next+" 330: job:n work plan 330 E")
	if got, want := hhmm(days[0]), "22:00..00:00 plan/plan break 0"; got != want {
		t.Fatalf("first day frame %q, want %q", got, want)
	}
	if got, want := hhmm(days[1]), "00:00..06:00 plan/plan break 30"; got != want {
		t.Fatalf("second day frame %q, want %q", got, want)
	}
}

// TestPrefillDSTDays: the same shift over the 23 h and the 25 h night
// (Europe/Helsinki: 2026-03-29 and 2026-10-25) holds 7 and 9 wall hours.
func TestPrefillDSTDays(t *testing.T) {
	for _, tc := range []struct {
		name, day, next string
		want            []string
	}{
		{"23 h day", "2026-03-28", "2026-03-29", []string{"2026-03-28 120: job:n work plan 120 E", "2026-03-29 270: job:n work plan 270 E"}},
		{"25 h day", "2026-10-24", "2026-10-25", []string{"2026-10-24 120: job:n work plan 120 E", "2026-10-25 390: job:n work plan 390 E"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			in := pin(t)
			in.Days = []string{tc.day, tc.next}
			in.StandardDay = map[string]int{tc.day: 480, tc.next: 480}
			in.Plan = []PlanRow{plan(t, in, "job:n", tc.day+" 22:00", tc.next+" 06:00", true)}
			expectDays(t, in, tc.want...)
		})
	}
	t.Run("a Standard Day on the 25 h day stays the standard day", func(t *testing.T) {
		in := pin(t)
		in.Days = []string{"2026-10-25"}
		in.StandardDay = map[string]int{"2026-10-25": 480}
		days := expectDays(t, in, "2026-10-25 480: ws work standard 480 N")
		if got, want := hhmm(days[0]), "08:00..16:30 standard/standard break 30"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
}

func TestPrefillBadInput(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, in *PrefillInput)
	}{
		{"no zone", func(t *testing.T, in *PrefillInput) { in.Loc = nil }},
		{"bad date", func(t *testing.T, in *PrefillInput) { in.Days = []string{"20.10.2026"} }},
		{"plan row ends before it starts", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{plan(t, *in, "job:a", pday+" 16:00", pday+" 08:00", true)}
		}},
		{"three plan rows", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{
				plan(t, *in, "job:a", pday+" 06:00", pday+" 08:00", true),
				plan(t, *in, "job:b", pday+" 09:00", pday+" 10:00", true),
				plan(t, *in, "job:c", pday+" 11:00", pday+" 12:00", true),
			}
		}},
		{"overlapping plan rows", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{
				plan(t, *in, "job:a", pday+" 08:00", pday+" 12:00", true),
				plan(t, *in, "job:b", pday+" 11:00", pday+" 14:00", true),
			}
		}},
		{"clock out before clock in", func(t *testing.T, in *PrefillInput) {
			in.Clocks = []Clock{clockTimes(t, *in, pday, "15:00", "07:00")}
		}},
		{"absence without a type", func(t *testing.T, in *PrefillInput) { in.Absences = []Absence{{Date: pday}} }},
		{"standard day over 1440", func(t *testing.T, in *PrefillInput) { in.StandardDay[pday] = 1441 }},
		{"foreman row kind", func(t *testing.T, in *PrefillInput) {
			in.Foreman = []ForemanRow{{Date: pday, Target: "job:a", Kind: "lunch", Minutes: 30}}
		}},
		{"day start past midnight", func(t *testing.T, in *PrefillInput) { in.DayStartMinutes = 1440 }},
		{"negative break", func(t *testing.T, in *PrefillInput) { in.BreakMinutes = -1 }},
		{"absence date", func(t *testing.T, in *PrefillInput) { in.Absences = []Absence{{Date: "x", Type: "sick"}} }},
		{"absence minutes", func(t *testing.T, in *PrefillInput) {
			in.Absences = []Absence{{Date: pday, Type: "sick", Minutes: -5}}
		}},
		{"holiday date", func(t *testing.T, in *PrefillInput) { in.Holidays = []Holiday{{Date: "x"}} }},
		{"holiday minutes", func(t *testing.T, in *PrefillInput) { in.Holidays = []Holiday{{Date: pday, Minutes: 1441}} }},
		{"foreman date", func(t *testing.T, in *PrefillInput) {
			in.Foreman = []ForemanRow{{Date: "x", Target: "job:a", Minutes: 30}}
		}},
		{"foreman row without a target", func(t *testing.T, in *PrefillInput) {
			in.Foreman = []ForemanRow{{Date: pday, Minutes: 30}}
		}},
		{"foreman minutes", func(t *testing.T, in *PrefillInput) {
			in.Foreman = []ForemanRow{{Date: pday, Target: "job:a", Minutes: 2000}}
		}},
		{"clock date", func(t *testing.T, in *PrefillInput) { in.Clocks = []Clock{{Date: "x"}} }},
		{"two clock rows on a day", func(t *testing.T, in *PrefillInput) {
			in.Clocks = []Clock{clockTimes(t, *in, pday, "07:00", ""), clockTimes(t, *in, pday, "", "15:00")}
		}},
		{"activity date", func(t *testing.T, in *PrefillInput) { in.Activity = []Day{{Date: "x"}} }},
		{"plan row without a target", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{plan(t, *in, "", pday+" 08:00", pday+" 16:00", true)}
		}},
		{"plan row over 24 h", func(t *testing.T, in *PrefillInput) {
			in.Plan = []PlanRow{plan(t, *in, "job:a", pday+" 08:00", "2026-10-21 09:00", true)}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			in := pin(t)
			tc.setup(t, &in)
			if _, err := Prefill(in); err == nil {
				t.Fatal("no error")
			}
		})
	}
}

// TestPrefillEdges: the corners of the chain.
func TestPrefillEdges(t *testing.T) {
	t.Run("part-day absences that fill the day leave no rest", func(t *testing.T) {
		in := pin(t)
		in.Plan = []PlanRow{plan(t, in, "job:a", pday+" 08:00", pday+" 16:30", true)}
		in.Absences = []Absence{{Date: pday, Type: "sick", Minutes: 240}, {Date: pday, Type: "training", Minutes: 240}}
		expectDays(t, in, pday+" 480: ws absence absence 240 sick E; ws absence absence 240 training E")
	})
	t.Run("a clock in after the planned end leaves the row empty, marked", func(t *testing.T) {
		in := pin(t)
		in.Plan = []PlanRow{plan(t, in, "job:a", pday+" 08:00", pday+" 12:00", true)}
		in.Clocks = []Clock{clockTimes(t, in, pday, "13:00", "")}
		days := expectDays(t, in, pday+" 0: ")
		if !days[0].ForgottenClockOut {
			t.Fatal("not marked for the foreman")
		}
	})
	t.Run("a forgotten clock out on a non-working day keeps the foreman's minutes", func(t *testing.T) {
		in := pin(t)
		in.StandardDay = map[string]int{}
		in.Foreman = []ForemanRow{{Date: pday, Target: "job:b", Minutes: 240}}
		in.Clocks = []Clock{clockTimes(t, in, pday, "10:00", "")}
		days := expectDays(t, in, pday+" 240: job:b work foreman 240 EP")
		if got, want := hhmm(days[0]), "10:00..14:00 clock/foreman break 0"; got != want {
			t.Fatalf("frame %q, want %q", got, want)
		}
	})
	t.Run("yesterday's tail and today's shift of one job merge into one row", func(t *testing.T) {
		in := pin(t)
		prev := "2026-10-19"
		in.StandardDay[prev] = 480
		in.Plan = []PlanRow{
			plan(t, in, "job:n", prev+" 22:00", pday+" 02:00", true),
			plan(t, in, "job:n", pday+" 20:00", pday+" 23:00", true),
		}
		expectDays(t, in, pday+" 300: job:n work plan 300 E")
	})
	t.Run("a zero foreman row is dropped; equal rows sort by target, then kind", func(t *testing.T) {
		in := pin(t)
		in.Foreman = []ForemanRow{
			{Date: pday, Target: "job:b", Kind: KindWait, Minutes: 30},
			{Date: pday, Target: "job:b", Minutes: 30},
			{Date: pday, Target: "job:a", Kind: KindTravel, Minutes: 30},
			{Date: pday, Target: "job:c", Minutes: 0},
		}
		expectDays(t, in, pday+" 90: job:a travel foreman 30 EP; job:b wait foreman 30 EP; job:b work foreman 30 EP")
	})
}
