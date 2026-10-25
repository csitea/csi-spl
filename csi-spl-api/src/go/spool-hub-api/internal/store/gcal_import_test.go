package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Spec 149 B6b / SPL-3339: the store side of the Google -> Spool half
// (GcalImport), on Memory and on Postgres (SPOOL_TEST_PG_DSN). An imported
// event is upserted by its gcal:<connection>:<google id> key: once, never a
// duplicate; unchanged keeps updated_at; a trashed one comes back with the
// same id; the member's private event, so another member does not read it.

func gcalImportEvent(human, title string, at time.Time) CalendarEvent {
	return CalendarEvent{Title: title, Kind: "other", Audience: CalendarPrivate, CreatorType: "human", CreatorID: human,
		StartsAt: at.Add(time.Hour), EndsAt: at.Add(2 * time.Hour)}
}

func TestGcalImportUpsert(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			f := newGcalFix(t, st)
			c := f.connect(t, f.m1, "m1@example.com")
			imp, cal := st.(GcalImport), st.(Calendar)
			key := "gcal:" + c.ID + ":ev1"
			in := gcalImportEvent(f.m1, "From Google", f.now)
			in.RRule = "FREQ=WEEKLY;COUNT=3"
			first, err := imp.PutGcalImported(ctx, f.tenant, key, in, f.now)
			if err != nil {
				t.Fatal(err)
			}
			if first.SourceKey != key || first.Audience != CalendarPrivate || first.CreatorID != f.m1 || first.RRule != in.RRule {
				t.Fatalf("imported %+v", first)
			}
			again, err := imp.PutGcalImported(ctx, f.tenant, key, in, f.now.Add(time.Minute))
			if err != nil || again.ID != first.ID || !again.UpdatedAt.Equal(first.UpdatedAt) {
				t.Fatalf("the same item again: %v, id %s (want %s), updated %v (want %v)", err, again.ID, first.ID, again.UpdatedAt, first.UpdatedAt)
			}
			in.Title = "From Google, moved"
			later := f.now.Add(2 * time.Minute)
			moved, err := imp.PutGcalImported(ctx, f.tenant, key, in, later)
			if err != nil || moved.ID != first.ID || moved.Title != in.Title || !moved.UpdatedAt.Equal(calendarNow(later)) {
				t.Fatalf("an edit: %v, %+v", err, moved)
			}
			if _, err := cal.TrashCalendarEvent(ctx, f.tenant, f.m1, first.ID, time.Time{}, later); err != nil {
				t.Fatal(err)
			}
			back, err := imp.PutGcalImported(ctx, f.tenant, key, in, later.Add(time.Minute))
			if err != nil || back.ID != first.ID || !back.DeletedAt.IsZero() {
				t.Fatalf("a trashed import back: %v, %+v", err, back)
			}
			if got, err := cal.GetCalendarEvent(ctx, f.tenant, f.m1, first.ID); err != nil || got.SourceKey != key {
				t.Fatalf("the member reads %+v, %v", got, err)
			}
			if _, err := cal.GetCalendarEvent(ctx, f.tenant, f.m2, first.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another member reads the import: %v, want ErrNotFound", err)
			}
			if _, err := imp.PutGcalImported(ctx, f.tenant, key, gcalImportEvent(f.m2, "hijack", f.now), later); !errors.Is(err, ErrConflict) {
				t.Fatalf("another creator on the key: %v, want ErrConflict", err)
			}
		})
	}
}

// The key family and the event shape are checked before anything is written.
func TestGcalImportRefuses(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			f := newGcalFix(t, st)
			c := f.connect(t, f.m1, "m1@example.com")
			imp := st.(GcalImport)
			ok := gcalImportEvent(f.m1, "x", f.now)
			public := ok
			public.Audience = CalendarWorkspace
			guest := ok
			guest.Mentions = []string{f.m2}
			for _, tc := range []struct {
				name, key string
				e         CalendarEvent
			}{
				{"goal family", "goal:G01:" + c.ID, ok},
				{"no connection uuid", "gcal:conn:ev1", ok},
				{"no google id", "gcal:" + c.ID + ":", ok},
				{"not private", "gcal:" + c.ID + ":ev1", public},
				{"mentions", "gcal:" + c.ID + ":ev1", guest},
			} {
				if _, err := imp.PutGcalImported(ctx, f.tenant, tc.key, tc.e, f.now); !errors.Is(err, ErrInvalidCalendarEvent) {
					t.Errorf("%s: %v, want ErrInvalidCalendarEvent", tc.name, err)
				}
			}
		})
	}
}
