// Package taskcron parses the 5-field cron expression of a scheduled task
// (spec 187 section 4.2.1) and walks its fire times in a time zone.
//
// Grammar: exactly 5 fields separated by single spaces or tabs, in the POSIX
// crontab order minute 0-59, hour 0-23, day of month 1-31, month 1-12, day
// of week 0-7 (0 and 7 are Sunday). Each field is `*`, a number, a range
// `a-b`, a step `*/n` or `a-b/n`, or a comma list of these. No names, no
// macros, no seconds or year field; at most 64 characters.
package taskcron

import (
	"strconv"
	"strings"
	"time"
)

// MaxLen is the longest expression Parse accepts.
const MaxLen = 64

// The refusal reasons of ErrCron (spec 4.2.1). "floor" and "never" are the
// store's save-time checks, built on MinGap; this package does not answer them.
const (
	ReasonFields = "fields"
	ReasonRange  = "range"
	ReasonSyntax = "syntax"
)

// ErrCron names the refused part: Reason is "fields", "range" or "syntax";
// Field is the field's name ("minute", "hour", "day_of_month", "month",
// "day_of_week"), or "" when the whole expression is refused.
type ErrCron struct{ Reason, Field string }

// Error reads "cron: <reason>" or "cron: <reason> in <field>".
func (e ErrCron) Error() string {
	if e.Field == "" {
		return "cron: " + e.Reason
	}
	return "cron: " + e.Reason + " in " + e.Field
}

// The field indexes of Schedule.bits, in the crontab order.
const (
	fMinute = iota
	fHour
	fDom
	fMonth
	fDow
)

var fieldDefs = [5]struct {
	name   string
	lo, hi int
}{
	{"minute", 0, 59},
	{"hour", 0, 23},
	{"day_of_month", 1, 31},
	{"month", 1, 12},
	{"day_of_week", 0, 7},
}

// Schedule is a parsed 5-field expression: one bit set per field (day of
// week 7 folded onto 0), and whether day of month and day of week are
// written `*` (the either-day rule reads them).
type Schedule struct {
	bits    [5]uint64
	domStar bool
	dowStar bool
}

// Parse reads expr. A refusal is an ErrCron: "syntax" for a character
// outside the grammar (names such as MON, macros such as @hourly), an empty
// field between two separators, a malformed item or a string over MaxLen;
// "fields" for a count other than 5; "range" for a value outside its
// field, a reversed range or a step of 0.
func Parse(expr string) (Schedule, error) {
	if len(expr) > MaxLen {
		return Schedule{}, ErrCron{Reason: ReasonSyntax}
	}
	if strings.TrimSpace(expr) == "" {
		return Schedule{}, ErrCron{Reason: ReasonFields}
	}
	toks := strings.FieldsFunc(expr, isSep)
	if len(toks) != strings.Count(expr, " ")+strings.Count(expr, "\t")+1 {
		return Schedule{}, ErrCron{Reason: ReasonSyntax}
	}
	for _, t := range toks {
		if strings.Trim(t, "0123456789*,-/") != "" {
			return Schedule{}, ErrCron{Reason: ReasonSyntax}
		}
	}
	if len(toks) != 5 {
		return Schedule{}, ErrCron{Reason: ReasonFields}
	}
	var s Schedule
	for i, t := range toks {
		d := fieldDefs[i]
		bits, reason := parseField(t, d.lo, d.hi)
		if reason != "" {
			return Schedule{}, ErrCron{Reason: reason, Field: d.name}
		}
		s.bits[i] = bits
	}
	if s.bits[fDow]&(1<<7) != 0 {
		s.bits[fDow] = s.bits[fDow]&^(1<<7) | 1
	}
	s.domStar = toks[fDom] == "*"
	s.dowStar = toks[fDow] == "*"
	return s, nil
}

func isSep(r rune) bool { return r == ' ' || r == '\t' }

// parseField reads one field's comma list into a bit set; reason is ""
// when it parses.
func parseField(text string, lo, hi int) (uint64, string) {
	var bits uint64
	for _, item := range strings.Split(text, ",") {
		a, b, step, reason := parseItem(item, lo, hi)
		if reason != "" {
			return 0, reason
		}
		for v := a; v <= b; v += step {
			bits |= 1 << uint(v)
		}
	}
	return bits, ""
}

// parseItem reads `*`, `n`, `a-b`, `*/n` or `a-b/n`.
func parseItem(item string, lo, hi int) (a, b, step int, reason string) {
	base, stepText, hasStep := strings.Cut(item, "/")
	step = 1
	if hasStep {
		if step, reason = number(stepText); reason != "" {
			return 0, 0, 0, reason
		}
		if step < 1 {
			return 0, 0, 0, ReasonRange
		}
	}
	switch {
	case base == "*":
		a, b = lo, hi
	case strings.Contains(base, "-"):
		as, bs, _ := strings.Cut(base, "-")
		if a, reason = number(as); reason != "" {
			return 0, 0, 0, reason
		}
		if b, reason = number(bs); reason != "" {
			return 0, 0, 0, reason
		}
	case hasStep:
		return 0, 0, 0, ReasonSyntax
	default:
		if a, reason = number(base); reason != "" {
			return 0, 0, 0, reason
		}
		b = a
	}
	if a < lo || b > hi || a > b {
		return 0, 0, 0, ReasonRange
	}
	return a, b, step, ""
}

