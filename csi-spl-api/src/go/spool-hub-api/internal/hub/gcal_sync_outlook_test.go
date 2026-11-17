package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// spec 180 FR-7: an imported outlook: row goes out to the owner's Google
// Calendar like any of their events (spec 149 2.5): one cycle inserts it
// private and stores its map row. The gcal: skip of the push is not widened.
// CONTROL: another owner's outlook: row (not naming this member) never
// reaches this member's calendar. Memory, and Postgres under SPOOL_TEST_PG_DSN.
func TestGcalSyncPushesOutlookImport(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	now := se.clock.now()
	row := func(owner, key, title string) store.CalendarSyncEvent {
		return store.CalendarSyncEvent{SourceKey: key, Event: store.CalendarEvent{Title: title, Kind: "other",
			Description: "Imported from Outlook", Audience: store.CalendarPrivate, Mentions: []string{owner},
			OwnerID: owner, CreatorType: "system", CreatorID: "outlook-import",
			StartsAt: now.Add(24 * time.Hour), EndsAt: now.Add(25 * time.Hour)}}
	}
	win := func(owner string) store.CalendarImportWindow {
		return store.CalendarImportWindow{Prefix: "outlook:" + owner + ":", From: now, To: now.Add(14 * 24 * time.Hour), By: "outlook-import"}
	}
	imp := se.st.(store.CalendarImport)
	if _, err := imp.ImportCalendarBySourceKey(context.Background(), se.tid, win(hum),
		[]store.CalendarSyncEvent{row(hum, "outlook:"+hum+":0123456789abcdef01234567", "Planning")}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := imp.ImportCalendarBySourceKey(context.Background(), se.tid, win("HUM-99998"),
		[]store.CalendarSyncEvent{row("HUM-99998", "outlook:HUM-99998:0123456789abcdef01234567", "Not hers")}, now); err != nil {
		t.Fatal(err)
	}
	se.cycle(t)
	cal := se.conn(t, hum).CalendarID
	if got := se.fake.Events(cal); len(got) != 1 || got[0].Summary != "Planning" || got[0].Visibility != "private" {
		t.Fatalf("google events after the import: %+v, want only Planning, private", got)
	}
	if m := se.maps(t, hum); len(m) != 1 || m[0].GoogleID == "" {
		t.Fatalf("map rows after the import: %+v, want one", m)
	}
}
