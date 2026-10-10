package store

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
)

// The signed-out read (calendar_web.go, rdb 0158) on Memory and Postgres:
// (a) a public event is answered; (b) the workspace's workspace, internal
// and private events are not (the leak test); (c) another workspace's public event
// is not; (d) the control: with the audience filter off, (b) fails.

func webTitles(evs []WebCalendarEvent) string {
	var out []string
	for _, e := range evs {
		out = append(out, e.Title)
	}
	slices.Sort(out)
	return strings.Join(out, ",")
}

// seedWebCalendar writes one event per audience in tenant, titled
// <prefix>-<audience>, the private one with a mention.
func seedWebCalendar(t *testing.T, cal Calendar, tenant, prefix string) {
	t.Helper()
	for _, a := range calendarAudiences {
		e := calEvent(prefix + "-" + a)
		e.Audience, e.Description = a, "about "+a
		if a == CalendarPrivate {
			e.Mentions = []string{calAgent}
		}
		if _, err := cal.CreateCalendarEvent(context.Background(), tenant, e, calT0); err != nil {
			t.Fatalf("create %s: %v", a, err)
		}
	}
}

func TestCalendarWebSignedOutRead(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal, web := st.(Calendar), st.(CalendarWebReader)
			a, b := newTenant(t, st), newTenant(t, st)
			seedWebCalendar(t, cal, a, "a")
			seedWebCalendar(t, cal, b, "b")

			evs, err := web.WebCalendarEvents(ctx, a, calWeek())
			if err != nil {
				t.Fatal(err)
			}
			// (a) + (b) + (c): only workspace a's public event.
			if got := webTitles(evs); got != "a-public" {
				t.Fatalf("signed-out read of a = %q, want only a-public (n=%d)", got, len(evs))
			}
			e := evs[0]
			if e.Description != "about public" || !e.StartsAt.Equal(calT0) || !e.EndsAt.Equal(calT0.Add(time.Hour)) || e.AllDay {
				t.Fatalf("safe fields: %+v", e)
			}
			// Outside the range: nothing.
			past := CalendarRange{Start: calT0.Add(-30 * 24 * time.Hour), End: calT0.Add(-24 * time.Hour)}
			if evs, err := web.WebCalendarEvents(ctx, a, past); err != nil || len(evs) != 0 {
				t.Fatalf("range: %v %v", evs, err)
			}
			// A trashed public event is gone too.
			mine, _ := cal.ListCalendarEvents(ctx, a, calOwner, calWeek())
			for _, m := range mine {
				if m.Audience == CalendarPublic {
					if err := cal.DeleteCalendarEvent(ctx, a, calOwner, m.ID); err != nil {
						t.Fatal(err)
					}
				}
			}
			if evs, err := web.WebCalendarEvents(ctx, a, calWeek()); err != nil || len(evs) != 0 {
				t.Fatalf("trashed public event still read: %v %v", evs, err)
			}
			if _, err := web.WebCalendarEvents(ctx, "", calWeek()); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v", err)
			}
		})
	}
}

// TestCalendarWebLeakControl: with the audience filter off the leak test's
// (b) must fail, or that test proves nothing.
func TestCalendarWebLeakControl(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			calendarWebFilterOff = true
			t.Cleanup(func() { calendarWebFilterOff = false })
			a := newTenant(t, st)
			seedWebCalendar(t, st.(Calendar), a, "a")
			evs, err := st.(CalendarWebReader).WebCalendarEvents(ctx, a, calWeek())
			if err != nil {
				t.Fatal(err)
			}
			if got := webTitles(evs); got == "a-public" {
				t.Fatalf("CONTROL: with the filter off the read still answered only %q; the leak test is vacuous", got)
			}
			t.Logf("CONTROL: filter off answers %q (n=%d), so (b) fails without the filter", webTitles(evs), len(evs))
		})
	}
}

func TestCalendarWebAudienceValidation(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			e, err := cal.CreateCalendarEvent(ctx, tid, calEvent("w"), calT0)
			if err != nil || e.Audience != CalendarWorkspace {
				t.Fatalf("default stays workspace: %+v %v", e, err)
			}
			pub := CalendarPublic
			if e, err = cal.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{Audience: &pub}, calT0); err != nil || e.Audience != CalendarPublic {
				t.Fatalf("edit to public: %+v %v", e, err)
			}
			bad := "internet"
			if _, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{Audience: &bad}, calT0); !errors.Is(err, ErrInvalidCalendarEvent) {
				t.Fatalf("unknown audience: %v", err)
			}
			// A member reads a public event like a workspace one.
			if got, err := cal.GetCalendarEvent(ctx, tid, calMember, e.ID); err != nil || got.Audience != CalendarPublic {
				t.Fatalf("member reads public: %+v %v", got, err)
			}
		})
	}
}

// TestCalendarWebGoalFields (specs/112 HUB-4): a public synced event carries
// its key, roadmap_url, specs and done_lines; a member's public event carries
// none. With the audience filter off an internal synced event is read, and it
// must still carry none of the four (webGoalFields is their one gate).
func TestCalendarWebGoalFields(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			pub := syncEv("goal:G01:deadline", "pub", "goal", CalendarPublic)
			pub.Event.Props["specs"], pub.Event.Props["done_lines"] = []string{"089", "112"}, []string{"all specs [x]"}
			pub.Event.Props["location"] = "not for the internet"
			in := syncEv("goal:G02:deadline", "in", "goal", CalendarInternal)
			in.Event.Props["specs"] = []string{"113"}
			if _, err := st.(CalendarSync).UpsertCalendarBySourceKey(ctx, tid, []CalendarSyncEvent{pub, in}, syncT0); err != nil {
				t.Fatal(err)
			}
			own := calEvent("own")
			own.Audience, own.StartsAt, own.EndsAt = CalendarPublic, syncT0, syncT0.Add(time.Hour)
			if _, err := st.(Calendar).CreateCalendarEvent(ctx, tid, own, syncT0); err != nil {
				t.Fatal(err)
			}
			week := CalendarRange{Start: syncT0.Add(-24 * time.Hour), End: syncT0.Add(48 * time.Hour)}
			goals := func() string {
				t.Helper()
				evs, err := st.(CalendarWebReader).WebCalendarEvents(ctx, tid, week)
				if err != nil {
					t.Fatal(err)
				}
				var out []string
				for _, e := range evs {
					out = append(out, fmt.Sprintf("%s=%+v", e.Title, e.Goal))
				}
				slices.Sort(out)
				return strings.Join(out, " ")
			}
			want := "own=<nil> pub=&{SourceKey:goal:G01:deadline RoadmapURL:/roadmap?goal=G01 Specs:[089 112] DoneLines:[all specs [x]]}"
			if got := goals(); got != want {
				t.Fatalf("goal fields:\n got %s\nwant %s", got, want)
			}
			calendarWebFilterOff = true
			t.Cleanup(func() { calendarWebFilterOff = false })
			if got := goals(); got != "in=<nil> "+want {
				t.Fatalf("filter off: an internal synced event must carry no goal field:\n got %s\nwant in=<nil> %s", got, want)
			}
		})
	}
}
