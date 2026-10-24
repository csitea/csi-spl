package hub

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Spool -> Google event mapping of spec 149 section 2.5 (build row B6a,
// SPL-3226): what a Spool event becomes on the member's target calendar, and
// the sync hash that keeps an unchanged event from being written twice.

// gcalRRulePrefix starts a recurrence line at Google (RFC 5545); Spool
// stores the rule without it.
const gcalRRulePrefix = "RRULE:"

// GcalSyncHash is the event's sync_hash (spec 149 2.5, Echo): SHA-256 of
// title, description, starts_at, ends_at, all_day, time_zone, rrule and
// status joined by newlines, as 64 hex digits. Times are UTC RFC 3339 with
// nanoseconds, so one instant hashes the same in any zone; an empty time
// zone is UTC and an empty status confirmed, as the store fills them.
func GcalSyncHash(e store.CalendarEvent) string {
	tz := e.TimeZone
	if tz == "" {
		tz = store.CalendarUTC
	}
	status := e.Status
	if status == "" {
		status = store.CalendarConfirmed
	}
	h := sha256.Sum256([]byte(strings.Join([]string{
		e.Title, e.Description,
		e.StartsAt.UTC().Format(time.RFC3339Nano), e.EndsAt.UTC().Format(time.RFC3339Nano),
		strconv.FormatBool(e.AllDay), tz, strings.TrimPrefix(e.RRule, gcalRRulePrefix), status,
	}, "\n")))
	return hex.EncodeToString(h[:])
}

// GcalEventOf is the Google event a Spool event is written as (spec 149
// 2.5, Mapping): title -> summary, description, start and end (dates when
// all-day, Google's end date exclusive), time_zone -> timeZone, rrule -> one
// RRULE: line, audience private -> visibility private, any other ->
// default. It is confirmed at Google: a Spool delete is a DELETE there.
func GcalEventOf(e store.CalendarEvent) gcal.Event {
	out := gcal.Event{
		Status: store.CalendarConfirmed, Summary: e.Title, Description: e.Description,
		Visibility: "default", Recurrence: []string{},
	}
	if e.Audience == store.CalendarPrivate {
		out.Visibility = "private"
	}
	if e.RRule != "" {
		out.Recurrence = []string{gcalRRulePrefix + strings.TrimPrefix(e.RRule, gcalRRulePrefix)}
	}
	if e.AllDay {
		start := e.StartsAt.UTC().Format(time.DateOnly)
		end := e.EndsAt.UTC().Format(time.DateOnly)
		if end <= start { // the end date is exclusive: one day at least
			end = e.StartsAt.UTC().AddDate(0, 0, 1).Format(time.DateOnly)
		}
		out.Start, out.End = gcal.EventTime{Date: start}, gcal.EventTime{Date: end}
		return out
	}
	tz := e.TimeZone
	if tz == "" {
		tz = store.CalendarUTC
	}
	out.Start = gcal.EventTime{DateTime: e.StartsAt.UTC(), TimeZone: tz}
	out.End = gcal.EventTime{DateTime: e.EndsAt.UTC(), TimeZone: tz}
	return out
}
