package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/097 T006: recurrence on Memory and Postgres. AC-04 end to end, the
// following split, the scope refusals, the 2000-occurrence cap, and a
// cross-workspace occurrence id (spec 3.2) that writes nothing.

var calHelsinki = func() *time.Location {
	l, err := time.LoadLocation("Europe/Helsinki")
	if err != nil {
		panic(err)
	}
	return l
}()

// calAC04 is AC-04's series: Mon/Wed 09:00 Helsinki from Mon 2026-10-19,
// six times, across the 25 October daylight-saving change.
func calAC04() CalendarEvent {
	e := calEvent("standup")
	e.StartsAt = time.Date(2026, 10, 19, 9, 0, 0, 0, calHelsinki).UTC()
	e.EndsAt = e.StartsAt.Add(30 * time.Minute)
	e.TimeZone, e.RRule = "Europe/Helsinki", "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6"
	return e
}

func calAutumn() CalendarRange {
	return CalendarRange{Start: time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), End: time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC)}
}

// calLocal is the occurrences as "Jan 2 15:04 title" in Helsinki.
func calLocal(evs []CalendarEvent) string {
	var out []string
	for _, e := range evs {
		out = append(out, e.StartsAt.In(calHelsinki).Format("Jan 2 15:04 ")+e.Title)
	}
	return strings.Join(out, ", ")
}

func calList(t *testing.T, cal Calendar, tid string) []CalendarEvent {
	t.Helper()
	evs, err := cal.ListCalendarEvents(context.Background(), tid, calOwner, calAutumn())
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	return evs
}

func calPtr[T any](v T) *T { return &v }

func TestCalendarSeriesAC04(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			s, err := cal.CreateCalendarEvent(ctx, tid, calAC04(), calT0)
			if err != nil || s.RecurUntil.IsZero() || s.Status != CalendarConfirmed {
				t.Fatalf("create: %+v %v", s, err)
			}
			evs := calList(t, cal, tid)
			want := "Oct 19 09:00 standup, Oct 21 09:00 standup, Oct 26 09:00 standup, Oct 28 09:00 standup, " +
				"Nov 2 09:00 standup, Nov 4 09:00 standup"
			if got := calLocal(evs); got != want {
				t.Fatalf("six at 09:00 local:\n got %s\nwant %s", got, want)
			}
			if evs[2].ID != s.ID+"_20261026T070000Z" || evs[2].RecurringEventID != s.ID || evs[2].RRule != s.RRule {
				t.Fatalf("occurrence shape: %+v", evs[2])
			}

			// edit "this" moves one: Wed 21 to 11:00
			moved := time.Date(2026, 10, 21, 11, 0, 0, 0, calHelsinki)
			occ, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, evs[1].ID, CalendarPatch{StartsAt: &moved,
				EndsAt: calPtr(moved.Add(30 * time.Minute)), IfUpdatedAt: evs[1].UpdatedAt, Scope: CalendarScopeThis}, calT0)
			if err != nil || occ.ID != evs[1].ID || !occ.StartsAt.Equal(moved) {
				t.Fatalf("edit this: %+v %v", occ, err)
			}
			if got, err := cal.GetCalendarEvent(ctx, tid, calOwner, evs[1].ID); err != nil || !got.StartsAt.Equal(moved) {
				t.Fatalf("read the moved occurrence: %+v %v", got, err)
			}
			// delete "following" from the 4th leaves three
			if _, err := cal.TrashCalendarScope(ctx, tid, calOwner, evs[3].ID, CalendarScopeFollowing, time.Time{}, calT0); err != nil {
				t.Fatalf("delete following: %v", err)
			}
			if got := calLocal(calList(t, cal, tid)); got != "Oct 19 09:00 standup, Oct 21 11:00 standup, Oct 26 09:00 standup" {
				t.Fatalf("after delete following: %s", got)
			}
			// edit "all" from an occurrence: an hour later and renamed; the moved one stays moved
			later := evs[2].StartsAt.Add(time.Hour)
			if _, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, evs[2].ID, CalendarPatch{StartsAt: &later,
				EndsAt: calPtr(later.Add(30 * time.Minute)), Title: calPtr("sync"), Scope: CalendarScopeAll}, calT0); err != nil {
				t.Fatalf("edit all: %v", err)
			}
			if got := calLocal(calList(t, cal, tid)); got != "Oct 19 10:00 sync, Oct 21 11:00 sync, Oct 26 10:00 sync" {
				t.Fatalf("after edit all: %s", got)
			}
			// delete "this", then the same viewer restores it
			evs = calList(t, cal, tid)
			gone, err := cal.TrashCalendarEvent(ctx, tid, calOwner, evs[0].ID, evs[0].UpdatedAt, calT0)
			if err != nil || gone.DeletedAt.IsZero() || len(calList(t, cal, tid)) != 2 {
				t.Fatalf("delete this: %+v %v", gone, err)
			}
			if _, err := cal.RestoreCalendarEvent(ctx, tid, calMember, evs[0].ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another viewer restores: %v", err)
			}
			if _, err := cal.RestoreCalendarEvent(ctx, tid, calOwner, evs[0].ID); err != nil || len(calList(t, cal, tid)) != 3 {
				t.Fatalf("restore the occurrence: %v", err)
			}
			// delete "all" by the series id: the series is in the trash, nothing on the grid
			if _, err := cal.TrashCalendarEvent(ctx, tid, calOwner, s.ID, time.Time{}, calT0); err != nil || len(calList(t, cal, tid)) != 0 {
				t.Fatalf("delete all: %v", err)
			}
			if tr, err := cal.CalendarTrash(ctx, tid, calOwner, calT0.Add(-time.Hour)); err != nil || len(tr) != 1 || tr[0].ID != s.ID {
				t.Fatalf("trash holds the series only: %+v %v", tr, err)
			}
		})
	}
}

