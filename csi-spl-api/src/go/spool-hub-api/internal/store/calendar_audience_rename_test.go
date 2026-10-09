package store

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
)

// The audience rename, step 1 (rdb 0159, owner t1 a3ce2031 msg bad3799a):
// the workspace audience is written as workspace, and the legacy public (its
// old name) is taken and read as workspace, never as the signed-out audience.

func TestCalendarAudienceLegacyPublicIsWorkspace(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			e := calEvent("legacy")
			e.Audience = calendarLegacyPublic
			out, err := cal.CreateCalendarEvent(ctx, tid, e, calT0)
			if err != nil || out.Audience != CalendarWorkspace {
				t.Fatalf("create public: %+v %v", out, err)
			}
			web := CalendarWeb
			if out, err = cal.UpdateCalendarEvent(ctx, tid, calOwner, out.ID, CalendarPatch{Audience: &web}, calT0); err != nil || out.Audience != CalendarWeb {
				t.Fatalf("edit to web: %+v %v", out, err)
			}
			pub := calendarLegacyPublic
			if out, err = cal.UpdateCalendarEvent(ctx, tid, calOwner, out.ID, CalendarPatch{Audience: &pub}, calT0); err != nil || out.Audience != CalendarWorkspace {
				t.Fatalf("edit back to public: %+v %v", out, err)
			}
			if evs, err := st.(CalendarWebReader).WebCalendarEvents(ctx, tid, calWeek()); err != nil || len(evs) != 0 {
				t.Fatalf("a legacy public event reached the signed-out read: %+v %v", evs, err)
			}
		})
	}
}

// A row the running hub wrote before this step still holds public: it reads
// as workspace and a search for workspace finds it.
func TestCalendarAudienceStoredPublicReadsWorkspace(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	e, err := pg.CreateCalendarEvent(ctx, tid, calEvent("old row"), calT0)
	if err != nil {
		t.Fatal(err)
	}
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE calendar_events SET audience = 'public' WHERE event_id = $1::uuid`, e.ID)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if got, err := pg.GetCalendarEvent(ctx, tid, calOwner, e.ID); err != nil || got.Audience != CalendarWorkspace {
		t.Fatalf("stored public reads: %+v %v", got, err)
	}
	q := CalendarQuery{Audiences: []string{CalendarWorkspace}, Range: calWeek()}
	if evs, err := pg.SearchCalendarEvents(ctx, tid, calOwner, q); err != nil || calIDs(evs) != "old row" {
		t.Fatalf("search workspace: %q %v", calIDs(evs), err)
	}
	if evs, err := pg.WebCalendarEvents(ctx, tid, calWeek()); err != nil || len(evs) != 0 {
		t.Fatalf("a stored public row reached the signed-out read: %+v %v", evs, err)
	}
}
