// SPDX-License-Identifier: AGPL-3.0-only

package hours

// Rate categories and the weekly flags of spec 107 FR-28 (row T024). Pure
// like Suggest and Across: no store, no clock, no settings read; the caller
// resolves the workspace keys and passes them in.
//
//  1. SplitCategories gives every minute of a row one category from its
//     start and end (the plan or the clock, or for an activity day
//     hours.day_start + the standard day; never activity, owner Q19), by the
//     member's local clock, precedence holiday > night > weekend > evening >
//     normal. A window may cross midnight (22:00-06:00). Holiday and weekend
//     go by the local date of the minute, so a night shift into a holiday is
//     holiday from midnight on.
//  2. A row's minutes under its start..end (the break, FR-26) are scaled down
//     across its categories by the largest remainder, ties in precedence
//     order; minutes over it (an activity day above the standard day, FR-15)
//     run on past the end.
//  3. FlagWeek marks a week's minutes past the overtime threshold
//     (hours.overtime_weekly_minutes, default 5 x the organisation's standard
//     day) as overtime, and those above the person's own weekly standard but
//     not past the threshold as extra, on the day the running total crosses.
//  4. A week across two periods is flagged when its last day freezes: a day
//     of the frozen earlier period keeps its flags (none), and what it would
//     have carried lands on the week's last day.
//
// A category is a label on minutes, never money (FR-19).

