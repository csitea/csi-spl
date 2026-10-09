package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// specs/112 STORE-1: UpsertCalendarBySourceKey on Memory and Postgres, one
// test for both (parity). Per driver:
//   - first sync of 4 keys: 4 created, kinds goal and milestone stored.
//   - CONTROL re-run of the same batch: 4 unchanged, nothing rewritten, the
//     visible row count still 4, updated_at unchanged.
//   - a changed title: 1 updated, same id.
//   - a batch without goal:G01:m:a and spec:089:done: both soft-deleted,
//     release: and db: kept; the key back brings its row back, same id.
//   - CONTROL refused, nothing written: a db: key with audience public, a
//     db: key with no audience, an unknown prefix, a key twice in a batch.
//   - workspace B does not see A's synced events.

var syncT0 = time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)

func syncEv(key, title, kind, audience string) CalendarSyncEvent {
	return CalendarSyncEvent{SourceKey: key, Event: CalendarEvent{Title: title, Kind: kind, Audience: audience,
		StartsAt: syncT0, EndsAt: syncT0.Add(24 * time.Hour), AllDay: true, CreatorType: "system", CreatorID: "roadmap-sync",
		Props: map[string]any{"roadmap_url": "/roadmap?goal=G01"}}}
}

func syncBatch() []CalendarSyncEvent {
	db := syncEv("db:t-0001", "Owner go", "milestone", CalendarInternal)
	db.Event.TopicID = "t-0001"
	return []CalendarSyncEvent{
		syncEv("goal:G01:deadline", "G01 deadline", "goal", CalendarWorkspace),
		syncEv("goal:G01:m:a", "G01 milestone a", "milestone", CalendarWorkspace),
		syncEv("spec:089:done", "spec 089 done", "milestone", CalendarWorkspace),
		db,
	}
}

func syncRange() CalendarRange {
	return CalendarRange{Start: syncT0.Add(-24 * time.Hour), End: syncT0.Add(48 * time.Hour)}
}

func TestCalendarSyncBySourceKey(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal, sync := st.(Calendar), st.(CalendarSync)
			tid, other := newTenant(t, st), newTenant(t, st)
			list := func(tenant string) map[string]CalendarEvent {
				t.Helper()
				evs, err := cal.ListCalendarEvents(ctx, tenant, "", syncRange())
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]CalendarEvent{}
				for _, e := range evs {
					out[e.Title] = e
				}
				return out
			}
			run := func(what string, b []CalendarSyncEvent, at time.Time, want CalendarSyncResult) {
				t.Helper()
				got, err := sync.UpsertCalendarBySourceKey(ctx, tid, b, at)
				if err != nil || got != want {
					t.Fatalf("%s: %+v %v, want %+v", what, got, err, want)
				}
			}

			run("first sync", syncBatch(), syncT0, CalendarSyncResult{Created: 4})
			first := list(tid)
			if len(first) != 4 || first["G01 deadline"].Kind != "goal" || first["Owner go"].Audience != CalendarInternal ||
				first["Owner go"].TopicID != "t-0001" || first["G01 deadline"].Props["roadmap_url"] != "/roadmap?goal=G01" {
				t.Fatalf("first sync stored %+v", first)
			}

			run("control: same batch again", syncBatch(), syncT0.Add(time.Hour), CalendarSyncResult{Unchanged: 4})
			again := list(tid)
			if len(again) != len(first) {
				t.Fatalf("control: a re-run changed the row count %d -> %d", len(first), len(again))
			}
			for title, e := range again {
				if e.ID != first[title].ID || !e.UpdatedAt.Equal(first[title].UpdatedAt) {
					t.Fatalf("control: a re-run rewrote %q: %+v", title, e)
				}
			}

			b := syncBatch()
			b[0].Event.Title = "G01 deadline moved"
			run("a changed title", b, syncT0.Add(2*time.Hour), CalendarSyncResult{Updated: 1, Unchanged: 3})
			if got := list(tid)["G01 deadline moved"]; got.ID != first["G01 deadline"].ID {
				t.Fatalf("an update is not in place: %+v", got)
			}

			keep := []CalendarSyncEvent{b[0], b[3]}
			run("prune", keep, syncT0.Add(3*time.Hour), CalendarSyncResult{Unchanged: 2, Deleted: 2})
			if got := list(tid); len(got) != 2 || got["Owner go"].ID == "" {
				t.Fatalf("prune left %+v", got)
			}
			run("prune again", keep, syncT0.Add(4*time.Hour), CalendarSyncResult{Unchanged: 2})
			run("release and db keys are never pruned", []CalendarSyncEvent{b[0], syncEv("release:v1.3.0", "v1.3.0", "release", CalendarWorkspace)},
				syncT0.Add(5*time.Hour), CalendarSyncResult{Created: 1, Unchanged: 1})
			if got := list(tid); len(got) != 3 || got["Owner go"].ID == "" {
				t.Fatalf("a release sync pruned a db: key: %+v", got)
			}
			run("a key back", append(keep, b[1]), syncT0.Add(6*time.Hour), CalendarSyncResult{Updated: 1, Unchanged: 2})
			if got := list(tid)["G01 milestone a"]; got.ID != first["G01 milestone a"].ID || !got.DeletedAt.IsZero() {
				t.Fatalf("a key back is not the same row: %+v", got)
			}
			before := len(list(tid))

			pub := syncEv("db:t-0002", "leak", "milestone", CalendarWorkspace)
			none := syncEv("db:t-0003", "leak", "milestone", "")
			twice := syncEv("goal:G02:deadline", "twice", "goal", CalendarWorkspace)
			for what, bad := range map[string][]CalendarSyncEvent{
				"control: a db: key with audience public": {b[0], pub},
				"a db: key with no audience":              {none},
				"an unknown prefix":                       {syncEv("git:v1.2.0", "x", "release", CalendarWorkspace)},
				"a key twice in one batch":                {twice, twice},
				"a kind outside the nine":                 {syncEv("goal:G03:deadline", "x", "roadmap", CalendarWorkspace)},
			} {
				if _, err := sync.UpsertCalendarBySourceKey(ctx, tid, bad, syncT0.Add(7*time.Hour)); !errors.Is(err, ErrInvalidCalendarEvent) {
					t.Fatalf("%s: %v, want ErrInvalidCalendarEvent", what, err)
				}
			}
			if got := list(tid); len(got) != before || got["leak"].ID != "" {
				t.Fatalf("a refused batch wrote rows: %+v", got)
			}
			if got := list(other); len(got) != 0 {
				t.Fatalf("workspace B reads A's synced events: %+v", got)
			}
		})
	}
}
