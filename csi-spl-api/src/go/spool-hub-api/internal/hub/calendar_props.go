package hub

import (
	"encoding/json"
	"maps"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The props registry of an event (specs/097 T004, spec 3.3): the keys of
// calendar_events.props, their types and defaults. Every write goes through
// it; an unknown key is 400 bad_event. A new key is one line in
// calendarPropKeys and a test, no DDL (098's jsonb-plus-promotion rule).
//
// reminders (spec 4.3, owner E2) are kept as the person typed them, a whole
// number of minutes, hours or days before the start, at most 4 weeks, up to
// 5. remind_at stays on the wire for 089 clients: written, it becomes one
// reminder of the whole minutes before the start; read, it is the earliest
// coming fire time. The remind_at column holds the earliest fire time, so a
// hub that rolls back still reminds once.

const (
	calPropLocation  = "location"
	calPropColor     = "color"
	calPropReminders = "reminders"

	calendarLocationMax  = 300
	calendarMaxReminders = 5
	calendarReminderMax  = 28 * 24 * time.Hour // 4 weeks before the start
	calendarMethodPopup  = "popup"
)

// calendarPropKeys is the registry: each key's check, which answers the value
// to store, or nil for the key's default (the key is then dropped).
var calendarPropKeys = map[string]func(v any) (any, *issueErr){
	calPropLocation:  propLocation,
	calPropColor:     propColor,
	calPropReminders: propReminders,
}

// calendarColors is Google's palette of 11 (spec 3.3, Q9); "" is the kind's.
var calendarColors = []string{"tomato", "flamingo", "tangerine", "banana", "sage", "basil", "peacock",
	"blueberry", "lavender", "grape", "graphite"}

// calendarUnits is a reminder's unit and its length.
var calendarUnits = map[string]time.Duration{"minutes": time.Minute, "hours": time.Hour, "days": 24 * time.Hour}

// calendarReminder is one typed reminder (spec 4.3).
type calendarReminder struct {
	Amount int    `json:"amount"`
	Unit   string `json:"unit"`
	Method string `json:"method"`
}

func (r calendarReminder) lead() time.Duration {
	return time.Duration(r.Amount) * calendarUnits[r.Unit]
}

// propString checks a string prop; "" is its default.
func propString(name string, v any) (string, *issueErr) {
	s, ok := v.(string)
	if !ok {
		return "", badCalendar(name + " must be a string")
	}
	return strings.TrimSpace(s), nil
}

func propLocation(v any) (any, *issueErr) {
	s, ie := propString(calPropLocation, v)
	if ie != nil || s == "" {
		return nil, ie
	}
	if utf8.RuneCountInString(s) > calendarLocationMax {
		return nil, badCalendar("location is at most 300 characters")
	}
	return s, nil
}

func propColor(v any) (any, *issueErr) {
	s, ie := propString(calPropColor, v)
	if ie != nil || s == "" {
		return nil, ie
	}
	if !slices.Contains(calendarColors, s) {
		return nil, badCalendar("color must be one of " + strings.Join(calendarColors, ", "))
	}
	return s, nil
}

// wholeNumber reads a JSON number that is a whole number: a json.Number from
// a request, a float64 from the store. A string, 1.5 or 1e400 is not.
func wholeNumber(v any) (int, bool) {
	var f float64
	switch n := v.(type) {
	case json.Number:
		i, err := n.Int64()
		if err != nil || i > math.MaxInt32 || i < math.MinInt32 {
			return 0, false
		}
		return int(i), true
	case float64:
		f = n
	default:
		return 0, false
	}
	if f != math.Trunc(f) || math.Abs(f) > math.MaxInt32 {
		return 0, false
	}
	return int(f), true
}

// parseReminder checks one {amount, unit, method}.
func parseReminder(v any) (calendarReminder, *issueErr) {
	m, ok := v.(map[string]any)
	if !ok {
		return calendarReminder{}, badCalendar(`a reminder is {"amount", "unit", "method"}`)
	}
	for k := range m {
		if k != "amount" && k != "unit" && k != "method" {
			return calendarReminder{}, badCalendar("a reminder has no field " + k)
		}
	}
	r := calendarReminder{Method: calendarMethodPopup}
	r.Unit, _ = m["unit"].(string)
	if _, ok := calendarUnits[r.Unit]; !ok {
		return r, badCalendar("a reminder's unit is minutes, hours or days")
	}
	n, ok := wholeNumber(m["amount"])
	if !ok || n < 1 {
		return r, badCalendar("a reminder's amount is a whole number, 1 or more")
	}
	r.Amount = n
	if r.lead() > calendarReminderMax {
		return r, badCalendar("a reminder is at most 4 weeks (40320 minutes, 672 hours, 28 days) before the event")
	}
	if meth, set := m["method"]; set && meth != calendarMethodPopup {
		return r, badCalendar("a reminder's method is popup")
	}
	return r, nil
}

// checkReminders checks a list: each reminder, equal ones once, at most 5.
func checkReminders(list []any) ([]calendarReminder, *issueErr) {
	out := []calendarReminder{}
	for _, v := range list {
		r, ie := parseReminder(v)
		if ie != nil {
			return nil, ie
		}
		if !slices.Contains(out, r) {
			out = append(out, r)
		}
	}
	if len(out) > calendarMaxReminders {
		return nil, badCalendar("an event has at most 5 reminders")
	}
	return out, nil
}

func propReminders(v any) (any, *issueErr) {
	list, ok := v.([]any)
	if !ok && v != nil {
		return nil, badCalendar("reminders must be a list")
	}
	rs, ie := checkReminders(list)
	if ie != nil || len(rs) == 0 {
		return nil, ie
	}
	out := make([]any, 0, len(rs))
	for _, r := range rs {
		out = append(out, map[string]any{"amount": r.Amount, "unit": r.Unit, "method": r.Method})
	}
	return out, nil
}

// mergeCalendarProps applies set (key -> new value) onto cur through the
// registry: an unknown key is 400 bad_event, a default value drops its key.
// cur's own keys are kept as they are.
func mergeCalendarProps(cur, set map[string]any) (map[string]any, *issueErr) {
	out := maps.Clone(cur)
	if out == nil {
		out = map[string]any{}
	}
	for _, k := range slices.Sorted(maps.Keys(set)) {
		check, ok := calendarPropKeys[k]
		if !ok {
			return nil, badCalendar("props has no key " + k + " (known: location, color, reminders)")
		}
		v, ie := check(set[k])
		if ie != nil {
			return nil, ie
		}
		if v == nil {
			delete(out, k)
		} else {
			out[k] = v
		}
	}
	return out, nil
}

// propsString reads a string prop of a stored event, "" when unset.
func propsString(e store.CalendarEvent, k string) string {
	s, _ := e.Props[k].(string)
	return s
}

// storedReminders reads props.reminders; ok is false when the key is absent
// (an 089 event, or one whose reminders were cleared).
func storedReminders(e store.CalendarEvent) ([]calendarReminder, bool) {
	raw, ok := e.Props[calPropReminders]
	if !ok {
		return nil, false
	}
	list, _ := raw.([]any)
	out := []calendarReminder{}
	for _, v := range list {
		if m, ok := v.(map[string]any); ok {
			if n, ok := m["amount"].(int); ok { // not yet through the store's JSON copy
				m = maps.Clone(m)
				m["amount"] = float64(n)
				v = m
			}
		}
		if r, ie := parseReminder(v); ie == nil {
			out = append(out, r)
		}
	}
	return out, true
}

// legacyReminder is an 089 remind_at as a reminder: the whole minutes from
// it, its seconds dropped, to the start; ok is false when it is none, after the start, under a minute
// or over 4 weeks before.
func legacyReminder(remindAt, start time.Time) (calendarReminder, bool) {
	if remindAt.IsZero() || remindAt.After(start) {
		return calendarReminder{}, false
	}
	remindAt = remindAt.Truncate(time.Minute)
	r := calendarReminder{Amount: int(start.Sub(remindAt) / time.Minute), Unit: "minutes", Method: calendarMethodPopup}
	return r, r.Amount >= 1 && r.lead() <= calendarReminderMax
}

// eventReminders is what an event reads back: props.reminders, else its 089
// remind_at as one reminder.
func eventReminders(e store.CalendarEvent) []calendarReminder {
	if rs, ok := storedReminders(e); ok {
		return rs
	}
	if r, ok := legacyReminder(e.RemindAt, e.StartsAt); ok {
		return []calendarReminder{r}
	}
	return []calendarReminder{}
}

// reminderFires lists when e's reminders fire, earliest first. An 089
// remind_at no reminder can express (e.g. after the start) fires as stored.
func reminderFires(e store.CalendarEvent) []time.Time {
	if _, ok := storedReminders(e); !ok && !e.RemindAt.IsZero() {
		if _, derivable := legacyReminder(e.RemindAt, e.StartsAt); !derivable {
			return []time.Time{e.RemindAt}
		}
	}
	rs := eventReminders(e)
	out := make([]time.Time, 0, len(rs))
	for _, r := range rs {
		out = append(out, e.StartsAt.Add(-r.lead()))
	}
	slices.SortFunc(out, func(a, b time.Time) int { return a.Compare(b) })
	return out
}

// wireRemindAt is remind_at on the wire: the earliest fire time not yet
// past, else the earliest (so an 089 event reads back its one remind_at).
func wireRemindAt(e store.CalendarEvent, now time.Time) time.Time {
	fires := reminderFires(e)
	if len(fires) == 0 {
		return time.Time{}
	}
	for _, f := range fires {
		if !f.Before(now) {
			return f
		}
	}
	return fires[0]
}

// remindAtColumn is the remind_at column for reminders rs before start: the
// earliest fire time, zero for none.
func remindAtColumn(rs []calendarReminder, start time.Time) time.Time {
	var out time.Time
	for _, r := range rs {
		if f := start.Add(-r.lead()); out.IsZero() || f.Before(out) {
			out = f
		}
	}
	return out
}

// remindAtAsReminders is a written remind_at: zero clears every reminder;
// else one reminder of the whole minutes before start (seconds dropped).
func remindAtAsReminders(at, start time.Time) ([]any, *issueErr) {
	if at.IsZero() {
		return []any{}, nil
	}
	if at.After(start) {
		return nil, badCalendar("remind_at must not be after starts_at")
	}
	r, ok := legacyReminder(at, start)
	if !ok {
		return nil, badCalendar("remind_at must be 1 minute to 4 weeks before starts_at")
	}
	return []any{map[string]any{"amount": json.Number(strconv.Itoa(r.Amount)), "unit": r.Unit}}, nil
}

// checkTimeZone: an IANA zone this hub knows (the image carries tzdata).
func checkTimeZone(tz string) *issueErr {
	if tz == store.CalendarUTC {
		return nil
	}
	if _, err := time.LoadLocation(tz); err != nil || !auth.IsTimeZone(tz) || tz == "Local" {
		return badCalendar("time_zone must be an IANA zone name, e.g. Europe/Helsinki")
	}
	return nil
}
