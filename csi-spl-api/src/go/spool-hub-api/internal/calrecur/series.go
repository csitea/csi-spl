// SPDX-License-Identifier: AGPL-3.0-only

package calrecur

import (
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/teambition/rrule-go"
)

// ErrBadOccurrenceID is an id that is not <event_id>_<YYYYMMDDTHHMMSSZ>.
var ErrBadOccurrenceID = errors.New("calrecur: not an occurrence id")

// Series is one series row: its first occurrence [Start, End), its rule and
// the IANA zone the rule repeats in. Get one from NewSeries.
type Series struct {
	EventID string
	Start   time.Time
	End     time.Time
	Rule    Rule
	Loc     *time.Location
	rr      *rrule.RRule
}

// Exception is one exception row of a series: the occurrence it replaces
// (OriginalStart) and either its own times or a cancellation.
type Exception struct {
	EventID       string
	OriginalStart time.Time
	Start         time.Time
	End           time.Time
	Cancelled     bool
}

// Occurrence is one instance on the grid. ExceptionID is the exception row
// that supplied its times, "" for a plain occurrence. Times are UTC.
type Occurrence struct {
	ID            string
	OriginalStart time.Time
	Start         time.Time
	End           time.Time
	ExceptionID   string
}

// NewSeries validates a series row: a rule in the subset, a known zone
// ("" = UTC, 089's default), end not before start, and at least one
// occurrence (an UNTIL before the start, or a start that the rule never
// reaches within its COUNT, is refused as ErrBadRule).
func NewSeries(eventID, rule string, start, end time.Time, zone string) (Series, error) {
	r, err := Parse(rule)
	if err != nil {
		return Series{}, err
	}
	loc, err := time.LoadLocation(zoneOrUTC(zone))
	if err != nil || strings.EqualFold(zone, "Local") {
		return Series{}, badRule("time zone %q", zone)
	}
	if end.Before(start) {
		return Series{}, badRule("end before start")
	}
	rr, err := rrule.NewRRule(r.option(start, loc))
	if err != nil {
		return Series{}, badRule("%v", err)
	}
	s := Series{EventID: eventID, Start: start, End: end, Rule: r, Loc: loc, rr: rr}
	if s.rr.After(start.Add(-time.Second), true).IsZero() {
		return Series{}, badRule("the rule yields no occurrence")
	}
	return s, nil
}

func zoneOrUTC(zone string) string {
	if zone == "" {
		return "UTC"
	}
	return zone
}

func (s Series) duration() time.Duration { return s.End.Sub(s.Start) }

// RecurUntil is the series' recur_until: the end of its last occurrence, or
// ok=false (NULL) when the series never ends.
func (s Series) RecurUntil() (until time.Time, ok bool) {
	if !s.Rule.Bounded() {
		return time.Time{}, false
	}
	last := time.Time{}
	next := s.rr.Iterator()
	for t, more := next(); more; t, more = next() {
		last = t
	}
	return last.Add(s.duration()).UTC(), true
}

// Has reports whether t is an occurrence start the rule produces.
func (s Series) Has(t time.Time) bool {
	got := s.rr.After(t, true)
	return !got.IsZero() && got.Equal(t)
}

// Expand lists the occurrences that overlap [from, to) (start < to and
// end >= from, the 089 range read's test), sorted by start. An exception
// replaces the occurrence it names: a cancelled one drops it, a changed one
// shows at its own times (so a moved occurrence appears where it was moved
// to). An exception whose OriginalStart the rule no longer produces is
// ignored. More than limit occurrences is ErrTooMany; pass the response's
// remaining budget out of MaxOccurrences.
func (s Series) Expand(exceptions []Exception, from, to time.Time, limit int) ([]Occurrence, error) {
	byStart := make(map[int64]Exception, len(exceptions))
	for _, e := range exceptions {
		byStart[e.OriginalStart.UTC().Unix()] = e
	}
	out, err := s.plain(byStart, from, to, limit)
	if err != nil {
		return nil, err
	}
	for _, e := range exceptions {
		if e.Cancelled || !e.Start.Before(to) || e.End.Before(from) || !s.Has(e.OriginalStart) {
			continue
		}
		out = append(out, Occurrence{
			ID:            OccurrenceID(s.EventID, e.OriginalStart),
			OriginalStart: e.OriginalStart.UTC(),
			Start:         e.Start.UTC(),
			End:           e.End.UTC(),
			ExceptionID:   e.EventID,
		})
	}
	if len(out) > limit {
		return nil, ErrTooMany
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Start.Before(out[j].Start) })
	return out, nil
}

// plain walks the rule's occurrences in the window, skipping those an
// exception names, and stops as soon as more than limit are found.
func (s Series) plain(skip map[int64]Exception, from, to time.Time, limit int) ([]Occurrence, error) {
	var out []Occurrence
	dur := s.duration()
	next := s.rr.Iterator()
	for t, more := next(); more && t.Before(to); t, more = next() {
		if t.Add(dur).Before(from) {
			continue
		}
		if _, replaced := skip[t.UTC().Unix()]; replaced {
			continue
		}
		if len(out) == limit {
			return nil, ErrTooMany
		}
		out = append(out, Occurrence{
			ID:            OccurrenceID(s.EventID, t),
			OriginalStart: t.UTC(),
			Start:         t.UTC(),
			End:           t.Add(dur).UTC(),
		})
	}
	return out, nil
}

// OccurrenceID is <event_id>_<YYYYMMDDTHHMMSSZ> of the occurrence's
// unchanged start (spec 4.1, Google's form).
func OccurrenceID(eventID string, originalStart time.Time) string {
	return eventID + "_" + originalStart.UTC().Format(stampLayout)
}

// ParseOccurrenceID splits an occurrence id into its series id and the
// occurrence's unchanged start.
func ParseOccurrenceID(id string) (eventID string, originalStart time.Time, err error) {
	i := strings.LastIndexByte(id, '_')
	if i <= 0 {
		return "", time.Time{}, ErrBadOccurrenceID
	}
	t, perr := time.Parse(stampLayout, id[i+1:])
	if perr != nil {
		return "", time.Time{}, ErrBadOccurrenceID
	}
	return id[:i], t, nil
}