import (
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The rate categories, one per minute.
const (
	CategoryHoliday = "holiday"
	CategoryNight   = "night"
	CategoryWeekend = "weekend"
	CategoryEvening = "evening"
	CategoryNormal  = "normal"
)

// CategoryOrder is the precedence, highest first.
var CategoryOrder = []string{CategoryHoliday, CategoryNight, CategoryWeekend, CategoryEvening, CategoryNormal}

// The workspace window defaults (hours.evening_window, hours.night_window).
const (
	DefaultEveningWindow = "18:00-22:00"
	DefaultNightWindow   = "22:00-06:00"
)

// ClockWindow is a daily [From, To) in minutes after local midnight. To <=
// From crosses midnight: 22:00-06:00 is 22:00..24:00 and 00:00..06:00.
type ClockWindow struct {
	From int `json:"from"`
	To   int `json:"to"`
}

// ParseClockWindow reads "HH:MM-HH:MM". "24:00" may end a window; a window
// that starts and ends at the same time is refused (empty or all day, it
// cannot say which).
func ParseClockWindow(s string) (ClockWindow, error) {
	parts := strings.Split(s, "-")
	if len(parts) != 2 {
		return ClockWindow{}, fmt.Errorf("hours: window %q is not HH:MM-HH:MM", s)
	}
	from, err := clockMinute(strings.TrimSpace(parts[0]), false)
	if err != nil {
		return ClockWindow{}, fmt.Errorf("hours: window %q: %w", s, err)
	}
	to, err := clockMinute(strings.TrimSpace(parts[1]), true)
	if err != nil {
		return ClockWindow{}, fmt.Errorf("hours: window %q: %w", s, err)
	}
	if from == to%(24*60) {
		return ClockWindow{}, fmt.Errorf("hours: window %q starts and ends at the same time", s)
	}
	return ClockWindow{From: from, To: to}, nil
}

// clockMinute reads "HH:MM" as minutes after midnight; end allows "24:00".
func clockMinute(s string, end bool) (int, error) {
	if len(s) != 5 || s[2] != ':' {
		return 0, fmt.Errorf("%q is not HH:MM", s)
	}
	h, err1 := strconv.Atoi(s[:2])
	m, err2 := strconv.Atoi(s[3:])
	if err1 != nil || err2 != nil || h < 0 || m < 0 || m > 59 {
		return 0, fmt.Errorf("%q is not HH:MM", s)
	}
	if h > 23 && !(end && h == 24 && m == 0) {
		return 0, fmt.Errorf("%q is out of range", s)
	}
	return h*60 + m, nil
}

// Contains says whether the minute after local midnight m (0..1439) is in
// the window.
func (w ClockWindow) Contains(m int) bool {
	if w.From < w.To {
		return m >= w.From && m < w.To
	}
	return m >= w.From || m < w.To
}

func (w ClockWindow) empty() bool { return w.From == w.To }

// CategoryRules are the inputs of SplitCategories, resolved by the caller:
// the workspace's windows, the member's zone (spec 1.6) and the holidays of
// the member's region (FR-29) as local dates YYYY-MM-DD.
type CategoryRules struct {
	Evening  ClockWindow
	Night    ClockWindow
	Holidays map[string]bool
	Zone     *time.Location
}

// DefaultCategoryRules are the workspace defaults in zone, no holidays.
func DefaultCategoryRules(zone *time.Location) (CategoryRules, error) {
	evening, err := ParseClockWindow(DefaultEveningWindow)
	if err != nil {
		return CategoryRules{}, err
	}
	night, err := ParseClockWindow(DefaultNightWindow)
	if err != nil {
		return CategoryRules{}, err
	}
	return CategoryRules{Evening: evening, Night: night, Zone: zone}, nil
}

// CategoryMinutes is a row's split, the category_minutes stored at approval:
// category -> minutes, zero categories left out.
type CategoryMinutes map[string]int

// Total is the minutes of the split.
func (c CategoryMinutes) Total() int {
	n := 0
	for _, v := range c {
		n += v
	}
	return n
}

// categoryOf is the category of the minute starting at t.
func (r CategoryRules) categoryOf(t time.Time) string {
	local := t.In(r.Zone)
	if r.Holidays[local.Format(time.DateOnly)] {
		return CategoryHoliday
	}
	m := local.Hour()*60 + local.Minute()
	if r.Night.Contains(m) {
		return CategoryNight
	}
	if wd := local.Weekday(); wd == time.Saturday || wd == time.Sunday {
		return CategoryWeekend
	}
	if r.Evening.Contains(m) {
		return CategoryEvening
	}
	return CategoryNormal
}

// SplitCategories splits a row of minutes worked between start and end
// (seconds truncated) into its categories (rules 1 and 2 above). A span over
// 24 hours, minutes outside 0..1440 and minutes with no span are refused.
func SplitCategories(start, end time.Time, minutes int, r CategoryRules) (CategoryMinutes, error) {
	if r.Zone == nil {
		return nil, errors.New("hours: categories need the member's zone")
	}
	if r.Evening.empty() || r.Night.empty() {
		return nil, errors.New("hours: categories need the evening and night windows")
	}
	if minutes < 0 || minutes > 24*60 {
		return nil, fmt.Errorf("hours: %d minutes is outside 0..1440", minutes)
	}
	start, end = start.Truncate(time.Minute), end.Truncate(time.Minute)
	if end.Before(start) {
		return nil, errors.New("hours: the row ends before it starts")
	}
	span := int(end.Sub(start) / time.Minute)
	if span > 24*60 {
		return nil, fmt.Errorf("hours: a row of %d minutes is over 24 hours", span)
	}
	if minutes > 0 && span == 0 {
		return nil, errors.New("hours: minutes need a start and an end")
	}
	// Rule 2: a row over its span runs on past the end.
	if minutes > span {
		span = minutes
	}
	raw := map[string]int{}
	for i := 0; i < span; i++ {
		raw[r.categoryOf(start.Add(time.Duration(i)*time.Minute))]++
	}
	return scaleCategories(raw, span, minutes), nil
}

// scaleCategories scales raw (summing to span) to minutes by the largest
// remainder, ties in precedence order.
func scaleCategories(raw map[string]int, span, minutes int) CategoryMinutes {
	out := CategoryMinutes{}
	if minutes == 0 {
		return out
	}
	type rem struct {
		cat  string
		rank int
		rest int
	}
	var rems []rem
	left := minutes
	for rank, cat := range CategoryOrder {
		n := raw[cat]
		if n == 0 {
			continue
		}
		whole := n * minutes / span
		out[cat] = whole
		left -= whole
		rems = append(rems, rem{cat, rank, n * minutes % span})
	}
	sort.SliceStable(rems, func(i, j int) bool {
		if rems[i].rest != rems[j].rest {
			return rems[i].rest > rems[j].rest
		}
		return rems[i].rank < rems[j].rank
	})
	for i := 0; left > 0; i, left = i+1, left-1 {
		out[rems[i].cat]++
	}
	for cat, n := range out {
		if n == 0 {
			delete(out, cat)
		}
	}
	return out
}

// DefaultOvertimeWeeklyMinutes is hours.overtime_weekly_minutes' default: 5 x
// the organisation's standard day (never the person's, FR-28).
func DefaultOvertimeWeeklyMinutes(orgStandardDay int) int { return 5 * orgStandardDay }

// WeekRules are the inputs of FlagWeek, resolved by the caller: the overtime
// threshold (the person's override, else the workspace's) and the person's
// own weekly standard (the sum of their standard days, FR-14).
type WeekRules struct {
	OvertimeWeeklyMinutes int
	StandardWeeklyMinutes int
}

// WeekDay is one day of a week: the approved minutes worked (absences left
// out by the caller), and Frozen when the day's period froze already.
type WeekDay struct {
	Day     string `json:"day"` // YYYY-MM-DD
	Minutes int    `json:"minutes"`
	Frozen  bool   `json:"frozen,omitempty"`
}

// DayFlags is a day's share of the week's flags.
type DayFlags struct {
	Day      string `json:"day"`
	Minutes  int    `json:"minutes"`
	Extra    int    `json:"extra"`
	Overtime int    `json:"overtime"`
	Frozen   bool   `json:"frozen,omitempty"`
}

// FlagWeek flags one week (rules 3 and 4 above), called when the week's last
// day freezes. Days come in any order and are returned by date; a week holds
// at most seven days, each once, and its last day must not be frozen yet.
func FlagWeek(days []WeekDay, r WeekRules) ([]DayFlags, error) {
	if len(days) == 0 {
		return nil, errors.New("hours: a week needs a day")
	}
	if r.OvertimeWeeklyMinutes <= 0 || r.StandardWeeklyMinutes < 0 {
		return nil, fmt.Errorf("hours: bad week rules %+v", r)
	}
	sorted := append([]WeekDay(nil), days...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Day < sorted[j].Day })
	first, err := time.Parse(time.DateOnly, sorted[0].Day)
	if err != nil {
		return nil, fmt.Errorf("hours: day %q: %w", sorted[0].Day, err)
	}
	out := make([]DayFlags, len(sorted))
	for i, d := range sorted {
		t, err := time.Parse(time.DateOnly, d.Day)
		if err != nil {
			return nil, fmt.Errorf("hours: day %q: %w", d.Day, err)
		}
		if i > 0 && d.Day == sorted[i-1].Day {
			return nil, fmt.Errorf("hours: day %s twice in a week", d.Day)
		}
		if t.Sub(first) > 6*24*time.Hour {
			return nil, fmt.Errorf("hours: %s and %s are not one week", sorted[0].Day, d.Day)
		}
		if d.Minutes < 0 || d.Minutes > 24*60 {
			return nil, fmt.Errorf("hours: day %s has %d minutes", d.Day, d.Minutes)
		}
		out[i] = DayFlags{Day: d.Day, Minutes: d.Minutes, Frozen: d.Frozen}
	}
	last := len(out) - 1
	if out[last].Frozen {
		return nil, fmt.Errorf("hours: the week's last day %s is frozen already", out[last].Day)
	}
	standard := min(r.StandardWeeklyMinutes, r.OvertimeWeeklyMinutes)
	total := 0
	for i := range out {
		before := total
		total += out[i].Minutes
		overtime := total - max(before, r.OvertimeWeeklyMinutes)
		extra := min(total, r.OvertimeWeeklyMinutes) - max(before, standard)
		target := i
		if out[i].Frozen {
			target = last
		}
		out[target].Overtime += max(overtime, 0)
		out[target].Extra += max(extra, 0)
	}
	return out, nil
}
