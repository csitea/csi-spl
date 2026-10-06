package store

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/097 T003 (rdb 0139): props and time_zone, the updated_at
// precondition, soft delete, restore and the trash, on Memory and Postgres.
// AC-07: a restore keeps the id. AC-08: workspace B cannot restore or list
// the trash of workspace A. FR-001: an 089 body stores exactly 089's row.

// calProps is a props value as the hub registry (T004) writes it.
func calProps() map[string]any {
	return map[string]any{"location": "Room 1", "color": "sage",
		"reminders": []any{map[string]any{"amount": 10, "unit": "minutes", "method": "popup"}}}
}

// FR-001: c-394's "Add to calendar" body (089 fields only) stores
// time_zone UTC, props {} and no deletion, and reads back the same.
func TestCalendar089BodyDefaults(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			e, err := cal.CreateCalendarEvent(ctx, tid, calEvent("089"), calT0)
			if err != nil || e.TimeZone != CalendarUTC || e.Props == nil || len(e.Props) != 0 ||
				!e.DeletedAt.IsZero() || e.DeletedBy != "" {
				t.Fatalf("089 body: %+v %v", e, err)
			}
			got, err := cal.GetCalendarEvent(ctx, tid, calOwner, e.ID)
			if err != nil || !reflect.DeepEqual(got, e) {
				t.Fatalf("read back:\n%+v\n%+v %v", got, e, err)
			}
			// an 089 patch leaves the 097 fields as they are
			title := "089 again"
			if got, err = cal.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{Title: &title}, calT0); err != nil ||
				got.TimeZone != CalendarUTC || len(got.Props) != 0 {
				t.Fatalf("089 patch: %+v %v", got, err)
			}
		})
	}
}

func TestCalendarPropsAndTimeZone(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			in := calEvent("props")
			in.Props, in.TimeZone = calProps(), "Europe/Helsinki"
			e, err := cal.CreateCalendarEvent(ctx, tid, in, calT0)
			if err != nil || e.TimeZone != "Europe/Helsinki" || e.Props["location"] != "Room 1" {
				t.Fatalf("create: %+v %v", e, err)
			}
			in.Props["location"] = "changed by the caller" // the store holds its own copy
			got, _ := cal.GetCalendarEvent(ctx, tid, calOwner, e.ID)
			rem := got.Props["reminders"].([]any)[0].(map[string]any)
			if got.Props["location"] != "Room 1" || rem["amount"] != float64(10) || !reflect.DeepEqual(got.Props, e.Props) {
				t.Fatalf("props read back: %+v", got.Props)
			}
			props, tz := map[string]any{"color": "grape"}, ""
			got, err = cal.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{Props: &props, TimeZone: &tz}, calT0)
			if err != nil || !reflect.DeepEqual(got.Props, map[string]any{"color": "grape"}) || got.TimeZone != CalendarUTC {
				t.Fatalf("patch props, clear time_zone: %+v %v", got, err)
			}
			for what, mut := range map[string]func(*CalendarEvent){
				"props size": func(e *CalendarEvent) { e.Props = map[string]any{"location": strings.Repeat("x", calendarPropsMax)} },
				"props json": func(e *CalendarEvent) { e.Props = map[string]any{"bad": make(chan int)} },
				"time_zone":  func(e *CalendarEvent) { e.TimeZone = strings.Repeat("Z", 65) },
			} {
				bad := calEvent("bad")
				mut(&bad)
				if _, err := cal.CreateCalendarEvent(ctx, tid, bad, calT0); !errors.Is(err, ErrInvalidCalendarEvent) {
					t.Fatalf("%s: %v", what, err)
				}
			}
		})
	}
}

// The jsonb bound counts the spaces Postgres prints, never inside strings.
func TestJSONBTextLen(t *testing.T) {
	for in, want := range map[string]int{`{}`: 2, `{"a":1,"b":[1,2]}`: 21, `{"a":"x:,\"y,"}`: 16} {
		if got := jsonbTextLen([]byte(in)); got != want {
			t.Fatalf("%s: %d, want %d", in, got, want)
		}
	}
}

