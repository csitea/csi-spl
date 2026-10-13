// SPDX-License-Identifier: AGPL-3.0-only

package hours

// Across is the overlap computation of spec 118 section 6 (D1): one person's
// hours in several workspaces become per personal day "reported" (the sum of
// what each workspace holds) and "actual" (wall-clock time counted once). It
// is pure like Suggest: no store, no clock of its own (now is given), nothing
// stored. The realm read route (spec 118 5.2, T003) reads each workspace as
// the person and calls it on every read, so a return or a resubmit shows on
// the next read. The WUI's today/timer arithmetic is checked against it by
// testdata/overlap_fixture.json (T-OV-JS).
//
// The rules, in the order of spec 118 6.2 and 6.3:
//
//  1. Placement (5.3): an entry's spans are taken from the earliest onward
//     until its minutes are placed, the last one used cut short; the rest of
//     its minutes is unplaced. An entry with no span (a typed number, an old
//     row, a left workspace's receipt) is wholly unplaced. A rejected entry
//     counts 0.
//  2. Placed minutes go to the personal day (zone) their span lies in, split
//     at the person's midnight; unplaced minutes stay on the workspace's date.
//     So reported and actual of a day add up the same minutes.
//  3. Reported(D) = placed + unplaced minutes of the counted entries; Open(D)
//     is the part from open suggestions.
//  4. Spans of one workspace that overlap each other (old data, 5.3 forbids
//     it) count once in actual and as DataErrorMinutes, never hidden.
//  5. A sweep line over every workspace's spans, an end before a start at the
//     same instant, keeps the set of open workspaces: a stretch where it holds
//     2 or more is an OverlapInterval; where it holds 1 or more is the union.
//  6. Actual(D) = |union| + unplaced (assumed not to overlap: Approx).
//     Overlap(D) = Reported - Actual, never negative.
//  7. An open timer [Timer, now) is a provisional span of its workspace: in
//     actual and in the intervals, never in reported.
//  8. An unavailable workspace marks its days Incomplete and names it; the
//     rest is computed. A window is the sum of its days (Sum).

import (
	"errors"
	"fmt"
	"slices"
	"sort"
	"time"
)

// Entry states as Across reads them: 107's approved and rejected rows, and
// the open suggestions of the member route.
const (
	EntryApproved = "approved"
	EntryOpen     = "open"
	EntryRejected = "rejected"
)

// TimeSpan is one interval [Start, End) of an entry, absolute (UTC on output).
type TimeSpan struct {
	Start time.Time `json:"start"`
	End   time.Time `json:"end"`
	// Provisional marks the open timer's span: drawn dashed, not entered.
	Provisional bool `json:"provisional,omitempty"`
}

// AcrossEntry is one entry of a workspace day: 107's hours_entries row (or an
// open suggestion, or a receipt row) with its hours_entry_spans.
type AcrossEntry struct {
	Target  string     `json:"target"`
	Minutes int        `json:"minutes"`
	State   string     `json:"state"` // EntryApproved, EntryOpen or EntryRejected
	Spans   []TimeSpan `json:"spans,omitempty"`
}

// WorkspaceDay is what one workspace holds for the person on one of its own
// days (the workspace's zone, 107 1.6).
type WorkspaceDay struct {
	Workspace   string        `json:"workspace"`
	Day         string        `json:"day"`                    // YYYY-MM-DD in the workspace's zone
	State       string        `json:"state,omitempty"`        // 107's mark, passed through
	StandardDay int           `json:"standard_day,omitempty"` // minutes, passed through
	Unavailable bool          `json:"unavailable,omitempty"`  // could not be read
	Entries     []AcrossEntry `json:"entries,omitempty"`
	// Timer is the start of the workspace's running timer (the WUI's, 6.3).
	Timer *time.Time `json:"timer,omitempty"`
}

// Totals are the numbers of a day or of a window, in minutes.
type Totals struct {
	Reported         int `json:"reported"`
	Open             int `json:"open"`
	Actual           int `json:"actual"`
	Overlap          int `json:"overlap"`
	Unplaced         int `json:"unplaced"`
	DataErrorMinutes int `json:"data_error_minutes"`
}

// OverlapInterval is a stretch where 2 or more workspaces hold the person.
type OverlapInterval struct {
	Start      time.Time `json:"start"`
	End        time.Time `json:"end"`
	Workspaces []string  `json:"workspaces"`
}

// WorkspaceShare is one workspace's part of a personal day.
type WorkspaceShare struct {
	Minutes     int        `json:"minutes"`
	Open        int        `json:"open"`
	State       string     `json:"state,omitempty"`
	StandardDay int        `json:"standard_day,omitempty"`
	Spans       []TimeSpan `json:"spans"`
}

// PersonalDay is one day in the person's zone (spec 118 6.4).
type PersonalDay struct {
	Day string `json:"day"`
	Totals
	Approx           bool                      `json:"approx"`
	Incomplete       bool                      `json:"incomplete"`
	Unavailable      []string                  `json:"unavailable"`
	OverlapIntervals []OverlapInterval         `json:"overlap_intervals"`
	Workspaces       map[string]WorkspaceShare `json:"workspaces"`
}

