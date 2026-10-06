// SPDX-License-Identifier: AGPL-3.0-only

// Package calrecur is the calendar's repeat rule (spec 097 section 4.4): the
// RFC 5545 RRULE subset v1 accepts, the hub-computed end of a series
// (recur_until), the expansion of a series into occurrences in its time zone
// with exceptions and cancellations applied, the 2000-occurrence cap of one
// response, and the occurrence id <event_id>_<YYYYMMDDTHHMMSSZ>.
//
// The arithmetic (daylight saving, -1FR, BYMONTHDAY) is rrule-go's (Q1,
// MIT); this package is the wrapper that lets only the 4.4 subset in. It is
// pure: no store, no clock, no I/O.
//
//	FREQ        DAILY | WEEKLY | MONTHLY | YEARLY (required)
//	INTERVAL    1..MaxInterval
//	BYDAY       WEEKLY: MO,WE (no ordinal); MONTHLY: 2TU, -1FR (ordinal 1..5, -1..-5)
//	BYMONTHDAY  MONTHLY, YEARLY: 1..31, -1..-31
//	BYMONTH     YEARLY: 1..12
//	COUNT       1..MaxCount, or
//	UNTIL       YYYYMMDDTHHMMSSZ (UTC) or YYYYMMDD (end of that local day)
package calrecur

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/teambition/rrule-go"
)

// Limits of the subset. MaxOccurrences is one response's cap (spec 4.4:
// past it the read is 400 bad_range, never a silent cut).
const (
	MaxRuleLen     = 500
	MaxInterval    = 999
	MaxCount       = 5000
	MaxOccurrences = 2000
)

// ErrBadRule is every refused rule (the hub answers 400 bad_event).
var ErrBadRule = errors.New("calrecur: rule outside the supported subset")

// ErrTooMany is a range that holds more occurrences than the cap allows (the
// hub answers 400 bad_range, "narrow the range").
var ErrTooMany = errors.New("calrecur: too many occurrences in range")

// stampLayout is the UTC stamp of an occurrence id and of an UNTIL value.
const stampLayout = "20060102T150405Z"

// Rule is a parsed, validated rule. Its zero value is not a rule; get one
// from Parse.
type Rule struct {
	freq       rrule.Frequency
	interval   int
	byDay      []rrule.Weekday
	byMonthDay []int
	byMonth    []int
	count      int
	until      time.Time // UTC instant; zero when none or untilDate is set
	untilDate  string    // YYYYMMDD, resolved in the series' zone
}

// Bounded reports whether the series ends (COUNT or UNTIL).
func (r Rule) Bounded() bool {
	return r.count > 0 || !r.until.IsZero() || r.untilDate != ""
}

// Parse validates s against the 4.4 subset. s carries no "RRULE:" prefix.
func Parse(s string) (Rule, error) {
	if s == "" || len(s) > MaxRuleLen {
		return Rule{}, badRule("empty or longer than %d", MaxRuleLen)
	}
	parts, err := splitParts(s)
	if err != nil {
		return Rule{}, err
	}
	r := Rule{interval: 1}
	if r.freq, err = parseFreq(parts["FREQ"]); err != nil {
		return Rule{}, err
	}
	for key, val := range parts {
		if err := r.setPart(key, val); err != nil {
			return Rule{}, err
		}
	}
	if err := r.checkShape(); err != nil {
		return Rule{}, err
	}
	return r, nil
}

func badRule(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrBadRule, fmt.Sprintf(format, args...))
}

func splitParts(s string) (map[string]string, error) {
	parts := map[string]string{}
	for _, kv := range strings.Split(s, ";") {
		key, val, ok := strings.Cut(kv, "=")
		if !ok || key == "" || val == "" {
			return nil, badRule("part %q is not KEY=VALUE", kv)
		}
		if _, dup := parts[key]; dup {
			return nil, badRule("%s given twice", key)
		}
		parts[key] = val
	}
	return parts, nil
}

func parseFreq(v string) (rrule.Frequency, error) {
	switch v {
	case "DAILY":
		return rrule.DAILY, nil
	case "WEEKLY":
		return rrule.WEEKLY, nil
	case "MONTHLY":
		return rrule.MONTHLY, nil
	case "YEARLY":
		return rrule.YEARLY, nil
	}
	return 0, badRule("FREQ %q", v)
}

// setPart reads one KEY=VALUE. BYDAY needs r.freq, which Parse sets first.
func (r *Rule) setPart(key, val string) error {
	var err error
	switch key {
	case "FREQ":
	case "INTERVAL":
		r.interval, err = intIn(key, val, 1, MaxInterval)
	case "COUNT":
		r.count, err = intIn(key, val, 1, MaxCount)
	case "UNTIL":
		err = r.setUntil(val)
	case "BYDAY":
		r.byDay, err = parseByDay(val, r.freq)
	case "BYMONTHDAY":
		r.byMonthDay, err = intList(key, val, 31, true)
	case "BYMONTH":
		r.byMonth, err = intList(key, val, 12, false)
	default:
		err = badRule("%s is not supported", key)
	}
	return err
}