// AC-02 at the store: two patches naming the same updated_at, the second is
// refused with the first one's result; a stale delete deletes nothing.
func TestCalendarEditPrecondition(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			e, err := cal.CreateCalendarEvent(ctx, tid, calEvent("drag"), calT0.Add(time.Nanosecond*1500))
			if err != nil {
				t.Fatal(err)
			}
			first, second := "first", "second"
			got, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{Title: &first, IfUpdatedAt: e.UpdatedAt},
				calT0.Add(time.Minute+time.Nanosecond*700))
			if err != nil || got.Title != "first" {
				t.Fatalf("fresh precondition: %+v %v", got, err)
			}
			cur, err := cal.UpdateCalendarEvent(ctx, tid, calMember, e.ID, CalendarPatch{Title: &second, IfUpdatedAt: e.UpdatedAt},
				calT0.Add(2*time.Minute))
			if !errors.Is(err, ErrEditConflict) || cur.Title != "first" || !cur.UpdatedAt.Equal(got.UpdatedAt) {
				t.Fatalf("stale precondition: %+v %v", cur, err)
			}
			if _, err = cal.TrashCalendarEvent(ctx, tid, calOwner, e.ID, e.UpdatedAt, calT0); !errors.Is(err, ErrEditConflict) {
				t.Fatalf("stale delete: %v", err)
			}
			if _, err = cal.GetCalendarEvent(ctx, tid, calOwner, e.ID); err != nil {
				t.Fatalf("a stale delete deleted: %v", err)
			}
			// the updated_at a read answers is the one a precondition matches
			if _, err = cal.TrashCalendarEvent(ctx, tid, calOwner, e.ID, cur.UpdatedAt, calT0); err != nil {
				t.Fatalf("fresh delete: %v", err)
			}
		})
	}
}

// AC-07: delete hides the event from every read; the deleter's trash lists
// it; restore brings back the same id with its fields.
func TestCalendarSoftDeleteRestore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			tid := newTenant(t, st)
			in := calEvent("undo")
			in.Props, in.RemindAt = calProps(), calT0.Add(-time.Hour)
			e, err := cal.CreateCalendarEvent(ctx, tid, in, calT0)
			if err != nil {
				t.Fatal(err)
			}
			keep, _ := cal.CreateCalendarEvent(ctx, tid, calEvent("keep"), calT0)
			del := calT0.Add(time.Hour)
			gone, err := cal.TrashCalendarEvent(ctx, tid, calMember, e.ID, time.Time{}, del)
			if err != nil || !gone.DeletedAt.Equal(del) || gone.DeletedBy != calMember || !gone.UpdatedAt.Equal(e.UpdatedAt) {
				t.Fatalf("trash: %+v %v", gone, err)
			}
			calAssertHidden(t, cal, tid, e.ID)
			if evs, _ := cal.ListCalendarEvents(ctx, tid, calOwner, calWeek()); calIDs(evs) != "keep" {
				t.Fatalf("CONTROL: the live event stays: %s", calIDs(evs))
			}
			if _, err := cal.TrashCalendarEvent(ctx, tid, calMember, e.ID, time.Time{}, del); !errors.Is(err, ErrNotFound) {
				t.Fatalf("delete twice: %v", err)
			}
			// the trash is the caller's own deletions, within since
			if tr, err := cal.CalendarTrash(ctx, tid, calMember, del); err != nil || len(tr) != 1 || tr[0].ID != e.ID || !tr[0].DeletedAt.Equal(del) {
				t.Fatalf("member's trash: %+v %v", tr, err)
			}
			for _, v := range []string{calOwner, ""} {
				if tr, _ := cal.CalendarTrash(ctx, tid, v, calT0); len(tr) != 0 {
					t.Fatalf("%q's trash: %+v", v, tr)
				}
			}
			if tr, _ := cal.CalendarTrash(ctx, tid, calMember, del.Add(time.Second)); len(tr) != 0 {
				t.Fatalf("trash before since: %+v", tr)
			}
			if _, err := cal.RestoreCalendarEvent(ctx, tid, calOwner, e.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("someone else restores: %v", err)
			}
			if _, err := cal.RestoreCalendarEvent(ctx, tid, calMember, keep.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("restore a live event: %v", err)
			}
			back, err := cal.RestoreCalendarEvent(ctx, tid, calMember, e.ID)
			if err != nil || back.ID != e.ID || !back.DeletedAt.IsZero() || back.DeletedBy != "" || !reflect.DeepEqual(back, e) {
				t.Fatalf("restore:\n%+v\n%+v %v", back, e, err)
			}
			if rs, _ := cal.CalendarReminders(ctx, tid, calOwner, calWeek()); len(rs) != 1 {
				t.Fatalf("restored reminder: %+v", rs)
			}
			if tr, _ := cal.CalendarTrash(ctx, tid, calMember, calT0); len(tr) != 0 {
				t.Fatalf("trash after restore: %+v", tr)
			}
		})
	}
}

