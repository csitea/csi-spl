package store

import (
	"context"
	"os"
	"path/filepath"
	"strings"
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

// Step 5 (rdb 0161): a row written before step 4 still holds web. It reads
// as public, and 0161 maps it to public, leaves updated_at alone and
// leaves a check that refuses web. The test drops the check to write that
// row; 0161 adds it back in the same transaction.
func TestCalendarAudience0161MapsWeb(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0161_calendar_web_to_public.sql"))
	if err != nil {
		t.Fatal(err)
	}
	tid := newTenant(t, pg)
	e, err := pg.CreateCalendarEvent(ctx, tid, calEvent("old row"), calT0)
	if err != nil {
		t.Fatal(err)
	}
	var mid string
	var upd0, upd1 time.Time
	if err := pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		for _, q := range []string{pgScopeOperator, `ALTER TABLE calendar_events DROP CONSTRAINT calendar_events_audience_check`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `UPDATE calendar_events SET audience = 'web' WHERE event_id = $1::uuid
			RETURNING audience, updated_at`, e.ID).Scan(&mid, &upd0); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, string(raw))
		return err
	}); err != nil || mid != "web" {
		t.Fatalf("seed web + 0161: %q %v", mid, err)
	}
	var aud string
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT audience, updated_at FROM calendar_events WHERE event_id = $1::uuid`, e.ID).Scan(&aud, &upd1)
	}); err != nil || aud != CalendarPublic || !upd1.Equal(upd0) {
		t.Fatalf("after 0161: %q %v -> %v %v", aud, upd0, upd1, err)
	}
	if evs, err := pg.WebCalendarEvents(ctx, tid, calWeek()); err != nil || webTitles(evs) != "old row" {
		t.Fatalf("the mapped row is not in the signed-out read: %+v %v", evs, err)
	}
	err = pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE calendar_events SET audience = 'web' WHERE event_id = $1::uuid`, e.ID)
		return err
	})
	if err == nil || !strings.Contains(err.Error(), "calendar_events_audience_check") {
		t.Fatalf("the check still takes web: %v", err)
	}
}

// Step 2 (rdb 0160): every stored public row becomes workspace, its
// updated_at untouched; private rows keep theirs.
func TestCalendarAudience0160MapsPublic(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0160_calendar_public_to_workspace.sql"))
	if err != nil {
		t.Fatal(err)
	}
	tid := newTenant(t, pg)
	for _, title := range []string{"public", "private"} {
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
	if before["public"] != "public" {
		t.Fatalf("CONTROL: the seeded rows: %v", before)
	}
	if err := pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, string(raw))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	after, upd1 := audiences()
	want := map[string]string{"public": CalendarWorkspace, "private": CalendarPrivate}
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
