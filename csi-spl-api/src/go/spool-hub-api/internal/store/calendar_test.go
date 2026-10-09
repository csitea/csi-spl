package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/089 T003: the calendar store on Memory and Postgres. A create without
// audience stores public; a member who is not mentioned cannot read, change
// or delete a private event, while its creator and a mentioned agent can;
// reminders go only to the creator and the mentions; workspace A cannot read
// workspace B (AC-07).

const (
	calOwner  = "11111111-1111-4111-8111-111111111111" // the workspace owner (a human UUID)
	calMember = "22222222-2222-4222-8222-222222222222" // a member nobody mentions
	calAgent  = "c-042"                                // an agent named with @
)

var calT0 = time.Date(2026, 10, 5, 9, 0, 0, 0, time.UTC)

func calEvent(title string) CalendarEvent {
	return CalendarEvent{Title: title, Kind: "release", StartsAt: calT0, EndsAt: calT0.Add(time.Hour),
		CreatorType: "human", CreatorID: calOwner}
}

func calWeek() CalendarRange {
	return CalendarRange{Start: calT0.Add(-24 * time.Hour), End: calT0.Add(6 * 24 * time.Hour)}
}

func calIDs(evs []CalendarEvent) string {
	var ids []string
	for _, e := range evs {
		ids = append(ids, e.Title)
	}
	return strings.Join(ids, ",")
}

func TestCalendarAudience(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			pub, err := cal.CreateCalendarEvent(ctx, tid, calEvent("pub"), calT0)
			if err != nil || pub.Audience != CalendarWorkspace || pub.ID == "" || len(pub.Mentions) != 0 {
				t.Fatalf("default audience: %+v %v", pub, err)
			}
			priv := calEvent("priv")
			priv.Audience, priv.Mentions, priv.RemindAt = CalendarPrivate, []string{calAgent}, calT0.Add(-10*time.Minute)
			if priv, err = cal.CreateCalendarEvent(ctx, tid, priv, calT0); err != nil {
				t.Fatal(err)
			}
			for _, v := range []string{calOwner, calAgent} {
				if got, err := cal.GetCalendarEvent(ctx, tid, v, priv.ID); err != nil || got.Title != "priv" || got.Mentions[0] != calAgent {
					t.Fatalf("%s reads its private event: %+v %v", v, got, err)
				}
				if evs, _ := cal.ListCalendarEvents(ctx, tid, v, calWeek()); calIDs(evs) != "pub,priv" && calIDs(evs) != "priv,pub" {
					t.Fatalf("%s range: %s", v, calIDs(evs))
				}
			}
			for _, v := range []string{calMember, ""} {
				if _, err := cal.GetCalendarEvent(ctx, tid, v, priv.ID); !errors.Is(err, ErrNotFound) {
					t.Fatalf("%q reads a private event: %v", v, err)
				}
				if evs, _ := cal.ListCalendarEvents(ctx, tid, v, calWeek()); calIDs(evs) != "pub" {
					t.Fatalf("%q range: %s", v, calIDs(evs))
				}
				title := "hijack"
				if _, err := cal.UpdateCalendarEvent(ctx, tid, v, priv.ID, CalendarPatch{Title: &title}, calT0); !errors.Is(err, ErrNotFound) {
					t.Fatalf("%q updates a private event: %v", v, err)
				}
				if err := cal.DeleteCalendarEvent(ctx, tid, v, priv.ID); !errors.Is(err, ErrNotFound) {
					t.Fatalf("%q deletes a private event: %v", v, err)
				}
			}
			// marks hide the private event from the member too
			if ms, _ := cal.CalendarMarks(ctx, tid, calMember, calWeek()); len(ms) != 1 || ms[0].Count != 1 {
				t.Fatalf("member marks: %+v", ms)
			}
			if ms, _ := cal.CalendarMarks(ctx, tid, calAgent, calWeek()); len(ms) != 1 || ms[0].Count != 2 || ms[0].Day != "2026-10-05" {
				t.Fatalf("agent marks: %+v", ms)
			}
		})
	}
}

