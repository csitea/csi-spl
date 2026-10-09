package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The audience rename (rdb 0159's header, owner t1 a3ce2031 msg bad3799a):
// workspace is everyone in the workspace (public before), public the
// signed-out audience (web before). This hub is step 4: public is written
// and read as the signed-out audience, and the legacy web is taken and read
// as public.

func TestCalendarAudiencePublicIsSignedOut(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal, web := st.(Calendar), st.(CalendarWebReader)
			tid := newTenant(t, st)
			e := calEvent("open day")
			e.Audience = CalendarPublic
			out, err := cal.CreateCalendarEvent(ctx, tid, e, calT0)
			if err != nil || out.Audience != CalendarPublic {
				t.Fatalf("create public: %+v %v", out, err)
			}
			if evs, err := web.WebCalendarEvents(ctx, tid, calWeek()); err != nil || webTitles(evs) != "open day" {
				t.Fatalf("a public event is not in the signed-out read: %+v %v", evs, err)
			}
			ws := CalendarWorkspace
			if out, err = cal.UpdateCalendarEvent(ctx, tid, calOwner, out.ID, CalendarPatch{Audience: &ws}, calT0); err != nil || out.Audience != CalendarWorkspace {
				t.Fatalf("edit to workspace: %+v %v", out, err)
			}
			if evs, err := web.WebCalendarEvents(ctx, tid, calWeek()); err != nil || len(evs) != 0 {
				t.Fatalf("a workspace event reached the signed-out read: %+v %v", evs, err)
			}
			legacy := calendarLegacyWeb
			if out, err = cal.UpdateCalendarEvent(ctx, tid, calOwner, out.ID, CalendarPatch{Audience: &legacy}, calT0); err != nil || out.Audience != CalendarPublic {
				t.Fatalf("edit to the legacy web: %+v %v", out, err)
			}
		})
	}
}

// A row written before step 4 still holds web: it reads as public, a search
// for public finds it, and the signed-out read answers it.
func TestCalendarAudienceStoredWebReadsPublic(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	e, err := pg.CreateCalendarEvent(ctx, tid, calEvent("old row"), calT0)
	if err != nil {
		t.Fatal(err)
	}
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE calendar_events SET audience = 'web' WHERE event_id = $1::uuid`, e.ID)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if got, err := pg.GetCalendarEvent(ctx, tid, calOwner, e.ID); err != nil || got.Audience != CalendarPublic {
		t.Fatalf("stored web reads: %+v %v", got, err)
	}
	q := CalendarQuery{Audiences: []string{CalendarPublic}, Range: calWeek()}
	if evs, err := pg.SearchCalendarEvents(ctx, tid, calOwner, q); err != nil || calIDs(evs) != "old row" {
		t.Fatalf("search public: %q %v", calIDs(evs), err)
	}
	if evs, err := pg.WebCalendarEvents(ctx, tid, calWeek()); err != nil || webTitles(evs) != "old row" {
		t.Fatalf("a stored web row is not in the signed-out read: %+v %v", evs, err)
	}
}

// Step 2 (rdb 0160): every stored public row becomes workspace, its
// updated_at untouched; web and private rows keep theirs.
func TestCalendarAudience0160MapsPublic(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0160_calendar_public_to_workspace.sql"))
	if err != nil {
		t.Fatal(err)
	}
	tid := newTenant(t, pg)
	for _, title := range []string{"public", "web", "private"} {
		if _, err := pg.CreateCalendarEvent(ctx, tid, calEvent(title), calT0); err != nil {
			t.Fatal(err)
		}
	}
	audiences := func() (map[string]string, map[string]time.Time) {
		t.Helper()
		aud, upd := map[string]string{}, map[string]time.Time{}
		if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			rows, err := tx.Query(ctx, `SELECT title, audience, updated_at FROM calendar_events WHERE tenant_id = $1`, tid)
			if err != nil {
				return err
			}
			defer rows.Close()
			for rows.Next() {
				var title, a string
				var u time.Time
				if err := rows.Scan(&title, &a, &u); err != nil {
					return err
				}
				aud[title], upd[title] = a, u
			}
			return rows.Err()
		}); err != nil {
			t.Fatal(err)
		}
		return aud, upd
	}
	// each row's title is the audience it held before 0160
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE calendar_events SET audience = title WHERE tenant_id = $1`, tid)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	before, upd0 := audiences()
	if before["public"] != "public" || before["web"] != "web" {
		t.Fatalf("CONTROL: the seeded rows: %v", before)
	}
	if err := pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, string(raw))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	after, upd1 := audiences()
	want := map[string]string{"public": CalendarWorkspace, "web": calendarLegacyWeb, "private": CalendarPrivate}
	for title, a := range want {
		if after[title] != a || !upd1[title].Equal(upd0[title]) {
			t.Errorf("%s: audience %q (want %q), updated_at %v -> %v", title, after[title], a, upd0[title], upd1[title])
		}
	}
	var def string
	if err := pg.Pool().QueryRow(ctx, `SELECT column_default FROM information_schema.columns
		WHERE table_name = 'calendar_events' AND column_name = 'audience'`).Scan(&def); err != nil || def != "'workspace'::text" {
		t.Fatalf("default: %q %v", def, err)
	}
}
