package taskcron

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func mustParse(t *testing.T, expr string) Schedule {
	t.Helper()
	s, err := Parse(expr)
	if err != nil {
		t.Fatalf("Parse(%q): %v", expr, err)
	}
	return s
}

func utc(y int, mo time.Month, d, h, mi int) time.Time {
	return time.Date(y, mo, d, h, mi, 0, 0, time.UTC)
}

func helsinki(t *testing.T) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation("Europe/Helsinki")
	if err != nil {
		t.Skipf("no tz data for Europe/Helsinki: %v", err)
	}
	return loc
}

// fires answers the first n fire times after from.
func fires(s Schedule, from time.Time, loc *time.Location, n int) []time.Time {
	var out []time.Time
	for t := from; len(out) < n; {
		t = s.Next(t, loc)
		if t.IsZero() {
			break
		}
		out = append(out, t)
	}
	return out
}

func wantFires(t *testing.T, expr string, from time.Time, loc *time.Location, want ...time.Time) {
	t.Helper()
	got := fires(mustParse(t, expr), from, loc, len(want))
	if len(got) != len(want) {
		t.Fatalf("%q: got %d fire times %v, want %v", expr, len(got), got, want)
	}
	for i := range want {
		if !got[i].Equal(want[i]) {
			t.Errorf("%q fire %d: got %s, want %s", expr, i, got[i].UTC(), want[i].UTC())
		}
	}
}

func wantRefused(t *testing.T, expr, reason, field string) {
	t.Helper()
	_, err := Parse(expr)
	var ec ErrCron
	if !errors.As(err, &ec) {
		t.Fatalf("Parse(%q): err %v, want ErrCron %s", expr, err, reason)
	}
	if ec.Reason != reason || ec.Field != field {
		t.Errorf("Parse(%q): got %+v, want {%s %s}", expr, ec, reason, field)
	}
}

// Each field's range: its bounds parse, one past each bound is refused
// "range" naming the field.
func TestFieldRanges(t *testing.T) {
	ok := []string{"0 0 1 1 0", "59 23 31 12 7", "0-59 0-23 1-31 1-12 0-7"}
	for _, e := range ok {
		mustParse(t, e)
	}
	bad := []struct{ expr, field string }{
		{"60 * * * *", "minute"},
		{"* 24 * * *", "hour"},
		{"* * 0 * *", "day_of_month"},
		{"* * 32 * *", "day_of_month"},
		{"* * * 0 *", "month"},
		{"* * * 13 *", "month"},
		{"* * * * 8", "day_of_week"},
		{"5-1 * * * *", "minute"},
		{"*/0 * * * *", "minute"},
		{"0-50/0 * * * *", "minute"},
		{"99999 * * * *", "minute"},
	}
	for _, b := range bad {
		wantRefused(t, b.expr, ReasonRange, b.field)
	}
}

// Lists, ranges and steps, each read back through Next.
func TestListsRangesSteps(t *testing.T) {
	from := utc(2026, 11, 2, 0, 0)
	wantFires(t, "5,10-12,40-50/5 * * * *", from, nil,
		utc(2026, 11, 2, 0, 5), utc(2026, 11, 2, 0, 10), utc(2026, 11, 2, 0, 11),
		utc(2026, 11, 2, 0, 12), utc(2026, 11, 2, 0, 40), utc(2026, 11, 2, 0, 45),
		utc(2026, 11, 2, 0, 50), utc(2026, 11, 2, 1, 5))
	wantFires(t, "*/20 */12 * * *", from, nil,
		utc(2026, 11, 2, 0, 20), utc(2026, 11, 2, 0, 40), utc(2026, 11, 2, 12, 0))
	wantFires(t, "0 9 1,15 2-3 *", from, nil,
		utc(2027, 2, 1, 9, 0), utc(2027, 2, 15, 9, 0), utc(2027, 3, 1, 9, 0), utc(2027, 3, 15, 9, 0))
	wantFires(t, "0 0 * * 1-5/2", from, nil, // Mon, Wed, Fri; 2026-11-02 is a Monday
		utc(2026, 11, 4, 0, 0), utc(2026, 11, 6, 0, 0), utc(2026, 11, 9, 0, 0))
}