func TestCalendarUpdateAndReminders(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			e := calEvent("deploy")
			e.RemindAt = calT0.Add(-15 * time.Minute)
			e, err := cal.CreateCalendarEvent(ctx, tid, e, calT0)
			if err != nil {
				t.Fatal(err)
			}
			win := CalendarRange{Start: calT0.Add(-time.Hour), End: calT0.Add(23 * time.Hour)}
			// a public event reminds its creator, not every member (D4)
			if rs, _ := cal.CalendarReminders(ctx, tid, calOwner, win); len(rs) != 1 {
				t.Fatalf("owner reminders: %+v", rs)
			}
			for _, v := range []string{calMember, calAgent, ""} {
				if rs, _ := cal.CalendarReminders(ctx, tid, v, win); len(rs) != 0 {
					t.Fatalf("%q reminders: %+v", v, rs)
				}
			}
			// a member edits a public event: mention the agent, move it a day
			starts, ends, mentions := calT0.Add(24*time.Hour), calT0.Add(25*time.Hour), []string{calAgent}
			remind := calT0.Add(23 * time.Hour)
			got, err := cal.UpdateCalendarEvent(ctx, tid, calMember, e.ID, CalendarPatch{StartsAt: &starts, EndsAt: &ends,
				Mentions: &mentions, RemindAt: &remind}, calT0.Add(time.Minute))
			if err != nil || !got.StartsAt.Equal(starts) || got.Title != "deploy" || !got.UpdatedAt.Equal(calT0.Add(time.Minute)) || !got.CreatedAt.Equal(calT0) {
				t.Fatalf("update: %+v %v", got, err)
			}
			if rs, _ := cal.CalendarReminders(ctx, tid, calAgent, CalendarRange{Start: remind, End: remind.Add(time.Hour)}); len(rs) != 1 {
				t.Fatalf("mentioned agent reminders: %+v", rs)
			}
			// [Start, End): the end of the window is out
			if rs, _ := cal.CalendarReminders(ctx, tid, calAgent, CalendarRange{Start: calT0, End: remind}); len(rs) != 0 {
				t.Fatalf("window end is exclusive: %+v", rs)
			}
			var zero time.Time
			if got, err = cal.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{RemindAt: &zero}, calT0); err != nil || !got.RemindAt.IsZero() {
				t.Fatalf("clear reminder: %+v %v", got, err)
			}
			// a patch the 0125 checks refuse changes nothing
			back := calT0
			if _, err = cal.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{EndsAt: &back}, calT0); !errors.Is(err, ErrInvalidCalendarEvent) {
				t.Fatalf("ends before starts: %v", err)
			}
			if got, _ = cal.GetCalendarEvent(ctx, tid, calOwner, e.ID); !got.EndsAt.Equal(ends) {
				t.Fatalf("refused patch wrote: %+v", got)
			}
			if err = cal.DeleteCalendarEvent(ctx, tid, calMember, e.ID); err != nil {
				t.Fatal(err)
			}
			if _, err = cal.GetCalendarEvent(ctx, tid, calOwner, e.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("after delete: %v", err)
			}
			if _, err = cal.GetCalendarEvent(ctx, tid, calOwner, "not-a-uuid"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("bad id: %v", err)
			}
		})
	}
}

