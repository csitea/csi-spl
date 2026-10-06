// Package calquick is the quick-add parser of spec 097 section 4.6: one line
// of English becomes a calendar event, by a fixed grammar and no AI (089 D4,
// owner Q8). It is pure: no store, no clock of its own, no network. The route
// POST /v1/calendar/events/quick (T010, after T006 and T007) calls Parse and
// checks what only the workspace knows (a guest is a member, a kind is in
// rdb 0125's list, the rrule is in the 4.4 subset).
//
// The grammar, word by word, case-insensitive; every other word is the title:
//
//	date      today | tomorrow | monday..sunday | YYYY-MM-DD |
//	          Oct 12 (jan..dec, or the full month name, then the day)
//	time      15:00 | 3pm | 3:30pm | 15:00-16:00 | 3pm-4pm | 3-4pm
//	duration  for 30m | for 2h | for 1h30m
//	repeat    every day | every weekday | every monday..sunday |
//	          every week | every month | every year
//	guest     @<id>   (an agent id is an agent guest, anything else a human)
//	kind      #<kind>
//
// A weekday name is that day this week or later (today included); "Oct 12" is
// this year's, or next year's once it has passed. With no date the event is
// today, or for a repeat its first matching day. A time with no end lasts one
// hour; a range ends the same day. With no time the event is all day:
// midnight UTC to the next midnight, as 089 6.1.1 stores it. "for" or "every"
// followed by a word that is not a duration or a repeat are title words
// ("Prep for launch"). Weekday names are not abbreviated, so "Sun" and "Sat"
// stay title words.
//
// Text it cannot read is an *Error naming the part (HTTP 400 bad_quick_add):
// a time-like or date-like word that is not a valid one, a second date, time,
// duration, repeat or kind, an end before its start, a duration beside an end
// time or with no start, an empty @ or #, no date, time or repeat at all, or
// no title.
package calquick

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// Guest types, as spec 4.5 names them.
const (
	GuestHuman = "human"
	GuestAgent = "agent"
)

// defaultLength is a timed event's length when the text gives no end.
const defaultLength = time.Hour

const badTime = "is not a time (15:00, 3pm, 15:00-16:00)"

// Guest is one @id of the text.
type Guest struct {
	Type string
	ID   string
}

// Event is what the text describes. StartsAt and EndsAt are UTC. Kind is ""
// when the text names none (the route then applies 089's default, other).
// RRule is the spec 4.4 value without the RRULE: prefix, "" for a single
// event. Guests is never nil.
type Event struct {
	Title    string
	Kind     string
	StartsAt time.Time
	EndsAt   time.Time
	AllDay   bool
	TimeZone string
	RRule    string
	Guests   []Guest
}

// Error is text the grammar cannot read. Part is the words it stopped at
// ("" when the whole text is at fault), Reason what is wrong with them.
type Error struct {
	Part   string
	Reason string
}

func (e *Error) Error() string {
	if e.Part == "" {
		return e.Reason
	}
	return fmt.Sprintf("%q %s", e.Part, e.Reason)
}

func refuse(part, reason string) *Error { return &Error{Part: part, Reason: reason} }