// 0 and 7 are both Sunday, alone and at the end of a range.
func TestSundayZeroAndSeven(t *testing.T) {
	from := utc(2026, 11, 4, 0, 0) // a Wednesday
	sun := utc(2026, 11, 8, 12, 0)
	wantFires(t, "0 12 * * 0", from, nil, sun)
	wantFires(t, "0 12 * * 7", from, nil, sun)
	wantFires(t, "0 12 * * 6-7", from, nil, utc(2026, 11, 7, 12, 0), sun)
}

// The either-day rule: both restricted, a day matching either fires; one
// `*`, only the other counts. Red control: with AND instead of OR, the
// first fire of `0 0 13 * 5` is Friday the 13th, not Friday the 6th.
func TestEitherDayRule(t *testing.T) {
	from := utc(2026, 11, 1, 0, 0) // a Sunday
	wantFires(t, "0 0 13 * 5", from, nil,
		utc(2026, 11, 6, 0, 0), utc(2026, 11, 13, 0, 0), utc(2026, 11, 20, 0, 0),
		utc(2026, 11, 27, 0, 0), utc(2026, 12, 4, 0, 0), utc(2026, 12, 11, 0, 0),
		utc(2026, 12, 13, 0, 0)) // the 13th, a Sunday
	wantFires(t, "0 0 13 * *", from, nil, utc(2026, 11, 13, 0, 0), utc(2026, 12, 13, 0, 0))
	wantFires(t, "0 0 * * 5", from, nil, utc(2026, 11, 6, 0, 0), utc(2026, 11, 13, 0, 0))
}

// `*/30 8-18 * * 1-5` in Europe/Helsinki across both DST changes: the
// local times hold, the UTC instants move by the hour.
func TestHelsinkiWorkdaysAcrossDST(t *testing.T) {
	loc := helsinki(t)
	const expr = "*/30 8-18 * * 1-5"
	// Spring: Sunday 2027-03-28 03:00 EET -> 04:00 EEST.
	wantFires(t, expr, time.Date(2027, 3, 26, 18, 0, 0, 0, loc), loc,
		utc(2027, 3, 26, 16, 30), // Fri 18:30 EET (+2)
		utc(2027, 3, 29, 5, 0),   // Mon 08:00 EEST (+3)
		utc(2027, 3, 29, 5, 30))
	// Autumn: Sunday 2026-10-25 04:00 EEST -> 03:00 EET.
	wantFires(t, expr, time.Date(2026, 10, 23, 18, 0, 0, 0, loc), loc,
		utc(2026, 10, 23, 15, 30), // Fri 18:30 EEST (+3)
		utc(2026, 10, 26, 6, 0),   // Mon 08:00 EET (+2)
		utc(2026, 10, 26, 6, 30))
	// One working week: 22 fire times a day, none at the weekend.
	got := fires(mustParse(t, expr), time.Date(2027, 3, 22, 0, 0, 0, 0, loc), loc, 111)
	if n := len(got); n != 111 || got[109].In(loc).Weekday() != time.Friday || got[110].In(loc).Weekday() != time.Monday {
		t.Fatalf("week walk: %d fires, 110th %s, 111th %s", n, got[109].In(loc), got[110].In(loc))
	}
}