func TestCalendarValidationAndMarks(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			for what, mut := range map[string]func(*CalendarEvent){
				"kind":     func(e *CalendarEvent) { e.Kind = "party" },
				"audience": func(e *CalendarEvent) { e.Audience = "team" },
				"title":    func(e *CalendarEvent) { e.Title = "" },
				"range":    func(e *CalendarEvent) { e.EndsAt = e.StartsAt.Add(-time.Second) },
				"creator":  func(e *CalendarEvent) { e.CreatorType = "bot" },
				"release":  func(e *CalendarEvent) { e.ReleaseVersion = "1.2.3" },
			} {
				e := calEvent("bad")
				mut(&e)
				if _, err := cal.CreateCalendarEvent(ctx, tid, e, calT0); !errors.Is(err, ErrInvalidCalendarEvent) {
					t.Fatalf("%s: %v", what, err)
				}
			}
			// an all-day freeze Mon..Wed ends at Thu 00:00 and covers 3 days;
			// a zero-length release on Wed marks Wed once more
			mon := time.Date(2026, 10, 5, 0, 0, 0, 0, time.UTC)
			freeze := CalendarEvent{Title: "freeze", Kind: "freeze", StartsAt: mon, EndsAt: mon.Add(72 * time.Hour), AllDay: true,
				CreatorType: "system", CreatorID: "hub"}
			rel := CalendarEvent{Title: "v1.4.0", Kind: "release", StartsAt: mon.Add(50 * time.Hour), EndsAt: mon.Add(50 * time.Hour),
				CreatorType: "system", CreatorID: "hub", ReleaseVersion: "v1.4.0"}
			for _, e := range []CalendarEvent{freeze, rel} {
				if _, err := cal.CreateCalendarEvent(ctx, tid, e, calT0); err != nil {
					t.Fatal(err)
				}
			}
			ms, err := cal.CalendarMarks(ctx, tid, calMember, CalendarRange{Start: mon.Add(-48 * time.Hour), End: mon.Add(7 * 24 * time.Hour)})
			var got []string
			for _, m := range ms {
				got = append(got, m.Day+"="+strings.Join(m.Kinds, "+"))
			}
			if err != nil || strings.Join(got, " ") != "2026-10-05=freeze 2026-10-06=freeze 2026-10-07=freeze+release" || ms[2].Count != 2 {
				t.Fatalf("marks: %v %v", got, err)
			}
			// the strip window clips a long event to its own days
			ms, _ = cal.CalendarMarks(ctx, tid, calMember, CalendarRange{Start: mon.Add(24 * time.Hour), End: mon.Add(48 * time.Hour)})
			if len(ms) != 1 || ms[0].Day != "2026-10-06" {
				t.Fatalf("clipped marks: %+v", ms)
			}
			if ds, err := cal.OfficialDays(ctx, "fi", calWeek()); err != nil || len(ds) != 0 {
				t.Fatalf("official days (no rows yet): %+v %v", ds, err)
			}
		})
	}
}

// AC-07: workspace B reads none of workspace A's events, by id, by range,
// by marks or by reminders, and cannot change or delete them.
func TestCalendarCrossTenant(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			a, b := newTenant(t, st), newTenant(t, st)
			e := calEvent("a-only")
			e.RemindAt = calT0
			e, err := cal.CreateCalendarEvent(ctx, a, e, calT0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := cal.GetCalendarEvent(ctx, b, calOwner, e.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("B reads A's event: %v", err)
			}
			if evs, _ := cal.ListCalendarEvents(ctx, b, calOwner, calWeek()); len(evs) != 0 {
				t.Fatalf("B's range holds A's event: %+v", evs)
			}
			if ms, _ := cal.CalendarMarks(ctx, b, calOwner, calWeek()); len(ms) != 0 {
				t.Fatalf("B's marks: %+v", ms)
			}
			if rs, _ := cal.CalendarReminders(ctx, b, calOwner, calWeek()); len(rs) != 0 {
				t.Fatalf("B's reminders: %+v", rs)
			}
			title := "x"
			if _, err := cal.UpdateCalendarEvent(ctx, b, calOwner, e.ID, CalendarPatch{Title: &title}, calT0); !errors.Is(err, ErrNotFound) {
				t.Fatalf("B updates A's event: %v", err)
			}
			if err := cal.DeleteCalendarEvent(ctx, b, calOwner, e.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("B deletes A's event: %v", err)
			}
			if _, err := cal.GetCalendarEvent(ctx, a, calOwner, e.ID); err != nil {
				t.Fatalf("CONTROL: A reads its own event: %v", err)
			}
			if _, err := cal.ListCalendarEvents(ctx, "", calOwner, calWeek()); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v", err)
			}
		})
	}
}

