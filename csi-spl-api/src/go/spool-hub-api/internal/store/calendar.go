package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"time"
	"unicode/utf8"
)

// The calendar section (specs/089, T003; rdb 0125 calendar_events and
// official_days). RLS holds the workspace only: the hub sets no per-viewer
// setting, so every read here also applies the private filter
//
//	audience <> 'private' OR creator_id = viewer OR viewer = ANY (mentions)
//
// (spec 089 section 5). Writes go through the same filter: a viewer who
// cannot read a private event cannot change or delete it either (it is
// ErrNotFound to them). Who may set audience to or from private (owner only,
// FR-010) and dropping internal events for a guest are the hub's (T004).
// The hub may roll before 0125 reaches its database: reads then answer
// empty and writes ErrCalendarUnavailable, never a 500.

// Calendar audiences (rdb 0125 check). An empty audience on create is public
// (owner decision D2).
const (
	CalendarPublic   = "public"
	CalendarInternal = "internal"
	CalendarPrivate  = "private"
)

// calendarKinds is rdb 0125's kind check.
var calendarKinds = []string{"release", "deploy", "maintenance", "freeze", "agent_task", "reminder", "other"}

// calendarRelease is rdb 0125's release_version check.
var calendarRelease = regexp.MustCompile(`^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$`)

// ErrInvalidCalendarEvent refuses a row rdb 0125's checks would refuse, before
// it reaches the database (HTTP 400).
var ErrInvalidCalendarEvent = errors.New("invalid calendar event")

// ErrCalendarUnavailable: this database has no calendar_events table yet
// (rdb 0125). HTTP 503.
var ErrCalendarUnavailable = errors.New("store: the calendar needs rdb 0125")

