package calquick

import (
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

// now is Tuesday 2026-10-06 13:00 in Helsinki (EEST, +03:00); Helsinki goes
// back to EET (+02:00) on Sunday 2026-10-25.
var now = time.Date(2026, 10, 6, 10, 0, 0, 0, time.UTC)

func helsinki(t *testing.T) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation("Europe/Helsinki")
	if err != nil {
		t.Skipf("no tz database: %v", err)
	}
	return loc
}

func utc(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

// TestParseGrammar covers every line of the 4.6 grammar.
func TestParseGrammar(t *testing.T) {
	loc := helsinki(t)
	agent := []Guest{{Type: GuestAgent, ID: "c-004"}}
	cases := []struct {
		name, text string
		want       Event
	}{
		// spec 4.6's own example
		{"spec example", "Deploy prd tomorrow 15:00-16:00 @c-004 #deploy",
			Event{Title: "Deploy prd", Kind: "deploy", StartsAt: utc("2026-10-07T12:00:00Z"), EndsAt: utc("2026-10-07T13:00:00Z"), Guests: agent}},
		// AC-09
		{"AC-09 weekday standup", "Standup every weekday 09:30 for 15m @c-004",
			Event{Title: "Standup", RRule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", StartsAt: utc("2026-10-06T06:30:00Z"), EndsAt: utc("2026-10-06T06:45:00Z"), Guests: agent}},
		// dates
		{"today all day", "Freeze today", Event{Title: "Freeze", AllDay: true, StartsAt: utc("2026-10-06T00:00:00Z"), EndsAt: utc("2026-10-07T00:00:00Z")}},
		{"tomorrow all day", "Freeze tomorrow", Event{Title: "Freeze", AllDay: true, StartsAt: utc("2026-10-07T00:00:00Z"), EndsAt: utc("2026-10-08T00:00:00Z")}},
		{"weekday name later", "Review friday 10:00", Event{Title: "Review", StartsAt: utc("2026-10-09T07:00:00Z"), EndsAt: utc("2026-10-09T08:00:00Z")}},
		{"weekday name is today", "Review Tuesday 15:00", Event{Title: "Review", StartsAt: utc("2026-10-06T12:00:00Z"), EndsAt: utc("2026-10-06T13:00:00Z")}},
		{"weekday name wraps", "Review monday 10:00", Event{Title: "Review", StartsAt: utc("2026-10-12T07:00:00Z"), EndsAt: utc("2026-10-12T08:00:00Z")}},
		{"iso date across dst", "Release 2026-10-26 09:00", Event{Title: "Release", StartsAt: utc("2026-10-26T07:00:00Z"), EndsAt: utc("2026-10-26T08:00:00Z")}},
		{"month day", "Party Oct 12", Event{Title: "Party", AllDay: true, StartsAt: utc("2026-10-12T00:00:00Z"), EndsAt: utc("2026-10-13T00:00:00Z")}},
		{"month day full name", "Party october 12 18:00", Event{Title: "Party", StartsAt: utc("2026-10-12T15:00:00Z"), EndsAt: utc("2026-10-12T16:00:00Z")}},
		{"month day passed is next year", "Party Jan 3", Event{Title: "Party", AllDay: true, StartsAt: utc("2027-01-03T00:00:00Z"), EndsAt: utc("2027-01-04T00:00:00Z")}},
		{"month day today", "Party Oct 6", Event{Title: "Party", AllDay: true, StartsAt: utc("2026-10-06T00:00:00Z"), EndsAt: utc("2026-10-07T00:00:00Z")}},
		// times
		{"24h time, no date is today", "Sync 15:00", Event{Title: "Sync", StartsAt: utc("2026-10-06T12:00:00Z"), EndsAt: utc("2026-10-06T13:00:00Z")}},
		{"3pm", "Sync tomorrow 3pm", Event{Title: "Sync", StartsAt: utc("2026-10-07T12:00:00Z"), EndsAt: utc("2026-10-07T13:00:00Z")}},
		{"3:30pm", "Sync tomorrow 3:30PM", Event{Title: "Sync", StartsAt: utc("2026-10-07T12:30:00Z"), EndsAt: utc("2026-10-07T13:30:00Z")}},
		{"12am is midnight", "Batch tomorrow 12am", Event{Title: "Batch", StartsAt: utc("2026-10-06T21:00:00Z"), EndsAt: utc("2026-10-06T22:00:00Z")}},
		{"12pm is noon", "Lunch tomorrow 12pm", Event{Title: "Lunch", StartsAt: utc("2026-10-07T09:00:00Z"), EndsAt: utc("2026-10-07T10:00:00Z")}},
		{"range pm", "Sync tomorrow 3pm-4:30pm", Event{Title: "Sync", StartsAt: utc("2026-10-07T12:00:00Z"), EndsAt: utc("2026-10-07T13:30:00Z")}},
		{"range shares pm", "Sync tomorrow 3-4pm", Event{Title: "Sync", StartsAt: utc("2026-10-07T12:00:00Z"), EndsAt: utc("2026-10-07T13:00:00Z")}},
		// durations
		{"for 30m", "Call tomorrow 10:00 for 30m", Event{Title: "Call", StartsAt: utc("2026-10-07T07:00:00Z"), EndsAt: utc("2026-10-07T07:30:00Z")}},
		{"for 2h", "Call tomorrow 10:00 for 2h", Event{Title: "Call", StartsAt: utc("2026-10-07T07:00:00Z"), EndsAt: utc("2026-10-07T09:00:00Z")}},
		{"for 1h30m", "Call tomorrow 10:00 for 1h30m", Event{Title: "Call", StartsAt: utc("2026-10-07T07:00:00Z"), EndsAt: utc("2026-10-07T08:30:00Z")}},
		// repeats
		{"every day", "Backup every day 02:00", Event{Title: "Backup", RRule: "FREQ=DAILY", StartsAt: utc("2026-10-05T23:00:00Z"), EndsAt: utc("2026-10-06T00:00:00Z")}},
		{"every monday", "Planning every Monday 10:00", Event{Title: "Planning", RRule: "FREQ=WEEKLY;BYDAY=MO", StartsAt: utc("2026-10-12T07:00:00Z"), EndsAt: utc("2026-10-12T08:00:00Z")}},
		{"every month from a date", "Invoices every month 2026-11-01", Event{Title: "Invoices", RRule: "FREQ=MONTHLY", AllDay: true, StartsAt: utc("2026-11-01T00:00:00Z"), EndsAt: utc("2026-11-02T00:00:00Z")}},
		{"every week", "Retro every week friday 14:00", Event{Title: "Retro", RRule: "FREQ=WEEKLY", StartsAt: utc("2026-10-09T11:00:00Z"), EndsAt: utc("2026-10-09T12:00:00Z")}},
		{"every year", "Audit every year Oct 20", Event{Title: "Audit", RRule: "FREQ=YEARLY", AllDay: true, StartsAt: utc("2026-10-20T00:00:00Z"), EndsAt: utc("2026-10-21T00:00:00Z")}},
		{"every weekday from a saturday", "Standup every weekday 2026-10-10 09:30", Event{Title: "Standup", RRule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", StartsAt: utc("2026-10-12T06:30:00Z"), EndsAt: utc("2026-10-12T07:30:00Z")}},
		// guests, kind, title
		{"human and agent guests, repeat once", "Pair tomorrow 10:00 @HUM-10 @c-004 @c-004",
			Event{Title: "Pair", StartsAt: utc("2026-10-07T07:00:00Z"), EndsAt: utc("2026-10-07T08:00:00Z"), Guests: []Guest{{GuestHuman, "HUM-10"}, {GuestAgent, "c-004"}}}},
		{"kind is lowercased", "Ship tomorrow #Release", Event{Title: "Ship", Kind: "release", AllDay: true, StartsAt: utc("2026-10-07T00:00:00Z"), EndsAt: utc("2026-10-08T00:00:00Z")}},
		{"for and every as title words", "Prep for launch every PR tomorrow", Event{Title: "Prep for launch every PR", AllDay: true, StartsAt: utc("2026-10-07T00:00:00Z"), EndsAt: utc("2026-10-08T00:00:00Z")}},
		{"numbers and abbreviations stay title", "Top 3 Sun issues May tomorrow", Event{Title: "Top 3 Sun issues May", AllDay: true, StartsAt: utc("2026-10-07T00:00:00Z"), EndsAt: utc("2026-10-08T00:00:00Z")}},
		{"title in the middle", "tomorrow 10:00 Deploy prd", Event{Title: "Deploy prd", StartsAt: utc("2026-10-07T07:00:00Z"), EndsAt: utc("2026-10-07T08:00:00Z")}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := Parse(c.text, now, loc)
			if err != nil {
				t.Fatalf("Parse(%q): %v", c.text, err)
			}
			c.want.TimeZone = "Europe/Helsinki"
			if c.want.Guests == nil {
				c.want.Guests = []Guest{}
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("Parse(%q)\n got %+v\nwant %+v", c.text, got, c.want)
			}
		})
	}
}

// TestParseRefusals: text the grammar cannot read is an *Error naming the part.
func TestParseRefusals(t *testing.T) {
	loc := helsinki(t)
	cases := []struct{ text, part, reason string }{
		{"", "", "is empty"},
		{"   ", "", "is empty"},
		{"tomorrow 15:00", "", "has no title"},
		{"Lunch", "", "has no date, time or repeat"},
		{"Lunch 25:00", "25:00", "is not a time"},
		{"Lunch 12:75", "12:75", "is not a time"},
		{"Lunch 13pm", "13pm", "is not a time"},
		{"Lunch 0am", "0am", "is not a time"},
		{"Lunch 3-4", "3-4", "is not a time"},
		{"Lunch 16:00-15:00", "16:00-15:00", "ends before it starts"},
		{"Lunch 2026-13-01", "2026-13-01", "is not a date"},
		{"Lunch 2026-02-30", "2026-02-30", "is not a date"},
		{"Lunch 2026-1-5", "2026-1-5", "is not a date"},
		{"Lunch Feb 30", "Feb 30", "is not a date"},
		{"Lunch today tomorrow", "tomorrow", "is a second date"},
		{"Lunch today 12:00 13:00", "13:00", "is a second time"},
		{"Lunch every day every month", "every month", "is a second repeat"},
		{"Lunch today 12:00 for 1h for 2h", "for 2h", "is a second duration"},
		{"Lunch today 12:00 for 0m", "for 0m", "is not a duration"},
		{"Lunch today 12:00-13:00 for 1h", "for", "cannot stand beside an end time"},
		{"Lunch today for 1h", "for", "needs a start time"},
		{"Lunch today @", "@", "names no guest"},
		{"Lunch today #", "#", "is not a kind"},
		{"Lunch today #a-b", "#a-b", "is not a kind"},
		{"Lunch today #deploy #release", "#release", "is a second kind"},
	}
	for _, c := range cases {
		t.Run(c.text, func(t *testing.T) {
			_, err := Parse(c.text, now, loc)
			var qe *Error
			if !errors.As(err, &qe) {
				t.Fatalf("Parse(%q) = %v, want an *Error", c.text, err)
			}
			if qe.Part != c.part || !strings.HasPrefix(qe.Reason, c.reason) {
				t.Fatalf("Parse(%q) = part %q reason %q, want part %q reason %q...", c.text, qe.Part, qe.Reason, c.part, c.reason)
			}
			if c.part != "" && !strings.Contains(err.Error(), c.part) {
				t.Fatalf("Parse(%q): the message %q does not name the part %q", c.text, err.Error(), c.part)
			}
		})
	}
}

// TestParseKeepsLocalTimeAcrossDST: the same 09:00 before and after Helsinki's
// October change is two different UTC instants (the zone, not a fixed offset).
func TestParseKeepsLocalTimeAcrossDST(t *testing.T) {
	loc := helsinki(t)
	before, err1 := Parse("Standup 2026-10-23 09:00", now, loc)
	after, err2 := Parse("Standup 2026-10-26 09:00", now, loc)
	if err1 != nil || err2 != nil {
		t.Fatalf("parse: %v %v", err1, err2)
	}
	if before.StartsAt.Hour() != 6 || after.StartsAt.Hour() != 7 {
		t.Fatalf("09:00 Helsinki = %v and %v UTC, want 06:00 and 07:00", before.StartsAt, after.StartsAt)
	}
}

// TestParseNilZoneIsUTC: no zone reads the text in UTC.
func TestParseNilZoneIsUTC(t *testing.T) {
	got, err := Parse("Sync tomorrow 15:00", now, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got.TimeZone != "UTC" || !got.StartsAt.Equal(utc("2026-10-07T15:00:00Z")) {
		t.Fatalf("got %+v, want 15:00 UTC tomorrow", got)
	}
}

// TestParseTodayIsTheZonesDay: at 23:30 UTC it is already tomorrow in Helsinki.
func TestParseTodayIsTheZonesDay(t *testing.T) {
	loc := helsinki(t)
	late := time.Date(2026, 10, 6, 23, 30, 0, 0, time.UTC)
	got, err := Parse("Freeze today", late, loc)
	if err != nil {
		t.Fatal(err)
	}
	if !got.StartsAt.Equal(utc("2026-10-07T00:00:00Z")) {
		t.Fatalf("today in Helsinki at %v = %v, want 2026-10-07", late, got.StartsAt)
	}
}
