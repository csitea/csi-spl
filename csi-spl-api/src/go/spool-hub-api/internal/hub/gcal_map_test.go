package hub_test

import (
	"regexp"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 149 B6a (SPL-3226): the Spool -> Google mapping and the sync hash of
// section 2.5. Pure functions, no store and no Google.

func gcalMapEvent() store.CalendarEvent {
	at := time.Date(2026, 3, 2, 9, 30, 0, 0, time.UTC)
	return store.CalendarEvent{ID: "8d0c5c3e-1b2a-4c3d-9e8f-0a1b2c3d4e5f", Title: "Planning", Description: "the plan",
		StartsAt: at, EndsAt: at.Add(time.Hour), TimeZone: "Europe/Helsinki", Audience: store.CalendarWorkspace,
		Kind: "other", Status: store.CalendarConfirmed}
}

// The hash is 64 hex digits, one instant hashes the same in any zone, the
// store's defaults ("" time zone, "" status) hash as what it fills, and each
// of the eight fields changes it; a field outside the list does not.
func TestGcalSyncHash(t *testing.T) {
	base := gcalMapEvent()
	h := hub.GcalSyncHash(base)
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(h) {
		t.Fatalf("hash %q is not 64 hex digits", h)
	}
	zoned := base
	hel := time.FixedZone("EET", 2*3600)
	zoned.StartsAt, zoned.EndsAt = base.StartsAt.In(hel), base.EndsAt.In(hel)
	if hub.GcalSyncHash(zoned) != h {
		t.Fatal("the same instants in another zone hash differently")
	}
	utc, filled := base, base
	utc.TimeZone, utc.Status = "", ""
	filled.TimeZone, filled.Status = store.CalendarUTC, store.CalendarConfirmed
	if hub.GcalSyncHash(utc) != hub.GcalSyncHash(filled) {
		t.Fatal(`"" time zone / status hash unlike UTC / confirmed`)
	}
	edits := map[string]func(*store.CalendarEvent){
		"title":       func(e *store.CalendarEvent) { e.Title += "!" },
		"description": func(e *store.CalendarEvent) { e.Description += "!" },
		"starts_at":   func(e *store.CalendarEvent) { e.StartsAt = e.StartsAt.Add(time.Minute) },
		"ends_at":     func(e *store.CalendarEvent) { e.EndsAt = e.EndsAt.Add(time.Minute) },
		"all_day":     func(e *store.CalendarEvent) { e.AllDay = true },
		"time_zone":   func(e *store.CalendarEvent) { e.TimeZone = "UTC" },
		"rrule":       func(e *store.CalendarEvent) { e.RRule = "FREQ=DAILY" },
		"status":      func(e *store.CalendarEvent) { e.Status = store.CalendarCancelled },
	}
	for name, edit := range edits {
		e := base
		edit(&e)
		if hub.GcalSyncHash(e) == h {
			t.Errorf("an edit of %s keeps the hash", name)
		}
	}
	other := base
	other.Kind, other.Audience, other.UpdatedAt = "goal", store.CalendarPrivate, time.Now()
	if hub.GcalSyncHash(other) != h {
		t.Fatal("kind, audience or updated_at changed the hash: they are not in section 2.5's list")
	}
}

// A timed event: summary, description, start and end with its zone,
// visibility default for a workspace event, private for a private one.
func TestGcalEventOfTimed(t *testing.T) {
	e := gcalMapEvent()
	g := hub.GcalEventOf(e)
	if g.Summary != "Planning" || g.Description != "the plan" || g.Status != "confirmed" || g.Visibility != "default" {
		t.Fatalf("mapped %+v", g)
	}
	if !g.Start.DateTime.Equal(e.StartsAt) || !g.End.DateTime.Equal(e.EndsAt) || g.Start.TimeZone != "Europe/Helsinki" ||
		g.End.TimeZone != "Europe/Helsinki" || g.Start.Date != "" {
		t.Fatalf("times %+v / %+v", g.Start, g.End)
	}
	if len(g.Recurrence) != 0 {
		t.Fatalf("a single event has recurrence %v", g.Recurrence)
	}
	e.Audience, e.TimeZone = store.CalendarPrivate, ""
	if g := hub.GcalEventOf(e); g.Visibility != "private" || g.Start.TimeZone != "UTC" {
		t.Fatalf("private, no zone: visibility %q zone %q", g.Visibility, g.Start.TimeZone)
	}
}

// An all-day event goes as dates with Google's exclusive end; one that ends
// on its start day still covers one day. A series goes with one RRULE line.
func TestGcalEventOfAllDayAndSeries(t *testing.T) {
	e := gcalMapEvent()
	e.AllDay = true
	e.StartsAt = time.Date(2026, 3, 2, 0, 0, 0, 0, time.UTC)
	e.EndsAt = time.Date(2026, 3, 4, 0, 0, 0, 0, time.UTC)
	g := hub.GcalEventOf(e)
	if g.Start.Date != "2026-03-02" || g.End.Date != "2026-03-04" || !g.Start.DateTime.IsZero() {
		t.Fatalf("all-day %+v / %+v", g.Start, g.End)
	}
	e.EndsAt = time.Date(2026, 3, 2, 23, 59, 0, 0, time.UTC)
	if g := hub.GcalEventOf(e); g.End.Date != "2026-03-03" {
		t.Fatalf("all-day ending on its start day: end %q, want 2026-03-03", g.End.Date)
	}
	e = gcalMapEvent()
	for _, rule := range []string{"FREQ=WEEKLY;COUNT=4", "RRULE:FREQ=WEEKLY;COUNT=4"} {
		e.RRule = rule
		if g := hub.GcalEventOf(e); !slices.Equal(g.Recurrence, []string{"RRULE:FREQ=WEEKLY;COUNT=4"}) {
			t.Fatalf("rrule %q -> %v", rule, g.Recurrence)
		}
	}
}