// CalendarEvent is one calendar_events row. A zero RemindAt is no reminder;
// "" TopicID / ReleaseVersion are NULL.
type CalendarEvent struct {
	ID             string
	Title          string
	Description    string
	Kind           string
	StartsAt       time.Time
	EndsAt         time.Time
	AllDay         bool
	Audience       string
	Mentions       []string // human UUIDs and agent ids named with @
	CreatorType    string   // human | agent | system
	CreatorID      string
	RemindAt       time.Time
	TopicID        string
	ReleaseVersion string
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// CalendarPatch is an update: a nil field is left as it is. A zero *RemindAt
// clears the reminder; an empty *TopicID / *ReleaseVersion clears that column.
type CalendarPatch struct {
	Title          *string
	Description    *string
	Kind           *string
	StartsAt       *time.Time
	EndsAt         *time.Time
	AllDay         *bool
	Audience       *string
	Mentions       *[]string
	RemindAt       *time.Time
	TopicID        *string
	ReleaseVersion *string
}

// CalendarMark is one UTC day of the year strip with events the viewer can
// read: how many cover it and their kinds, sorted.
type CalendarMark struct {
	Day   string // YYYY-MM-DD
	Count int
	Kinds []string
}

// OfficialDay is one official_days row: a region's public holiday.
type OfficialDay struct {
	Region string
	Day    string // YYYY-MM-DD
	Title  string
}

// CalendarRange bounds a read: [Start, End). A range read answers the events
// that overlap it (starts before End, ends at or after Start).
type CalendarRange struct {
	Start, End time.Time
}

// Calendar is the calendar section's store. viewer is the reading member's
// human UUID or the agent id, the creator_id / mentions value it matches.
type Calendar interface {
	CreateCalendarEvent(ctx context.Context, tenant string, e CalendarEvent, now time.Time) (CalendarEvent, error)
	GetCalendarEvent(ctx context.Context, tenant, viewer, id string) (CalendarEvent, error)
	UpdateCalendarEvent(ctx context.Context, tenant, viewer, id string, p CalendarPatch, now time.Time) (CalendarEvent, error)
	DeleteCalendarEvent(ctx context.Context, tenant, viewer, id string) error
	// ListCalendarEvents answers the overlapping events, by start then id.
	ListCalendarEvents(ctx context.Context, tenant, viewer string, r CalendarRange) ([]CalendarEvent, error)
	// CalendarMarks answers the days in r that have an event, oldest first.
	CalendarMarks(ctx context.Context, tenant, viewer string, r CalendarRange) ([]CalendarMark, error)
	// CalendarReminders answers the events the viewer owns or is mentioned
	// on whose remind_at is in r, by remind_at. A public event of someone
	// else reminds nobody but its creator and its mentions (D4).
	CalendarReminders(ctx context.Context, tenant, viewer string, r CalendarRange) ([]CalendarEvent, error)
	// OfficialDays answers region's days in r (shared reference, no tenant).
	OfficialDays(ctx context.Context, region string, r CalendarRange) ([]OfficialDay, error)
}

var (
	_ Calendar = (*Memory)(nil)
	_ Calendar = (*Postgres)(nil)
)

// calendarMaxEvents caps one range or reminder read.
const calendarMaxEvents = 2000

// normalizeCalendarEvent fills the defaults and applies rdb 0125's checks.
func normalizeCalendarEvent(e *CalendarEvent) error {
	if e.Audience == "" {
		e.Audience = CalendarPublic
	}
	if e.Mentions == nil {
		e.Mentions = []string{}
	}
	e.StartsAt, e.EndsAt = e.StartsAt.UTC(), e.EndsAt.UTC()
	if !e.RemindAt.IsZero() {
		e.RemindAt = e.RemindAt.UTC()
	}
	return validateCalendarEvent(e)
}

func validateCalendarEvent(e *CalendarEvent) error {
	bad := func(what string) error { return fmt.Errorf("%w: %s", ErrInvalidCalendarEvent, what) }
	switch {
	case utf8.RuneCountInString(e.Title) < 1 || utf8.RuneCountInString(e.Title) > 200:
		return bad("title must be 1..200 characters")
	case utf8.RuneCountInString(e.Description) > 4000:
		return bad("description must be at most 4000 characters")
	case !slices.Contains(calendarKinds, e.Kind):
		return bad("unknown kind")
	case e.Audience != CalendarPublic && e.Audience != CalendarInternal && e.Audience != CalendarPrivate:
		return bad("audience must be public, internal or private")
	case e.CreatorType != "human" && e.CreatorType != "agent" && e.CreatorType != "system":
		return bad("creator_type must be human, agent or system")
	case e.CreatorID == "" || utf8.RuneCountInString(e.CreatorID) > 64:
		return bad("creator_id must be 1..64 characters")
	case e.StartsAt.IsZero() || e.EndsAt.Before(e.StartsAt):
		return bad("ends_at must not be before starts_at")
	case e.ReleaseVersion != "" && !calendarRelease.MatchString(e.ReleaseVersion):
		return bad("release_version must be v<X.Y.Z>")
	}
	return nil
}

// applyCalendarPatch writes p's set fields onto e.
func applyCalendarPatch(e *CalendarEvent, p CalendarPatch) {
	set := func(dst *string, src *string) {
		if src != nil {
			*dst = *src
		}
	}
	set(&e.Title, p.Title)
	set(&e.Description, p.Description)
	set(&e.Kind, p.Kind)
	set(&e.Audience, p.Audience)
	set(&e.TopicID, p.TopicID)
	set(&e.ReleaseVersion, p.ReleaseVersion)
	if p.StartsAt != nil {
		e.StartsAt = *p.StartsAt
	}
	if p.EndsAt != nil {
		e.EndsAt = *p.EndsAt
	}
	if p.AllDay != nil {
		e.AllDay = *p.AllDay
	}
	if p.Mentions != nil {
		e.Mentions = slices.Clone(*p.Mentions)
	}
	if p.RemindAt != nil {
		e.RemindAt = *p.RemindAt
	}
}

// calendarOwnsOrNamed: the viewer created the event or is mentioned on it.
func calendarOwnsOrNamed(e *CalendarEvent, viewer string) bool {
	return viewer != "" && (e.CreatorID == viewer || slices.Contains(e.Mentions, viewer))
}

// calendarVisible is the private filter (spec 089 section 5).
func calendarVisible(e *CalendarEvent, viewer string) bool {
	return e.Audience != CalendarPrivate || calendarOwnsOrNamed(e, viewer)
}

// calendarOverlaps: e starts before r.End and ends at or after r.Start.
func calendarOverlaps(e *CalendarEvent, r CalendarRange) bool {
	return e.StartsAt.Before(r.End) && !e.EndsAt.Before(r.Start)
}

// calendarDays lists the UTC days e covers inside r. An event that ends
// exactly at midnight (an all-day event to the next day) does not cover
// the day it ends on, unless it starts there too.
func calendarDays(e *CalendarEvent, r CalendarRange) []string {
	last := e.EndsAt
	if last.After(e.StartsAt) {
		last = last.Add(-time.Microsecond)
	}
	if !last.Before(r.End) {
		last = r.End.Add(-time.Microsecond)
	}
	d := e.StartsAt
	if d.Before(r.Start) {
		d = r.Start
	}
	d = d.UTC().Truncate(24 * time.Hour)
	var out []string
	for ; !d.After(last); d = d.Add(24 * time.Hour) {
		out = append(out, d.Format(time.DateOnly))
	}
	return out
}