var (
	weekdays = map[string]time.Weekday{
		"sunday": time.Sunday, "monday": time.Monday, "tuesday": time.Tuesday, "wednesday": time.Wednesday,
		"thursday": time.Thursday, "friday": time.Friday, "saturday": time.Saturday,
	}
	byday  = [...]string{"SU", "MO", "TU", "WE", "TH", "FR", "SA"}
	months = map[string]time.Month{
		"jan": time.January, "feb": time.February, "mar": time.March, "apr": time.April, "may": time.May,
		"jun": time.June, "jul": time.July, "aug": time.August, "sep": time.September, "oct": time.October,
		"nov": time.November, "dec": time.December,
		"january": time.January, "february": time.February, "march": time.March, "april": time.April,
		"june": time.June, "july": time.July, "august": time.August, "september": time.September,
		"october": time.October, "november": time.November, "december": time.December,
	}
	repeats = map[string]string{
		"day": "FREQ=DAILY", "weekday": "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "week": "FREQ=WEEKLY",
		"month": "FREQ=MONTHLY", "year": "FREQ=YEARLY",
	}

	isoDateRe  = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`)
	dateLikeRe = regexp.MustCompile(`^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$`)
	clockRe    = regexp.MustCompile(`^([0-9]{1,2})(?::([0-9]{2}))?(am|pm)?$`)
	timeLikeRe = regexp.MustCompile(`^[0-9]{1,2}(:[0-9]+)?(am|pm)?(-[0-9]{1,2}(:[0-9]+)?(am|pm)?)?$`)
	durRe      = regexp.MustCompile(`^(?:([0-9]{1,3})h)?(?:([0-9]{1,4})m)?$`)
	dayNumRe   = regexp.MustCompile(`^[0-9]{1,2}$`)
	kindRe     = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
)

// clock is a time of day in minutes after midnight.
type clock int

// parsed is the grammar's findings before they become an Event.
type parsed struct {
	title  []string
	date   *time.Time // a calendar date, midnight in the event's zone
	start  *clock
	end    *clock
	length time.Duration
	repeat string
	rday   *time.Weekday // the weekday of "every monday"
	kind   string
	guests []Guest
}

// Parse reads text as the 4.6 grammar. now is the caller's clock and loc the
// event's time zone (the body's time_zone, UTC when nil); dates and times are
// read in loc.
func Parse(text string, now time.Time, loc *time.Location) (Event, error) {
	if loc == nil {
		loc = time.UTC
	}
	words := strings.Fields(text)
	if len(words) == 0 {
		return Event{}, refuse("", "is empty")
	}
	n := now.In(loc)
	today := time.Date(n.Year(), n.Month(), n.Day(), 0, 0, 0, 0, loc)
	p := &parsed{guests: []Guest{}}
	for i := 0; i < len(words); {
		took, err := p.word(words, i, today)
		if err != nil {
			return Event{}, err
		}
		i += took
	}
	return p.event(today, loc)
}

// word reads the grammar item that starts at words[i] and answers how many
// words it took; a title word takes one.
func (p *parsed) word(words []string, i int, today time.Time) (int, error) {
	w := words[i]
	lw := strings.ToLower(w)
	next := ""
	if i+1 < len(words) {
		next = strings.ToLower(words[i+1])
	}
	switch {
	case strings.HasPrefix(w, "@"):
		return 1, p.guest(w)
	case strings.HasPrefix(w, "#"):
		return 1, p.setKind(w)
	case lw == "for" && next != "" && durRe.MatchString(next):
		return 2, p.setLength(w+" "+words[i+1], next)
	case lw == "every" && isRepeat(next):
		return 2, p.setRepeat(w+" "+words[i+1], next)
	}
	if took, ok, err := p.dateWord(w, lw, next, today); ok || err != nil {
		return took, err
	}
	if timeLikeRe.MatchString(lw) && (strings.ContainsAny(lw, ":-") || strings.HasSuffix(lw, "m")) {
		return 1, p.setTime(w, lw)
	}
	p.title = append(p.title, w)
	return 1, nil
}

// dateWord reads a date of one or two words; ok is false for a non-date.
func (p *parsed) dateWord(w, lw, next string, today time.Time) (int, bool, error) {
	if m, isMonth := months[lw]; isMonth && dayNumRe.MatchString(next) {
		d, err := monthDay(w+" "+next, m, next, today)
		if err != nil {
			return 0, true, err
		}
		return 2, true, p.setDate(w+" "+next, d)
	}
	var d time.Time
	switch wd, isDay := weekdays[lw]; {
	case lw == "today":
		d = today
	case lw == "tomorrow":
		d = today.AddDate(0, 0, 1)
	case isDay:
		d = onOrAfter(today, wd)
	case isoDateRe.MatchString(lw):
		t, err := time.ParseInLocation(time.DateOnly, lw, today.Location())
		if err != nil {
			return 0, true, refuse(w, "is not a date (YYYY-MM-DD)")
		}
		d = t
	case dateLikeRe.MatchString(lw):
		return 0, true, refuse(w, "is not a date (YYYY-MM-DD)")
	default:
		return 0, false, nil
	}
	return 1, true, p.setDate(w, d)
}

// monthDay is "Oct 12": this year's, or next year's once it has passed.
func monthDay(part string, m time.Month, day string, today time.Time) (time.Time, error) {
	n, _ := strconv.Atoi(day)
	for _, y := range []int{today.Year(), today.Year() + 1} {
		d := time.Date(y, m, n, 0, 0, 0, 0, today.Location())
		if d.Day() != n || d.Month() != m {
			return time.Time{}, refuse(part, "is not a date")
		}
		if !d.Before(today) {
			return d, nil
		}
	}
	return time.Time{}, refuse(part, "is not a date")
}

func (p *parsed) guest(w string) error {
	id := strings.TrimPrefix(w, "@")
	if id == "" {
		return refuse(w, "names no guest")
	}
	g := Guest{Type: GuestHuman, ID: id}
	if agentid.IsAgent(id) {
		g.Type = GuestAgent
	}
	for _, have := range p.guests {
		if have == g {
			return nil
		}
	}
	p.guests = append(p.guests, g)
	return nil
}

func (p *parsed) setKind(w string) error {
	k := strings.ToLower(strings.TrimPrefix(w, "#"))
	if !kindRe.MatchString(k) {
		return refuse(w, "is not a kind (#deploy, #release, ...)")
	}
	if p.kind != "" && p.kind != k {
		return refuse(w, "is a second kind")
	}
	p.kind = k
	return nil
}

// setLength reads the word after "for": 30m, 2h, 1h30m.
func (p *parsed) setLength(part, word string) error {
	m := durRe.FindStringSubmatch(word)
	h, _ := strconv.Atoi(m[1])
	mins, _ := strconv.Atoi(m[2])
	d := time.Duration(h)*time.Hour + time.Duration(mins)*time.Minute
	switch {
	case d <= 0:
		return refuse(part, "is not a duration (for 30m, for 2h)")
	case p.length != 0:
		return refuse(part, "is a second duration")
	}
	p.length = d
	return nil
}

func isRepeat(next string) bool {
	_, ok := repeats[next]
	_, day := weekdays[next]
	return ok || day
}

func (p *parsed) setRepeat(part, what string) error {
	if p.repeat != "" {
		return refuse(part, "is a second repeat")
	}
	if wd, day := weekdays[what]; day {
		p.repeat = "FREQ=WEEKLY;BYDAY=" + byday[wd]
		p.rday = &wd
		return nil
	}
	p.repeat = repeats[what]
	return nil
}

func (p *parsed) setDate(part string, d time.Time) error {
	if p.date != nil {
		return refuse(part, "is a second date")
	}
	p.date = &d
	return nil
}

// setTime reads 15:00, 3pm or a range 15:00-16:00.
func (p *parsed) setTime(w, lw string) error {
	if p.start != nil {
		return refuse(w, "is a second time")
	}
	from, to, isRange := strings.Cut(lw, "-")
	start, ok := readClock(from, to)
	if !ok {
		return refuse(w, badTime)
	}
	p.start = &start
	if !isRange {
		return nil
	}
	end, ok := readClock(to, from)
	if !ok {
		return refuse(w, badTime)
	}
	if end <= start {
		return refuse(w, "ends before it starts")
	}
	p.end = &end
	return nil
}

// readClock reads one end of a time. A bare hour ("3" in "3-4pm") takes the
// am / pm of the other end, mate; a bare hour with none is not a time.
func readClock(s, mate string) (clock, bool) {
	m := clockRe.FindStringSubmatch(s)
	if m == nil {
		return 0, false
	}
	h, _ := strconv.Atoi(m[1])
	mins, _ := strconv.Atoi(m[2])
	suffix := m[3]
	if suffix == "" && m[2] == "" {
		mm := clockRe.FindStringSubmatch(mate)
		if mm == nil || mm[3] == "" {
			return 0, false
		}
		suffix = mm[3]
	}
	if mins > 59 || (suffix == "" && h > 23) || (suffix != "" && (h < 1 || h > 12)) {
		return 0, false
	}
	if suffix != "" {
		h %= 12
		if suffix == "pm" {
			h += 12
		}
	}
	return clock(h*60 + mins), true
}

// event turns the findings into an Event.
func (p *parsed) event(today time.Time, loc *time.Location) (Event, error) {
	switch {
	case len(p.title) == 0:
		return Event{}, refuse("", "has no title")
	case p.date == nil && p.start == nil && p.repeat == "":
		return Event{}, refuse("", "has no date, time or repeat")
	case p.length != 0 && p.end != nil:
		return Event{}, refuse("for", "cannot stand beside an end time")
	case p.length != 0 && p.start == nil:
		return Event{}, refuse("for", "needs a start time")
	}
	day := p.firstDay(today)
	ev := Event{Title: strings.Join(p.title, " "), Kind: p.kind, TimeZone: loc.String(),
		RRule: p.repeat, Guests: p.guests}
	if p.start == nil {
		ev.AllDay = true
		ev.StartsAt = time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.UTC)
		ev.EndsAt = ev.StartsAt.AddDate(0, 0, 1)
		return ev, nil
	}
	start := at(day, *p.start, loc)
	end := start.Add(defaultLength)
	switch {
	case p.end != nil:
		end = at(day, *p.end, loc)
	case p.length != 0:
		end = start.Add(p.length)
	}
	ev.StartsAt, ev.EndsAt = start.UTC(), end.UTC()
	return ev, nil
}

// firstDay is the event's day: the date given, else today, moved forward to
// the first day the repeat holds.
func (p *parsed) firstDay(today time.Time) time.Time {
	day := today
	if p.date != nil {
		day = *p.date
	}
	switch {
	case p.rday != nil:
		day = onOrAfter(day, *p.rday)
	case p.repeat == repeats["weekday"]:
		for day.Weekday() == time.Saturday || day.Weekday() == time.Sunday {
			day = day.AddDate(0, 0, 1)
		}
	}
	return day
}

// at is clock c on day in loc.
func at(day time.Time, c clock, loc *time.Location) time.Time {
	return time.Date(day.Year(), day.Month(), day.Day(), int(c)/60, int(c)%60, 0, 0, loc)
}

// onOrAfter is the first day from d on that falls on wd.
func onOrAfter(d time.Time, wd time.Weekday) time.Time {
	return d.AddDate(0, 0, (int(wd)-int(d.Weekday())+7)%7)
}
