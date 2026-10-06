package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/097 T009 (spec 4.7): the search on Memory and Postgres. Text matches
// title, description and location; kind, audience and guest filter; the
// private filter and deleted_at apply; the cursor pages without a repeat or
// a gap; AC-08: workspace B finds none of A's events.

// calSearchSeed stores the search fixture in a fresh workspace and answers it.
func calSearchSeed(t *testing.T, st Store) string {
	t.Helper()
	ctx, cal := context.Background(), st.(Calendar)
	tid := newTenant(t, st)
	add := func(title string, mut func(*CalendarEvent)) CalendarEvent {
		e := calEvent(title)
		if mut != nil {
			mut(&e)
		}
		out, err := cal.CreateCalendarEvent(ctx, tid, e, calT0)
		if err != nil {
			t.Fatalf("seed %s: %v", title, err)
		}
		return out
	}
	add("Ship v1.4", nil)
	add("Freeze", func(e *CalendarEvent) {
		e.Kind, e.Description, e.StartsAt, e.EndsAt = "freeze", "no SHIPping today", calT0.Add(24*time.Hour), calT0.Add(25*time.Hour)
	})
	add("Standup", func(e *CalendarEvent) {
		e.Kind, e.Props, e.StartsAt, e.EndsAt = "other", map[string]any{"location": "Ship room"}, calT0.Add(48*time.Hour), calT0.Add(49*time.Hour)
	})
	add("Secret ship", func(e *CalendarEvent) {
		e.Audience, e.Mentions, e.StartsAt, e.EndsAt = CalendarPrivate, []string{calAgent}, calT0.Add(72*time.Hour), calT0.Add(73*time.Hour)
	})
	add("Team ship", func(e *CalendarEvent) {
		e.Audience, e.CreatorID, e.StartsAt, e.EndsAt = CalendarInternal, calMember, calT0.Add(96*time.Hour), calT0.Add(97*time.Hour)
	})
	gone := add("Deleted ship", nil)
	if _, err := cal.TrashCalendarEvent(ctx, tid, calOwner, gone.ID, time.Time{}, calT0); err != nil {
		t.Fatal(err)
	}
	add("Far ship", func(e *CalendarEvent) { e.StartsAt, e.EndsAt = calT0.AddDate(2, 0, 0), calT0.AddDate(2, 0, 0) })
	return tid
}

func TestCalendarSearchFilters(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			srch := st.(CalendarSearch)
			tid := calSearchSeed(t, st)
			for _, c := range []struct {
				what, viewer, want string
				q                  CalendarQuery
			}{
				{"text in title, description, location", calOwner, "Ship v1.4,Freeze,Standup,Secret ship,Team ship", CalendarQuery{Text: "sHiP"}},
				{"no text: every live event", calMember, "Ship v1.4,Freeze,Standup,Team ship", CalendarQuery{}},
				{"private: a mentioned agent", calAgent, "Secret ship", CalendarQuery{Text: "secret"}},
				{"private: a member nobody names", calMember, "", CalendarQuery{Text: "secret"}},
				{"kind", calOwner, "Freeze,Standup", CalendarQuery{Kinds: []string{"freeze", "other"}}},
				{"audience", calOwner, "Secret ship,Team ship", CalendarQuery{Audiences: []string{CalendarPrivate, CalendarInternal}}},
				{"guest: mention", calOwner, "Secret ship", CalendarQuery{Guest: calAgent}},
				{"guest: creator", calOwner, "Team ship", CalendarQuery{Guest: calMember}},
				{"no match", calOwner, "", CalendarQuery{Text: "nothing like it"}},
				{"limit", calOwner, "Ship v1.4,Freeze", CalendarQuery{Limit: 2}},
			} {
				q := c.q
				q.Range = calWeek()
				evs, err := srch.SearchCalendarEvents(ctx, tid, c.viewer, q)
				if err != nil || calIDs(evs) != c.want {
					t.Fatalf("%s: got %q want %q (%v)", c.what, calIDs(evs), c.want, err)
				}
			}
			// CONTROL: the far event is there, only outside the week
			wide := CalendarRange{Start: calT0.AddDate(-1, 0, 0), End: calT0.AddDate(3, 0, 0)}
			if evs, _ := srch.SearchCalendarEvents(ctx, tid, calOwner, CalendarQuery{Text: "far", Range: wide}); calIDs(evs) != "Far ship" {
				t.Fatalf("CONTROL far event: %q", calIDs(evs))
			}
		})
	}
}

