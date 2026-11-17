package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// spec 180 FR-4, FR-5: ImportCalendarBySourceKey on Memory and Postgres, one
// test for both. Per driver, with a window [day 0, day 14):
//   - first import of 3 keys: 3 created, private, owner and mention set.
//   - CONTROL the same batch again: 3 unchanged, updated_at unchanged.
//   - a moved meeting (its key changes): 1 created, the old row deleted
//     (deleted_by = the importer), the other two unchanged.
//   - a row outside the window is never pruned; another owner's prefix is
//     never pruned; a roadmap goal: row is never pruned.
//   - a key back: its row comes back, same id.
//   - CONTROL refused, nothing written: a key of another owner's prefix, a
//     bad prefix, from after to; a roadmap sync with an outlook: key.

var impT0 = time.Date(2026, 11, 17, 22, 0, 0, 0, time.UTC)

func impEv(key, title string, start time.Time) CalendarSyncEvent {
	return CalendarSyncEvent{SourceKey: key, Event: CalendarEvent{Title: title, Kind: "other",
		Description: "Imported from Outlook", Audience: CalendarPrivate, Mentions: []string{"HUM-10"},
		OwnerID: "HUM-10", StartsAt: start, EndsAt: start.Add(30 * time.Minute), CreatorType: "system",
		CreatorID: "outlook-import", Props: map[string]any{"location": "Room 1"}}}
}

func impWin(prefix string) CalendarImportWindow {
	return CalendarImportWindow{Prefix: prefix, From: impT0, To: impT0.Add(14 * 24 * time.Hour), By: "outlook-import"}
}

func TestCalendarImportBySourceKey(t *testing.T) {
	ctx := context.Background()
	const pre = "outlook:HUM-10:"
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal, imp := st.(Calendar), st.(CalendarImport)
			tid := newTenant(t, st)
			list := func() map[string]CalendarEvent {
				t.Helper()
				evs, err := cal.ListCalendarEvents(ctx, tid, "HUM-10",
					CalendarRange{Start: impT0.Add(-30 * 24 * time.Hour), End: impT0.Add(60 * 24 * time.Hour)})
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]CalendarEvent{}
				for _, e := range evs {
					out[e.Title] = e
				}
				return out
			}
			run := func(what string, win CalendarImportWindow, b []CalendarSyncEvent, at time.Time, want CalendarSyncResult) {
				t.Helper()
				got, err := imp.ImportCalendarBySourceKey(ctx, tid, win, b, at)
				if err != nil || got != want {
					t.Fatalf("%s: %+v %v, want %+v", what, got, err, want)
				}
			}
			a := impEv(pre+"aaa", "standup", impT0.Add(9*time.Hour))
			b := impEv(pre+"bbb", "review", impT0.Add(30*time.Hour))
			c := impEv(pre+"ccc", "retro", impT0.Add(50*time.Hour))
			far := impEv(pre+"far", "far out", impT0.Add(20*24*time.Hour))
			other := impEv("outlook:HUM-11:zzz", "theirs", impT0.Add(10*time.Hour))
			other.Event.OwnerID, other.Event.Mentions = "HUM-11", []string{"HUM-10", "HUM-11"}

			run("far, outside the window", CalendarImportWindow{Prefix: pre, From: impT0.Add(15 * 24 * time.Hour),
				To: impT0.Add(25 * 24 * time.Hour), By: "outlook-import"}, []CalendarSyncEvent{far}, impT0, CalendarSyncResult{Created: 1})
			run("another owner", impWin("outlook:HUM-11:"), []CalendarSyncEvent{other}, impT0, CalendarSyncResult{Created: 1})
			if _, err := st.(CalendarSync).UpsertCalendarBySourceKey(ctx, tid,
				[]CalendarSyncEvent{syncEv("goal:G01:deadline", "G01 deadline", "goal", CalendarWorkspace)}, impT0); err != nil {
				t.Fatal(err)
			}

			run("first import", impWin(pre), []CalendarSyncEvent{a, b, c}, impT0, CalendarSyncResult{Created: 3})
			first := list()
			if e := first["standup"]; e.Audience != CalendarPrivate || e.OwnerID != "HUM-10" || e.SourceKey != pre+"aaa" ||
				len(e.Mentions) != 1 || e.Props["location"] != "Room 1" {
				t.Fatalf("first import stored %+v", e)
			}
			run("control: same batch", impWin(pre), []CalendarSyncEvent{a, b, c}, impT0.Add(time.Hour), CalendarSyncResult{Unchanged: 3})
			for title, e := range list() {
				if e.ID != first[title].ID || !e.UpdatedAt.Equal(first[title].UpdatedAt) {
					t.Fatalf("control: a re-run rewrote %q", title)
				}
			}

			moved := impEv(pre+"aab", "standup", impT0.Add(11*time.Hour))
			run("moved", impWin(pre), []CalendarSyncEvent{moved, b, c}, impT0.Add(2*time.Hour),
				CalendarSyncResult{Created: 1, Unchanged: 2, Deleted: 1})
			got := list()
			if got["standup"].ID == first["standup"].ID || !got["standup"].StartsAt.Equal(moved.Event.StartsAt) {
				t.Fatalf("moved: %+v", got["standup"])
			}
			if got["far out"].ID == "" || got["theirs"].ID == "" || got["G01 deadline"].ID == "" {
				t.Fatalf("a prune left its prefix or window: %+v", got)
			}

			run("cancelled", impWin(pre), []CalendarSyncEvent{moved, c}, impT0.Add(3*time.Hour),
				CalendarSyncResult{Unchanged: 2, Deleted: 1})
			run("a key back", impWin(pre), []CalendarSyncEvent{moved, b, c}, impT0.Add(4*time.Hour),
				CalendarSyncResult{Updated: 1, Unchanged: 2})
			if e := list()["review"]; e.ID != first["review"].ID || !e.DeletedAt.IsZero() {
				t.Fatalf("a key back is not the same row: %+v", e)
			}
			before := len(list())

			for what, call := range map[string]func() error{
				"control: another owner's key": func() error {
					_, err := imp.ImportCalendarBySourceKey(ctx, tid, impWin(pre), []CalendarSyncEvent{a, other}, impT0)
					return err
				},
				"a bad prefix": func() error {
					_, err := imp.ImportCalendarBySourceKey(ctx, tid, impWin("goal:"), []CalendarSyncEvent{a}, impT0)
					return err
				},
				"from after to": func() error {
					w := impWin(pre)
					w.From, w.To = w.To, w.From
					_, err := imp.ImportCalendarBySourceKey(ctx, tid, w, []CalendarSyncEvent{a}, impT0)
					return err
				},
				"a roadmap sync with an outlook: key": func() error {
					_, err := st.(CalendarSync).UpsertCalendarBySourceKey(ctx, tid, []CalendarSyncEvent{a}, impT0)
					return err
				},
			} {
				if err := call(); !errors.Is(err, ErrInvalidCalendarEvent) {
					t.Fatalf("%s: %v, want ErrInvalidCalendarEvent", what, err)
				}
			}
			if got := len(list()); got != before {
				t.Fatalf("a refused import wrote rows: %d -> %d", before, got)
			}
		})
	}
}