// number reads a non-empty run of digits; more than 4 digits is out of
// every field's range.
func number(s string) (int, string) {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, ReasonSyntax
	}
	if len(s) > 4 {
		return 0, ReasonRange
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, ReasonSyntax
	}
	return n, ""
}

func (s Schedule) has(f, v int) bool { return s.bits[f]&(1<<uint(v)) != 0 }

// dayMatches applies the month and the either-day rule to a civil date:
// when both day of month and day of week are restricted, either one
// matching is enough; when one is `*`, only the other counts.
func (s Schedule) dayMatches(day time.Time) bool {
	if !s.has(fMonth, int(day.Month())) {
		return false
	}
	dom := s.has(fDom, day.Day())
	dow := s.has(fDow, int(day.Weekday()))
	switch {
	case s.domStar && s.dowStar:
		return true
	case s.domStar:
		return dow
	case s.dowStar:
		return dom
	}
	return dom || dow
}

// searchDays bounds Next: 8 years and a day reach every 29 February, also
// across a century year that is not a leap year.
const searchDays = 8*366 + 1

// Next answers the first fire time strictly after after, in loc (nil is
// UTC), with the DST rule of spec 4.2: a local minute that does not exist
// fires at the first valid instant after the gap, and a local minute that
// occurs twice fires once, at its first occurrence. It answers the zero
// time when the expression names no existing date within searchDays.
func (s Schedule) Next(after time.Time, loc *time.Location) time.Time {
	if loc == nil {
		loc = time.UTC
	}
	start := civil(after.In(loc)).Truncate(time.Minute).Add(time.Minute)
	day := time.Date(start.Year(), start.Month(), start.Day(), 0, 0, 0, 0, time.UTC)
	for i := 0; i < searchDays; i, day = i+1, day.AddDate(0, 0, 1) {
		if !s.dayMatches(day) {
			continue
		}
		from := 0
		if i == 0 {
			from = start.Hour()*60 + start.Minute()
		}
		if t, ok := s.nextInDay(day, from, after, loc); ok {
			return t
		}
	}
	return time.Time{}
}

// nextInDay walks the matching minutes of one civil day from minute of day
// from, and answers the first whose instant is after after.
func (s Schedule) nextInDay(day time.Time, from int, after time.Time, loc *time.Location) (time.Time, bool) {
	for h := from / 60; h < 24; h++ {
		if !s.has(fHour, h) {
			continue
		}
		m0 := 0
		if h == from/60 {
			m0 = from % 60
		}
		for m := m0; m < 60; m++ {
			if !s.has(fMinute, m) {
				continue
			}
			c := day.Add(time.Duration(h)*time.Hour + time.Duration(m)*time.Minute)
			if t := instant(c, loc); t.After(after) {
				return t, true
			}
		}
	}
	return time.Time{}, false
}

// civil answers t's wall clock in its own location, as a UTC time, so civil
// times compare and add without a zone.
func civil(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second(), t.Nanosecond(), time.UTC)
}

// instant answers the instant of the civil minute c in loc: its first
// occurrence when the wall clock shows it twice, and the end of the gap
// when the wall clock skips it.
func instant(c time.Time, loc *time.Location) time.Time {
	t := time.Date(c.Year(), c.Month(), c.Day(), c.Hour(), c.Minute(), 0, 0, loc)
	w := civil(t)
	start, end := t.ZoneBounds()
	switch {
	case w.Equal(c):
		return firstOccurrence(t, start, c)
	case w.After(c) && !start.IsZero():
		return start
	case w.Before(c) && !end.IsZero():
		return end
	}
	return t
}

// firstOccurrence answers the earlier instant with the wall clock c when t
// sits just after a transition that turned the clock back.
func firstOccurrence(t, zoneStart, c time.Time) time.Time {
	if zoneStart.IsZero() {
		return t
	}
	_, off := t.Zone()
	_, prevOff := zoneStart.Add(-time.Second).Zone()
	if prevOff <= off {
		return t
	}
	alt := t.Add(time.Duration(off-prevOff) * time.Second)
	if alt.Before(zoneStart) && civil(alt).Equal(c) {
		return alt
	}
	return t
}

// MinGap walks the fire times from from over horizon and answers the
// smallest gap between two consecutive ones; ok=false when none fires. A
// single fire time answers horizon itself: no two fire times are closer.
func (s Schedule) MinGap(from time.Time, loc *time.Location, horizon time.Duration) (gap time.Duration, ok bool) {
	limit := from.Add(horizon)
	prev := s.Next(from, loc)
	if prev.IsZero() || prev.After(limit) {
		return 0, false
	}
	gap = horizon
	for {
		t := s.Next(prev, loc)
		if t.IsZero() || t.After(limit) {
			return gap, true
		}
		if d := t.Sub(prev); d < gap {
			gap = d
		}
		if gap <= time.Minute {
			return gap, true
		}
		prev = t
	}
}