// The cursor (start, id) pages through events that share one start time
// without a repeat or a gap.
func TestCalendarSearchCursor(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal, srch := st.(Calendar), st.(CalendarSearch)
			tid := newTenant(t, st)
			for _, title := range []string{"a", "b", "c", "d", "e"} {
				if _, err := cal.CreateCalendarEvent(ctx, tid, calEvent(title), calT0); err != nil {
					t.Fatal(err)
				}
			}
			all, _ := srch.SearchCalendarEvents(ctx, tid, calOwner, CalendarQuery{Range: calWeek(), Limit: 10})
			seen := map[string]bool{}
			q := CalendarQuery{Range: calWeek(), Limit: 2}
			for page := 0; page < 4; page++ {
				evs, err := srch.SearchCalendarEvents(ctx, tid, calOwner, q)
				if err != nil {
					t.Fatal(err)
				}
				for _, e := range evs {
					if seen[e.ID] {
						t.Fatalf("page %d repeats %s", page, e.Title)
					}
					seen[e.ID] = true
				}
				if len(evs) == 0 {
					break
				}
				last := evs[len(evs)-1]
				q.AfterStart, q.AfterID = last.StartsAt, last.ID
			}
			if len(all) != 5 || len(seen) != 5 {
				t.Fatalf("paged %d of %d", len(seen), len(all))
			}
		})
	}
}

// AC-08: workspace B's search finds none of A's events, even as the same
// viewer and by guest.
func TestCalendarSearchCrossTenant(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			srch := st.(CalendarSearch)
			a := calSearchSeed(t, st)
			b := newTenant(t, st)
			for _, q := range []CalendarQuery{{}, {Text: "ship"}, {Guest: calOwner}, {Kinds: []string{"release"}}} {
				q.Range = calWeek()
				if evs, err := srch.SearchCalendarEvents(ctx, b, calOwner, q); err != nil || len(evs) != 0 {
					t.Fatalf("B finds A's events %+v: %q %v", q, calIDs(evs), err)
				}
				if evs, _ := srch.SearchCalendarEvents(ctx, a, calOwner, q); len(evs) == 0 {
					t.Fatalf("CONTROL: A finds its own events %+v", q)
				}
			}
			if _, err := srch.SearchCalendarEvents(ctx, "", calOwner, CalendarQuery{Range: calWeek()}); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v", err)
			}
		})
	}
}

// Postgres: a calendar_guests row makes its guest match (rdb 0139), and
// the probes answer empty or 089's shape, never an error.
func TestCalendarSearchPostgresGuestsAndProbes(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	e, err := pg.CreateCalendarEvent(ctx, tid, calEvent("Invited"), calT0)
	if err != nil {
		t.Fatal(err)
	}
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO calendar_guests (tenant_id, event_id, guest_type, guest_id, invited_by)
			VALUES ($1, $2::uuid, 'human', $3, $4)`, tid, e.ID, calMember, calOwner)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	q := CalendarQuery{Guest: calMember, Range: calWeek()}
	if evs, err := pg.SearchCalendarEvents(ctx, tid, calOwner, q); err != nil || calIDs(evs) != "Invited" {
		t.Fatalf("guest row: %q %v", calIDs(evs), err)
	}
	t.Cleanup(func() { pg.calEdit, pg.cal = seatsProbe{}, seatsProbe{} })
	pg.calEdit = seatsProbe{check: func(context.Context) (bool, error) { return false, nil }}
	if evs, err := pg.SearchCalendarEvents(ctx, tid, calOwner, CalendarQuery{Text: "invited", Range: calWeek()}); err != nil || len(evs) != 1 {
		t.Fatalf("without 0139: %q %v", calIDs(evs), err)
	}
	if evs, err := pg.SearchCalendarEvents(ctx, tid, calOwner, q); err != nil || len(evs) != 0 {
		t.Fatalf("without 0139 no guests table is read: %q %v", calIDs(evs), err)
	}
	pg.cal = seatsProbe{check: func(context.Context) (bool, error) { return false, nil }}
	if evs, err := pg.SearchCalendarEvents(ctx, tid, calOwner, CalendarQuery{Range: calWeek()}); err != nil || len(evs) != 0 {
		t.Fatalf("without 0125: %q %v", calIDs(evs), err)
	}
}