// The Postgres half of AC-07 rests on RLS, not on the store's WHERE
// tenant_id: in B's scope a read with NO tenant predicate still sees none of
// A's rows, and with no scope at all it sees nothing. The CONTROL, the same
// read as the operator, sees A's row, so the zero counts are not vacuous.
func TestCalendarRLSControl(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	e, err := pg.CreateCalendarEvent(ctx, a, calEvent("rls"), calT0)
	if err != nil {
		t.Fatal(err)
	}
	const noTenantPredicate = `SELECT count(*) FROM calendar_events WHERE event_id = $1::uuid`
	count := func(run func(fn func(pgx.Tx) error) error) int {
		var n int
		if err := run(func(tx pgx.Tx) error { return tx.QueryRow(ctx, noTenantPredicate, e.ID).Scan(&n) }); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := count(func(fn func(pgx.Tx) error) error { return pg.inTenant(ctx, b, fn) }); n != 0 {
		t.Fatalf("B's scope sees A's event: %d", n)
	}
	if n := count(func(fn func(pgx.Tx) error) error { return pgx.BeginFunc(ctx, pg.pool, fn) }); n != 0 {
		t.Fatalf("no scope sees A's event: %d", n)
	}
	if n := count(func(fn func(pgx.Tx) error) error { return pg.inTenant(ctx, a, fn) }); n != 1 {
		t.Fatalf("CONTROL: A's scope sees its event: %d", n)
	}
	if n := count(func(fn func(pgx.Tx) error) error { return pg.asOperator(ctx, fn) }); n != 1 {
		t.Fatalf("CONTROL: the operator sees A's event: %d", n)
	}
	// a write in B's scope that names A's tenant is refused by WITH CHECK
	err = pg.inTenant(ctx, b, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO calendar_events (tenant_id, title, kind, starts_at, ends_at, creator_type, creator_id)
			VALUES ($1, 'forged', 'other', now(), now(), 'human', 'x')`, a)
		return err
	})
	if err == nil || !strings.Contains(err.Error(), "row-level security") {
		t.Fatalf("B writes into A: %v", err)
	}
}

// While rdb 0125 is missing on an env the reads answer empty and the writes
// ErrCalendarUnavailable, never a 500 (the agent_seats.go probe).
func TestCalendarProbeMissingTable(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	e, err := pg.CreateCalendarEvent(ctx, tid, calEvent("seen"), calT0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pg.cal = seatsProbe{} })
	pg.cal = seatsProbe{check: func(context.Context) (bool, error) { return false, nil }}
	if evs, err := pg.ListCalendarEvents(ctx, tid, calOwner, calWeek()); err != nil || len(evs) != 0 {
		t.Fatalf("range without the table: %+v %v", evs, err)
	}
	if ms, err := pg.CalendarMarks(ctx, tid, calOwner, calWeek()); err != nil || len(ms) != 0 {
		t.Fatalf("marks without the table: %+v %v", ms, err)
	}
	if rs, err := pg.CalendarReminders(ctx, tid, calOwner, calWeek()); err != nil || len(rs) != 0 {
		t.Fatalf("reminders without the table: %+v %v", rs, err)
	}
	if _, err := pg.GetCalendarEvent(ctx, tid, calOwner, e.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get without the table: %v", err)
	}
	if _, err := pg.CreateCalendarEvent(ctx, tid, calEvent("x"), calT0); !errors.Is(err, ErrCalendarUnavailable) {
		t.Fatalf("create without the table: %v", err)
	}
	if err := pg.DeleteCalendarEvent(ctx, tid, calOwner, e.ID); !errors.Is(err, ErrCalendarUnavailable) {
		t.Fatalf("delete without the table: %v", err)
	}
	pg.cal = seatsProbe{}
	if evs, err := pg.ListCalendarEvents(ctx, tid, calOwner, calWeek()); err != nil || len(evs) != 1 {
		t.Fatalf("CONTROL range with the table: %+v %v", evs, err)
	}
}