// checkShape refuses parts that do not belong to the rule's FREQ.
func (r Rule) checkShape() error {
	switch {
	case r.count > 0 && (!r.until.IsZero() || r.untilDate != ""):
		return badRule("COUNT and UNTIL together")
	case len(r.byDay) > 0 && r.freq != rrule.WEEKLY && r.freq != rrule.MONTHLY:
		return badRule("BYDAY needs FREQ=WEEKLY or MONTHLY")
	case len(r.byMonthDay) > 0 && r.freq != rrule.MONTHLY && r.freq != rrule.YEARLY:
		return badRule("BYMONTHDAY needs FREQ=MONTHLY or YEARLY")
	case len(r.byMonth) > 0 && r.freq != rrule.YEARLY:
		return badRule("BYMONTH needs FREQ=YEARLY")
	case len(r.byDay) > 0 && len(r.byMonthDay) > 0:
		return badRule("BYDAY and BYMONTHDAY together")
	}
	return nil
}

func (r *Rule) setUntil(v string) error {
	if len(v) == len("20060102") {
		if _, err := time.Parse("20060102", v); err != nil {
			return badRule("UNTIL %q", v)
		}
		r.untilDate = v
		return nil
	}
	t, err := time.Parse(stampLayout, v)
	if err != nil {
		return badRule("UNTIL %q is not YYYYMMDD or YYYYMMDDTHHMMSSZ", v)
	}
	r.until = t
	return nil
}

func intIn(key, v string, lo, hi int) (int, error) {
	n, err := strconv.Atoi(v)
	if err != nil || n < lo || n > hi || strings.HasPrefix(v, "+") {
		return 0, badRule("%s %q is not %d..%d", key, v, lo, hi)
	}
	return n, nil
}

// intList reads a comma list of 1..hi, and -hi..-1 when negative is allowed.
func intList(key, v string, hi int, negative bool) ([]int, error) {
	var out []int
	for _, item := range strings.Split(v, ",") {
		n, err := strconv.Atoi(item)
		bad := err != nil || n == 0 || n > hi || n < -hi || strings.HasPrefix(item, "+")
		if bad || (n < 0 && !negative) {
			return nil, badRule("%s value %q", key, item)
		}
		out = append(out, n)
	}
	return out, nil
}

var weekdays = map[string]rrule.Weekday{
	"MO": rrule.MO, "TU": rrule.TU, "WE": rrule.WE, "TH": rrule.TH,
	"FR": rrule.FR, "SA": rrule.SA, "SU": rrule.SU,
}

// parseByDay reads MO,WE for WEEKLY and 2TU,-1FR for MONTHLY: a weekly day
// carries no ordinal and a monthly day must. Other FREQs are refused by
// checkShape.
func parseByDay(v string, freq rrule.Frequency) ([]rrule.Weekday, error) {
	var out []rrule.Weekday
	seen := map[string]bool{}
	for _, item := range strings.Split(v, ",") {
		if len(item) < 2 || seen[item] {
			return nil, badRule("BYDAY value %q", item)
		}
		seen[item] = true
		day, ok := weekdays[item[len(item)-2:]]
		if !ok {
			return nil, badRule("BYDAY value %q", item)
		}
		wd, err := byDayOrdinal(item, day, freq)
		if err != nil {
			return nil, err
		}
		out = append(out, wd)
	}
	return out, nil
}

func byDayOrdinal(item string, day rrule.Weekday, freq rrule.Frequency) (rrule.Weekday, error) {
	ord := item[:len(item)-2]
	if freq != rrule.MONTHLY {
		if ord != "" {
			return day, badRule("BYDAY %q: an ordinal needs FREQ=MONTHLY", item)
		}
		return day, nil
	}
	n, err := strconv.Atoi(ord)
	if err != nil || n == 0 || n > 5 || n < -5 || strings.HasPrefix(ord, "+") {
		return day, badRule("BYDAY %q: FREQ=MONTHLY needs an ordinal 1..5 or -1..-5", item)
	}
	return day.Nth(n), nil
}

// option builds rrule-go's option for a series that starts at start in loc.
// The wall clock of start in loc is what every occurrence keeps.
func (r Rule) option(start time.Time, loc *time.Location) rrule.ROption {
	opt := rrule.ROption{
		Freq:       r.freq,
		Dtstart:    start.In(loc),
		Interval:   r.interval,
		Wkst:       rrule.MO,
		Count:      r.count,
		Until:      r.until,
		Bymonthday: r.byMonthDay,
		Bymonth:    r.byMonth,
		Byweekday:  r.byDay,
	}
	if r.untilDate != "" {
		d, _ := time.ParseInLocation("20060102", r.untilDate, loc) // checked in setUntil
		opt.Until = d.AddDate(0, 0, 1).Add(-time.Second)
	}
	return opt
}