// calAssertHidden: a deleted event is on no read but the trash, and cannot
// be changed.
func calAssertHidden(t *testing.T, cal Calendar, tid, id string) {
	t.Helper()
	ctx := context.Background()
	if _, err := cal.GetCalendarEvent(ctx, tid, calOwner, id); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get a deleted event: %v", err)
	}
	if evs, _ := cal.ListCalendarEvents(ctx, tid, calOwner, calWeek()); strings.Contains(calIDs(evs), "undo") {
		t.Fatalf("range holds a deleted event: %s", calIDs(evs))
	}
	if ms, _ := cal.CalendarMarks(ctx, tid, calOwner, calWeek()); len(ms) != 1 || ms[0].Count != 1 {
		t.Fatalf("marks count a deleted event: %+v", ms)
	}
	if rs, _ := cal.CalendarReminders(ctx, tid, calOwner, calWeek()); len(rs) != 0 {
		t.Fatalf("a deleted event reminds: %+v", rs)
	}
	title := "x"
	if _, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, id, CalendarPatch{Title: &title}, calT0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("patch a deleted event: %v", err)
	}
}

// AC-08: workspace B can neither restore A's deleted event nor see it in
// its trash, even as the same viewer id.
func TestCalendarCrossTenantRestore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal := st.(Calendar)
			a, b := newTenant(t, st), newTenant(t, st)
			e, err := cal.CreateCalendarEvent(ctx, a, calEvent("a-only"), calT0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := cal.TrashCalendarEvent(ctx, b, calOwner, e.ID, time.Time{}, calT0); !errors.Is(err, ErrNotFound) {
				t.Fatalf("B deletes A's event: %v", err)
			}
			if _, err := cal.TrashCalendarEvent(ctx, a, calOwner, e.ID, time.Time{}, calT0); err != nil {
				t.Fatal(err)
			}
			if tr, _ := cal.CalendarTrash(ctx, b, calOwner, calT0); len(tr) != 0 {
				t.Fatalf("B's trash holds A's event: %+v", tr)
			}
			if _, err := cal.RestoreCalendarEvent(ctx, b, calOwner, e.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("B restores A's event: %v", err)
			}
			if _, err := cal.CalendarTrash(ctx, "", calOwner, calT0); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v", err)
			}
			if _, err := cal.RestoreCalendarEvent(ctx, a, calOwner, e.ID); err != nil {
				t.Fatalf("CONTROL: A restores its own event: %v", err)
			}
		})
	}
}

// Until rdb 0139 reaches a database the Postgres store answers 089's shape:
// props {} and UTC, a hard delete, nothing in the trash, never a 500.
func TestCalendarProbeMissingColumns(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	t.Cleanup(func() { pg.calEdit = seatsProbe{} })
	pg.calEdit = seatsProbe{check: func(context.Context) (bool, error) { return false, nil }}
	in := calEvent("089 hub shape")
	in.Props, in.TimeZone = calProps(), "Europe/Helsinki"
	e, err := pg.CreateCalendarEvent(ctx, tid, in, calT0)
	if err != nil || e.TimeZone != CalendarUTC || len(e.Props) != 0 {
		t.Fatalf("create without 0139: %+v %v", e, err)
	}
	title := "patched"
	if got, err := pg.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{Title: &title, IfUpdatedAt: e.UpdatedAt}, calT0); err != nil || got.Title != title {
		t.Fatalf("patch without 0139: %+v %v", got, err)
	}
	if _, err := pg.TrashCalendarEvent(ctx, tid, calOwner, e.ID, time.Time{}, calT0); err != nil {
		t.Fatalf("delete without 0139: %v", err)
	}
	if tr, err := pg.CalendarTrash(ctx, tid, calOwner, calT0); err != nil || len(tr) != 0 {
		t.Fatalf("trash without 0139: %+v %v", tr, err)
	}
	if _, err := pg.RestoreCalendarEvent(ctx, tid, calOwner, e.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("restore without 0139: %v", err)
	}
	// the delete was 089's hard delete: with the columns back, no row at all
	pg.calEdit = seatsProbe{}
	if _, err := pg.RestoreCalendarEvent(ctx, tid, calOwner, e.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("CONTROL restore with 0139: %v", err)
	}
	var n int
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM calendar_events WHERE event_id = $1::uuid`, e.ID).Scan(&n)
	}); err != nil || n != 0 {
		t.Fatalf("a hard delete left %d rows: %v", n, err)
	}
	if got, err := pg.CreateCalendarEvent(ctx, tid, in, calT0); err != nil || got.TimeZone != "Europe/Helsinki" {
		t.Fatalf("CONTROL create with 0139: %+v %v", got, err)
	}
}