const dayLayout = "2006-01-02"

// Across computes the personal days of days in zone. A day appears when a
// workspace day names it or a span reaches into it; a span near a window's
// edge may reach a day outside it, so the caller keeps the days it asked for.
func Across(days []WorkspaceDay, zone *time.Location, now time.Time) ([]PersonalDay, error) {
	if zone == nil {
		return nil, errors.New("hours: no time zone")
	}
	acc := map[string]*dayAcc{}
	get := func(day string) *dayAcc {
		if acc[day] == nil {
			acc[day] = &dayAcc{spans: map[string][]TimeSpan{}, shares: map[string]*WorkspaceShare{}}
		}
		return acc[day]
	}
	for _, wd := range days {
		if _, err := time.Parse(dayLayout, wd.Day); err != nil {
			return nil, fmt.Errorf("hours: day %q: %w", wd.Day, err)
		}
		home := get(wd.Day)
		share := home.share(wd.Workspace)
		share.State, share.StandardDay = wd.State, wd.StandardDay
		if wd.Unavailable {
			home.unavailable = append(home.unavailable, wd.Workspace)
			continue
		}
		for _, e := range wd.Entries {
			if err := checkEntry(wd, e); err != nil {
				return nil, err
			}
			if e.State == EntryRejected {
				continue
			}
			placed, unplaced := place(e.Spans, e.Minutes)
			for _, s := range placed {
				for _, part := range splitAtMidnight(s, zone) {
					get(part.Start.In(zone).Format(dayLayout)).add(wd.Workspace, part, e.State == EntryOpen)
				}
			}
			if unplaced > 0 {
				home.unplaced += unplaced
				home.addMinutes(wd.Workspace, unplaced, e.State == EntryOpen)
			}
		}
		if wd.Timer != nil && now.After(*wd.Timer) {
			s := TimeSpan{Start: wd.Timer.UTC(), End: now.UTC(), Provisional: true}
			for _, part := range splitAtMidnight(s, zone) {
				get(part.Start.In(zone).Format(dayLayout)).add(wd.Workspace, part, false)
			}
		}
	}
	out := make([]PersonalDay, 0, len(acc))
	for day, d := range acc {
		out = append(out, d.result(day))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Day < out[j].Day })
	return out, nil
}

// Sum is a window's totals: the sum of its days, never a second union (6.2
// step 7).
func Sum(days []PersonalDay) Totals {
	var t Totals
	for _, d := range days {
		t.Reported += d.Reported
		t.Open += d.Open
		t.Actual += d.Actual
		t.Overlap += d.Overlap
		t.Unplaced += d.Unplaced
		t.DataErrorMinutes += d.DataErrorMinutes
	}
	return t
}

func checkEntry(wd WorkspaceDay, e AcrossEntry) error {
	switch {
	case e.State != EntryApproved && e.State != EntryOpen && e.State != EntryRejected:
		return fmt.Errorf("hours: %s %s: entry state %q", wd.Workspace, wd.Day, e.State)
	case e.Minutes < 0:
		return fmt.Errorf("hours: %s %s: negative minutes", wd.Workspace, wd.Day)
	}
	for _, s := range e.Spans {
		if !s.End.After(s.Start) {
			return fmt.Errorf("hours: %s %s: span does not end after its start", wd.Workspace, wd.Day)
		}
	}
	return nil
}

// place applies 5.3's rule: placed = min(minutes, span length), the spans
// taken from the earliest onward and the last one used cut short.
func place(spans []TimeSpan, minutes int) ([]TimeSpan, int) {
	sorted := sortedSpans(spans)
	left := time.Duration(minutes) * time.Minute
	var placed []TimeSpan
	for _, s := range sorted {
		if left <= 0 {
			break
		}
		s = TimeSpan{Start: s.Start.UTC(), End: s.End.UTC()}
		if s.End.Sub(s.Start) > left {
			s.End = s.Start.Add(left)
		}
		left -= s.End.Sub(s.Start)
		placed = append(placed, s)
	}
	return placed, int(left / time.Minute)
}

// splitAtMidnight cuts s at each midnight of zone; a DST day is simply 23 or
// 25 hours long between two midnights.
func splitAtMidnight(s TimeSpan, zone *time.Location) []TimeSpan {
	var parts []TimeSpan
	for s.Start.Before(s.End) {
		l := s.Start.In(zone)
		next := time.Date(l.Year(), l.Month(), l.Day()+1, 0, 0, 0, 0, zone).UTC()
		if !next.Before(s.End) {
			parts = append(parts, s)
			break
		}
		parts = append(parts, TimeSpan{Start: s.Start, End: next, Provisional: s.Provisional})
		s.Start = next
	}
	return parts
}

func sortedSpans(spans []TimeSpan) []TimeSpan {
	sorted := append([]TimeSpan{}, spans...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Start.Before(sorted[j].Start) })
	return sorted
}