func TestCalendarSeriesFollowing(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			s, err := cal.CreateCalendarEvent(ctx, tid, calAC04(), calT0)
			if err != nil {
				t.Fatal(err)
			}
			evs := calList(t, cal, tid)
			// an exception after the split point, renamed only
			if _, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, evs[4].ID, CalendarPatch{Description: calPtr("own")}, calT0); err != nil {
				t.Fatal(err)
			}
			first, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, evs[2].ID, CalendarPatch{Title: calPtr("new"),
				Scope: CalendarScopeFollowing}, calT0)
			if err != nil || first.RecurringEventID == s.ID || first.RRule != "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4" {
				t.Fatalf("edit following: %+v %v", first, err)
			}
			got := calList(t, cal, tid)
			want := "Oct 19 09:00 standup, Oct 21 09:00 standup, Oct 26 09:00 new, Oct 28 09:00 new, Nov 2 09:00 new, Nov 4 09:00 new"
			if calLocal(got) != want {
				t.Fatalf("after following:\n got %s\nwant %s", calLocal(got), want)
			}
			if got[4].RecurringEventID != first.RecurringEventID || got[4].Description != "own" {
				t.Fatalf("the later exception moved to the new series with its own field: %+v", got[4])
			}
		})
	}
}

func TestCalendarSeriesRefusals(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			bad := calAC04()
			bad.RRule = "FREQ=HOURLY"
			if _, err := cal.CreateCalendarEvent(ctx, tid, bad, calT0); !errors.Is(err, ErrInvalidCalendarEvent) {
				t.Fatalf("a rule outside the subset: %v", err)
			}
			s, err := cal.CreateCalendarEvent(ctx, tid, calAC04(), calT0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, s.ID, CalendarPatch{Title: calPtr("x"),
				Scope: CalendarScopeThis}, calT0); !errors.Is(err, ErrInvalidCalendarEvent) {
				t.Fatalf("scope this on a series id: %v", err)
			}
			occ := s.ID + "_20261021T060000Z"
			if _, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, occ, CalendarPatch{RRule: calPtr("FREQ=DAILY")}, calT0); !errors.Is(err, ErrInvalidCalendarEvent) {
				t.Fatalf("an rrule on one occurrence: %v", err)
			}
			if _, err := cal.GetCalendarEvent(ctx, tid, calOwner, s.ID+"_20261022T060000Z"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a start the rule does not make: %v", err)
			}
			if _, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, occ, CalendarPatch{Title: calPtr("x"),
				IfUpdatedAt: calT0.Add(-time.Hour)}, calT0); !errors.Is(err, ErrEditConflict) {
				t.Fatalf("a stale If-Match on an occurrence: %v", err)
			}
			daily := calEvent("daily")
			daily.RRule = "FREQ=DAILY"
			if _, err := cal.CreateCalendarEvent(ctx, tid, daily, calT0); err != nil {
				t.Fatal(err)
			}
			long := CalendarRange{Start: calT0, End: calT0.AddDate(6, 0, 0)}
			if _, err := cal.ListCalendarEvents(ctx, tid, calOwner, long); !errors.Is(err, ErrCalendarTooMany) {
				t.Fatalf("more than 2000 occurrences: %v", err)
			}
			if ms, err := cal.CalendarMarks(ctx, tid, calOwner, CalendarRange{Start: calT0, End: calT0.AddDate(5, 0, 0)}); err != nil || len(ms) < 1800 {
				t.Fatalf("five years of marks: %d %v", len(ms), err)
			}
			if rs, err := cal.CalendarReminders(ctx, tid, calOwner, long); err != nil || len(rs) != 0 {
				t.Fatalf("a series is not an 089 remind_at row: %+v %v", rs, err)
			}
		})
	}
}