// A local minute the clock skips fires at the end of the gap, once; a
// local minute the clock shows twice fires once, at its first occurrence.
func TestDSTGapAndRepeat(t *testing.T) {
	loc := helsinki(t)
	// 03:30 does not exist on 2027-03-28: it fires at 04:00 EEST = 01:00Z.
	wantFires(t, "30 3 * * *", utc(2027, 3, 27, 12, 0), loc,
		utc(2027, 3, 28, 1, 0), utc(2027, 3, 29, 0, 30))
	// 03:00 and 03:30 both fall in the gap: one fire, not two.
	wantFires(t, "*/30 3 * * *", utc(2027, 3, 27, 12, 0), loc,
		utc(2027, 3, 28, 1, 0), utc(2027, 3, 29, 0, 0))
	// 03:30 occurs twice on 2026-10-25 (00:30Z EEST, 01:30Z EET): once.
	wantFires(t, "30 3 * * *", utc(2026, 10, 24, 12, 0), loc,
		utc(2026, 10, 25, 0, 30), utc(2026, 10, 26, 1, 30))
	// Asked from inside the repeated hour, the second 03:30 does not fire.
	wantFires(t, "30 3 * * *", utc(2026, 10, 25, 1, 10), loc, utc(2026, 10, 26, 1, 30))
}

// MinGap: `*/5 * * * *` is 5 minutes, `0 0 30 2 *` has none.
func TestMinGap(t *testing.T) {
	loc := helsinki(t)
	from := utc(2026, 11, 26, 7, 3)
	year := 366 * 24 * time.Hour
	cases := []struct {
		expr string
		gap  time.Duration
		ok   bool
	}{
		{"*/5 * * * *", 5 * time.Minute, true},
		{"*/15 * * * *", 15 * time.Minute, true},
		{"0,10 * * * *", 10 * time.Minute, true},
		{"* * * * *", time.Minute, true},
		{"0 0 30 2 *", 0, false},
		{"0 0 31 4,6,9,11 *", 0, false},
	}
	for _, c := range cases {
		gap, ok := mustParse(t, c.expr).MinGap(from, loc, year)
		if gap != c.gap || ok != c.ok {
			t.Errorf("MinGap(%q) = %s, %v; want %s, %v", c.expr, gap, ok, c.gap, c.ok)
		}
	}
	// One fire time inside the horizon answers the horizon.
	if gap, ok := mustParse(t, "0 12 26 11 *").MinGap(from, nil, 24*time.Hour); !ok || gap != 24*time.Hour {
		t.Errorf("single fire: got %s, %v", gap, ok)
	}
	if !mustParse(t, "0 0 30 2 *").Next(from, nil).IsZero() {
		t.Error("0 0 30 2 *: Next is not the zero time")
	}
}

// 29 February is found across the century year 2100, which has none.
func TestLeapDay(t *testing.T) {
	wantFires(t, "0 0 29 2 *", utc(2097, 1, 1, 0, 0), nil, utc(2104, 2, 29, 0, 0))
}

// MON and @hourly are syntax, 6 or 4 fields are fields.
func TestRefusals(t *testing.T) {
	syntax := []string{
		"0 0 * * MON", "@hourly", "0 0 * JAN *", "0 0 L * *", "0 0 * * 1#2",
		"0 0 ? * *", "1/5 * * * *", "1- * * * *", "1,,2 * * * *",
		"0  0 * * *", " 0 0 * * *", "0 0 * * * ", "-1 * * * *",
		strings.Repeat("1,", 32) + "1 * * * *",
	}
	for _, e := range syntax {
		wantRefused(t, e, ReasonSyntax, fieldFor(e))
	}
	for _, e := range []string{"0 0 * * * *", "0 0 * *", "", "   "} {
		wantRefused(t, e, ReasonFields, "")
	}
	mustParse(t, "0\t0\t*\t*\t*")
	if got := (ErrCron{Reason: ReasonRange, Field: "hour"}).Error(); got != "cron: range in hour" {
		t.Errorf("Error() = %q", got)
	}
	if got := (ErrCron{Reason: ReasonFields}).Error(); got != "cron: fields" {
		t.Errorf("Error() = %q", got)
	}
}

// fieldFor names the field a syntax refusal points at: a malformed item
// inside a well-formed 5-field string names its field, a bad character or
// separator names none.
func fieldFor(expr string) string {
	switch expr {
	case "1/5 * * * *", "1- * * * *", "1,,2 * * * *", "-1 * * * *":
		return "minute"
	}
	return ""
}
