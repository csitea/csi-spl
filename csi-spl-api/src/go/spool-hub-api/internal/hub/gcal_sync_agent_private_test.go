package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-5720: an agent's private entry for a member follows the hub row into
// that member's Google Calendar, with no second path. The operator PATCH and
// DELETE (calendar_operator_write.go) write through UpdateCalendarEvent and
// TrashCalendarScope as the person (ordered_by); this test makes the same two
// store calls. The out half inserts the entry, patches it once after the
// change, and deletes it at Google after the trash. CONTROL: an agent's
// private entry for another member never reaches this member's calendar.
// Memory, and Postgres under SPOOL_TEST_PG_DSN.
func TestGcalSyncFollowsAgentPrivateReplace(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	other := seat(t, se.env, se.tid, rbac.Developer) // not connected: GcalSyncOnce syncs one connection a call
	agentFor := func(person, title string) store.CalendarEvent {
		return se.event(t, "c-840", title, func(e *store.CalendarEvent) {
			e.CreatorType, e.Mentions, e.OwnerID = "agent", []string{person}, person
		})
	}
	ev := agentFor(hum, "Trip")
	agentFor(other, "Not hers")
	se.cycle(t)
	cal := se.conn(t, hum).CalendarID
	if got := se.fake.Events(cal); len(got) != 1 || got[0].Summary != "Trip" || got[0].Visibility != "private" {
		t.Fatalf("google events after the insert: %+v, want only Trip, private", got)
	}
	gid := se.maps(t, hum)[0].GoogleID

	se.next()
	title := "Trip, 15 min alert"
	props := map[string]any{"reminders": []any{map[string]any{"amount": float64(15), "unit": "minutes", "method": "popup"}}}
	if _, err := se.st.(store.Calendar).UpdateCalendarEvent(context.Background(), se.tid, hum, ev.ID,
		store.CalendarPatch{Title: &title, Props: &props}, se.clock.now()); err != nil {
		t.Fatal(err)
	}
	se.fake.ResetCalls()
	se.cycle(t)
	if p, i := se.fake.Calls("events.patch"), se.fake.Calls("events.insert"); p != 1 || i != 0 {
		t.Fatalf("after the change: %d patch, %d insert; want 1, 0", p, i)
	}
	if got := se.fake.Events(cal); len(got) != 1 || got[0].Summary != title {
		t.Fatalf("google events after the change: %+v, want one %q", got, title)
	}

	se.next()
	if _, err := se.st.(store.Calendar).TrashCalendarScope(context.Background(), se.tid, hum, ev.ID, "", time.Time{}, se.clock.now()); err != nil {
		t.Fatal(err)
	}
	se.fake.ResetCalls()
	se.cycle(t)
	if n := se.fake.Calls("events.delete"); n != 1 {
		t.Fatalf("events.delete %d times after the trash, want 1", n)
	}
	if g, ok := se.fake.Event(cal, gid); !ok || g.Status != "cancelled" {
		t.Fatalf("google event %s after the trash: %+v (found %v), want cancelled", gid, g, ok)
	}
}