// spec 3.2: an exception row has its series' tenant; an occurrence id of
// workspace A, sent in workspace B, reads, writes and deletes nothing.
func TestCalendarSeriesCrossTenant(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			a, b := newTenant(t, st), newTenant(t, st)
			s, err := cal.CreateCalendarEvent(ctx, a, calAC04(), calT0)
			if err != nil {
				t.Fatal(err)
			}
			occ := s.ID + "_20261021T060000Z"
			if _, err := cal.GetCalendarEvent(ctx, b, calOwner, occ); !errors.Is(err, ErrNotFound) {
				t.Fatalf("B reads A's occurrence: %v", err)
			}
			for _, scope := range []string{"", CalendarScopeThis, CalendarScopeFollowing, CalendarScopeAll} {
				if _, err := cal.UpdateCalendarEvent(ctx, b, calOwner, occ, CalendarPatch{Title: calPtr("B"), Scope: scope}, calT0); !errors.Is(err, ErrNotFound) {
					t.Fatalf("B edits A's occurrence (%q): %v", scope, err)
				}
				if _, err := cal.TrashCalendarScope(ctx, b, calOwner, occ, scope, time.Time{}, calT0); !errors.Is(err, ErrNotFound) {
					t.Fatalf("B deletes A's occurrence (%q): %v", scope, err)
				}
			}
			if got := calLocal(calList(t, cal, a)); strings.Count(got, "standup") != 6 {
				t.Fatalf("A's series changed: %s", got)
			}
			if evs := calList(t, cal, b); len(evs) != 0 {
				t.Fatalf("B holds rows: %+v", evs)
			}
			if pg, ok := st.(*Postgres); ok {
				var n int
				if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
					return tx.QueryRow(ctx, `SELECT count(*) FROM calendar_events WHERE recurring_event_id = $1::uuid`, s.ID).Scan(&n)
				}); err != nil || n != 0 {
					t.Fatalf("exception rows of A's series: %d %v", n, err)
				}
			}
			// CONTROL: the same call in A writes an exception row
			if _, err := cal.UpdateCalendarEvent(ctx, a, calOwner, occ, CalendarPatch{Title: calPtr("A")}, calT0); err != nil {
				t.Fatalf("CONTROL A edits its occurrence: %v", err)
			}
			if got := calLocal(calList(t, cal, a)); !strings.Contains(got, "Oct 21 09:00 A") {
				t.Fatal(fmt.Sprintf("CONTROL: %s", got))
			}
		})
	}
}