func minutesOf(s TimeSpan) int { return int(s.End.Sub(s.Start) / time.Minute) }

type dayAcc struct {
	spans       map[string][]TimeSpan // per workspace, placed and provisional
	shares      map[string]*WorkspaceShare
	reported    int
	open        int
	unplaced    int
	unavailable []string
}

func (d *dayAcc) share(ws string) *WorkspaceShare {
	if d.shares[ws] == nil {
		d.shares[ws] = &WorkspaceShare{}
	}
	return d.shares[ws]
}

func (d *dayAcc) addMinutes(ws string, minutes int, open bool) {
	sh := d.share(ws)
	sh.Minutes += minutes
	d.reported += minutes
	if open {
		sh.Open += minutes
		d.open += minutes
	}
}

// add files a span of ws under the day; an entered one also counts its
// minutes, a provisional one (the timer) does not.
func (d *dayAcc) add(ws string, s TimeSpan, open bool) {
	d.spans[ws] = append(d.spans[ws], s)
	sh := d.share(ws)
	sh.Spans = append(sh.Spans, s)
	if !s.Provisional {
		d.addMinutes(ws, minutesOf(s), open)
	}
}

func (d *dayAcc) result(day string) PersonalDay {
	pd := PersonalDay{
		Day:              day,
		Unavailable:      append([]string{}, d.unavailable...),
		OverlapIntervals: []OverlapInterval{},
		Workspaces:       map[string]WorkspaceShare{},
	}
	sort.Strings(pd.Unavailable)
	pd.Incomplete = len(pd.Unavailable) > 0
	var events []event
	for ws, spans := range d.spans {
		merged, dup := union(spans)
		pd.DataErrorMinutes += dup
		for _, s := range merged {
			events = append(events, event{at: s.Start, ws: ws, delta: 1}, event{at: s.End, ws: ws, delta: -1})
		}
	}
	unionMinutes, intervals := sweep(events)
	pd.OverlapIntervals = append(pd.OverlapIntervals, intervals...)
	pd.Reported, pd.Open, pd.Unplaced = d.reported, d.open, d.unplaced
	pd.Approx = d.unplaced > 0
	pd.Actual = unionMinutes + d.unplaced
	if pd.Overlap = pd.Reported - pd.Actual; pd.Overlap < 0 {
		pd.Overlap = 0
	}
	for ws, sh := range d.shares {
		out := *sh
		out.Spans = sortedSpans(sh.Spans)
		pd.Workspaces[ws] = out
	}
	return pd
}

// union merges one workspace's spans; dup is the minutes its entered spans
// overlap each other (old data). Touching spans are no overlap, and the
// provisional timer joins the union but is never a data error.
func union(spans []TimeSpan) ([]TimeSpan, int) {
	var merged []TimeSpan
	var enteredEnd time.Time
	dup := 0
	for _, s := range sortedSpans(spans) {
		if !s.Provisional {
			if s.Start.Before(enteredEnd) {
				dup += minutesOf(TimeSpan{Start: s.Start, End: minTime(s.End, enteredEnd)})
			}
			if s.End.After(enteredEnd) {
				enteredEnd = s.End
			}
		}
		if n := len(merged); n > 0 && !s.Start.After(merged[n-1].End) {
			if s.End.After(merged[n-1].End) {
				merged[n-1].End = s.End
			}
			continue
		}
		merged = append(merged, TimeSpan{Start: s.Start, End: s.End})
	}
	return merged, dup
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

type event struct {
	at    time.Time
	ws    string
	delta int
}

// sweep walks the endpoints, ends before starts at one instant, and returns
// the union's minutes and the stretches with 2 or more workspaces open
// (adjacent stretches with the same set joined).
func sweep(events []event) (int, []OverlapInterval) {
	sort.Slice(events, func(i, j int) bool {
		if !events[i].at.Equal(events[j].at) {
			return events[i].at.Before(events[j].at)
		}
		return events[i].delta < events[j].delta
	})
	open := map[string]int{}
	var total time.Duration
	var out []OverlapInterval
	for i, ev := range events {
		if i > 0 && len(open) > 0 && ev.at.After(events[i-1].at) {
			from := events[i-1].at
			total += ev.at.Sub(from)
			if len(open) >= 2 {
				out = appendInterval(out, from, ev.at, open)
			}
		}
		if open[ev.ws] += ev.delta; open[ev.ws] == 0 {
			delete(open, ev.ws)
		}
	}
	return int(total / time.Minute), out
}

func appendInterval(out []OverlapInterval, from, to time.Time, open map[string]int) []OverlapInterval {
	ws := make([]string, 0, len(open))
	for w := range open {
		ws = append(ws, w)
	}
	sort.Strings(ws)
	if n := len(out); n > 0 && out[n-1].End.Equal(from) && slices.Equal(out[n-1].Workspaces, ws) {
		out[n-1].End = to
		return out
	}
	return append(out, OverlapInterval{Start: from, End: to, Workspaces: ws})
}
