package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 149 B6b (SPL-3339): the sync cycle's Google -> Spool half against
// fakegcal; no test reaches Google. Cases C15-C19 of spec 149 section 5,
// the Google-side delete, and the guard that the member route PUT
// /v1/calendar/sync still refuses a gcal: key (the import has its own store
// entry point). Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full). The env and its helpers are B6a's (gcal_sync_test.go).

// inEnv is a member connected and synced once, so the target calendar exists.
func inEnv(t *testing.T) (*gcalSyncEnv, string, string) {
	t.Helper()
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	se.cycle(t)
	cal := se.conn(t, hum).CalendarID
	if cal == "" {
		t.Fatal("the first cycle created no target calendar")
	}
	se.next()
	return se, hum, cal
}

// gev is a Google event two days after the clock, an hour long.
func (se *gcalSyncEnv) gev(summary string) gcal.Event {
	at := se.clock.now().Add(48 * time.Hour)
	return gcal.Event{Summary: summary, Start: gcal.EventTime{DateTime: at, TimeZone: "Europe/Helsinki"},
		End: gcal.EventTime{DateTime: at.Add(time.Hour), TimeZone: "Europe/Helsinki"}}
}

// add writes ev on the Google side of cal.
func (se *gcalSyncEnv) add(t *testing.T, cal string, ev gcal.Event) gcal.Event {
	t.Helper()
	out, err := se.fake.AddEvent(cal, ev)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// imported lists hum's live events that came from this connection.
func (se *gcalSyncEnv) imported(t *testing.T, hum string) []store.CalendarEvent {
	t.Helper()
	evs, err := se.st.(store.CalendarSourced).CalendarBySourceKey(context.Background(), se.tid, hum, "gcal:"+se.conn(t, hum).ID+":")
	if err != nil {
		t.Fatal(err)
	}
	return evs
}

func (se *gcalSyncEnv) spoolEvent(t *testing.T, hum, id string) store.CalendarEvent {
	t.Helper()
	ev, err := se.st.(store.Calendar).GetCalendarEvent(context.Background(), se.tid, hum, id)
	if err != nil {
		t.Fatal(err)
	}
	return ev
}

// C15: a new event on the Google side becomes the member's private Spool
// event, keyed gcal:<connection>:<google id>, with a map row; the out half
// never writes it back to Google, in this cycle or the next.
func TestGcalSyncInImportsGoogleEvent(t *testing.T) {
	se, hum, cal := inEnv(t)
	g := se.add(t, cal, se.gev("Dentist"))
	se.fake.ResetCalls()
	se.cycle(t)
	conn := se.conn(t, hum)
	got := se.imported(t, hum)
	want := "gcal:" + conn.ID + ":" + g.ID
	if len(got) != 1 || got[0].Title != "Dentist" || got[0].Audience != store.CalendarPrivate || got[0].CreatorType != "human" ||
		got[0].CreatorID != hum || got[0].SourceKey != want || got[0].Kind != "other" || got[0].TimeZone != "Europe/Helsinki" ||
		!got[0].StartsAt.Equal(g.Start.DateTime) {
		t.Fatalf("imported %+v, want one private Dentist of %s keyed %s", got, hum, want)
	}
	m := se.maps(t, hum)
	if len(m) != 1 || m[0].EventID != got[0].ID || m[0].GoogleID != g.ID || m[0].SyncHash != hub.GcalSyncHash(got[0]) {
		t.Fatalf("map rows %+v, want %s -> %s", m, got[0].ID, g.ID)
	}
	if n := se.fake.Calls("events.insert") + se.fake.Calls("events.patch"); n != 0 {
		t.Fatalf("the out half wrote the import back to google: %d calls", n)
	}
	if conn.SyncToken == "" {
		t.Fatal("no sync token stored after the in half")
	}
	se.next()
	se.fake.ResetCalls()
	se.cycle(t)
	if n := se.fake.Calls("events.insert") + se.fake.Calls("events.patch") + se.fake.Calls("events.delete"); n != 0 {
		t.Fatalf("the next cycle wrote %d times to google, want 0", n)
	}
	if again := se.imported(t, hum); len(again) != 1 || !again[0].UpdatedAt.Equal(got[0].UpdatedAt) {
		t.Fatalf("the next cycle rewrote the import: %+v", again)
	}
}

// C15b: a Google event with an empty summary is stored with the placeholder
// title (the WUI's i18n key), and the cycle completes.
func TestGcalSyncInEmptySummary(t *testing.T) {
	se, hum, cal := inEnv(t)
	se.add(t, cal, se.gev(""))
	se.cycle(t)
	got := se.imported(t, hum)
	if len(got) != 1 || got[0].Title != hub.GcalUntitled {
		t.Fatalf("imported %+v, want one titled %q", got, hub.GcalUntitled)
	}
	if c := se.conn(t, hum); c.StatusDetail != "" || c.SyncLeaseUntil != nil || c.LastSyncedAt == nil {
		t.Fatalf("the cycle did not complete: detail %q, lease %v, last %v", c.StatusDetail, c.SyncLeaseUntil, c.LastSyncedAt)
	}
}

// C15c: a changed occurrence of a Google series (recurringEventId) is
// skipped: no Spool row. Twin: the series in the same list comes in, so the
// list was read.
func TestGcalSyncInSkipsGoogleOccurrence(t *testing.T) {
	se, hum, cal := inEnv(t)
	series := se.gev("Yoga")
	series.Recurrence = []string{"RRULE:FREQ=WEEKLY;COUNT=4"}
	s := se.add(t, cal, series)
	occ := se.gev("Yoga, moved")
	occ.RecurringEventID = s.ID
	se.add(t, cal, occ)
	se.cycle(t)
	got := se.imported(t, hum)
	if len(got) != 1 || got[0].Title != "Yoga" || got[0].RRule != "FREQ=WEEKLY;COUNT=4" {
		t.Fatalf("imported %+v, want the series only, with its rule", got)
	}
}

// C16: another member of the same workspace listing the calendar does not
// see the import. Twin: the connecting member does, so the check does not
// pass on an empty import.
func TestGcalSyncInPrivateToMember(t *testing.T) {
	se, hum, cal := inEnv(t)
	se.add(t, cal, se.gev("Dentist"))
	se.cycle(t)
	mate := seat(t, se.env, se.tid, rbac.Developer)
	from := se.clock.now()
	q := "/v1/calendar/events?start=" + from.Format(time.RFC3339) + "&end=" + from.Add(7*24*time.Hour).Format(time.RFC3339)
	code, own := call(t, se.env, se.tid, http.MethodGet, q, hum, nil)
	if code != http.StatusOK || !strings.Contains(","+calTitles(own, "events")+",", ",Dentist,") {
		t.Fatalf("the connecting member lists %d %v, want Dentist", code, own)
	}
	code, other := call(t, se.env, se.tid, http.MethodGet, q, mate, nil)
	if code != http.StatusOK || strings.Contains(calTitles(other, "events"), "Dentist") {
		t.Fatalf("another member lists %d %v, want no Dentist", code, other)
	}
}

// C17: echo. After C13 the fake lists the out half's own write back: no
// Spool write. The same when Google only moved the etag (content equal:
// the sync hash catches it). The in half did list (events.list), so the
// check does not pass on a cycle that never read Google.
func TestGcalSyncInEcho(t *testing.T) {
	se, hum, cal := inEnv(t)
	ev := se.event(t, hum, "Planning", nil)
	se.cycle(t)
	before := se.maps(t, hum)
	if len(before) != 1 {
		t.Fatalf("map rows %+v, want the pushed event", before)
	}
	for _, step := range []string{"own write listed back", "etag moved, same content"} {
		if step == "etag moved, same content" {
			if err := se.fake.UpdateEvent(cal, before[0].GoogleID, func(*gcal.Event) {}); err != nil {
				t.Fatal(err)
			}
		}
		se.next()
		se.fake.ResetCalls()
		se.cycle(t)
		if n := se.fake.Calls("events.list"); n != 1 {
			t.Fatalf("%s: events.list %d times, want 1", step, n)
		}
		if got := se.spoolEvent(t, hum, ev.ID); !got.UpdatedAt.Equal(ev.UpdatedAt) || got.Title != "Planning" {
			t.Fatalf("%s: the spool event was written: %+v", step, got)
		}
		if imp := se.imported(t, hum); len(imp) != 0 {
			t.Fatalf("%s: the echo was imported: %+v", step, imp)
		}
		if n := se.fake.Calls("events.patch") + se.fake.Calls("events.insert"); n != 0 {
			t.Fatalf("%s: %d writes to google, want 0", step, n)
		}
	}
}

// The idle cycle: with nothing changed on either side, the In half lists
// once with the stored sync token (events.list, exactly 1) and nothing
// writes or authorizes (gcalWriteCalls, 0). B6a's C14 and C13b count only
// gcalWriteCalls; this test holds the list to one per cycle.
func TestGcalSyncInIdleListsOnce(t *testing.T) {
	se, hum, _ := inEnv(t)
	se.event(t, hum, "Planning", nil)
	se.cycle(t)
	for i := range 2 {
		se.next()
		se.fake.ResetCalls()
		if !se.cycle(t) {
			t.Fatal("the connection was not due again")
		}
		if l, n := se.fake.Calls("events.list"), se.calls(); l != 1 || n != 0 {
			t.Fatalf("idle cycle %d: %d events.list, %d other calls; want 1 and 0", i+1, l, n)
		}
	}
}

// conflictEnv is a Spool event pushed to Google, then edited on both sides:
// in Spool, the clock moved by gap, then at Google.
func conflictEnv(t *testing.T, gap time.Duration) (*gcalSyncEnv, string, string, store.CalendarEvent, string) {
	t.Helper()
	se, hum, cal := inEnv(t)
	ev := se.event(t, hum, "Planning", nil)
	se.cycle(t)
	gid := se.maps(t, hum)[0].GoogleID
	se.next()
	spool := "Spool edit"
	if _, err := se.st.(store.Calendar).UpdateCalendarEvent(context.Background(), se.tid, hum, ev.ID,
		store.CalendarPatch{Title: &spool}, se.clock.now()); err != nil {
		t.Fatal(err)
	}
	se.clock.add(gap)
	if err := se.fake.UpdateEvent(cal, gid, func(e *gcal.Event) { e.Summary = "Google edit" }); err != nil {
		t.Fatal(err)
	}
	se.next()
	se.fake.ResetCalls()
	se.cycle(t)
	return se, hum, cal, ev, gid
}

// C18: both sides edited, Google later: Google's values are in Spool, and
// neither this cycle nor the next PATCHes Google.
func TestGcalSyncInConflictGoogleNewer(t *testing.T) {
	se, hum, cal, ev, gid := conflictEnv(t, 10*time.Second)
	if got := se.spoolEvent(t, hum, ev.ID); got.Title != "Google edit" {
		t.Fatalf("spool title %q, want Google's", got.Title)
	}
	if n := se.fake.Calls("events.patch"); n != 0 {
		t.Fatalf("the cycle patched google %d times, want 0", n)
	}
	se.next()
	se.fake.ResetCalls()
	se.cycle(t)
	if n := se.fake.Calls("events.patch"); n != 0 {
		t.Fatalf("the next cycle patched google %d times, want 0", n)
	}
	if g, _ := se.fake.Event(cal, gid); g.Summary != "Google edit" {
		t.Fatalf("google summary %q, want Google edit", g.Summary)
	}
}

// C18 twin: Spool's edit is the newer one, or a tie (the same instant):
// Spool wins, its value goes to Google in one PATCH.
func TestGcalSyncInConflictSpoolWins(t *testing.T) {
	for name, gap := range map[string]time.Duration{"spool newer": -10 * time.Second, "tie": 0} {
		t.Run(name, func(t *testing.T) {
			se, hum, cal, ev, gid := conflictEnv(t, gap)
			if got := se.spoolEvent(t, hum, ev.ID); got.Title != "Spool edit" {
				t.Fatalf("spool title %q, want Spool's", got.Title)
			}
			if g, _ := se.fake.Event(cal, gid); g.Summary != "Spool edit" || se.fake.Calls("events.patch") != 1 {
				t.Fatalf("google summary %q after %d patches, want Spool edit after 1", g.Summary, se.fake.Calls("events.patch"))
			}
		})
	}
}

// C19: Google refuses the sync token (410): it is cleared, the calendar is
// listed in full, and nothing is duplicated, neither the import nor the
// Spool event the out half wrote.
func TestGcalSyncInSyncTokenGone(t *testing.T) {
	se, hum, cal := inEnv(t)
	se.event(t, hum, "Planning", nil)
	se.add(t, cal, se.gev("Dentist"))
	se.cycle(t)
	old := se.conn(t, hum).SyncToken
	if old == "" || len(se.imported(t, hum)) != 1 {
		t.Fatalf("setup: token %q, imports %+v", old, se.imported(t, hum))
	}
	se.fake.ExpireSyncTokens(cal)
	se.add(t, cal, se.gev("Gym"))
	se.next()
	se.fake.ResetCalls()
	se.cycle(t)
	if n := se.fake.Calls("events.list"); n != 2 {
		t.Fatalf("events.list %d times, want 2 (the 410, then in full)", n)
	}
	titles := map[string]int{}
	for _, e := range se.imported(t, hum) {
		titles[e.Title]++
	}
	if len(titles) != 2 || titles["Dentist"] != 1 || titles["Gym"] != 1 {
		t.Fatalf("imports after the 410: %v, want Dentist and Gym once each", titles)
	}
	if n := len(se.fake.Events(cal)); n != 3 || len(se.maps(t, hum)) != 3 {
		t.Fatalf("google holds %d events, %d map rows; want 3 and 3", n, len(se.maps(t, hum)))
	}
	if c := se.conn(t, hum); c.SyncToken == "" || c.SyncToken == old {
		t.Fatalf("sync token %q after the full list (old %q)", c.SyncToken, old)
	}
}

// A delete at Google (status cancelled) trashes the import and the member's
// own Spool event (a delete beats an edit), and drops their map rows.
func TestGcalSyncInGoogleDelete(t *testing.T) {
	se, hum, cal := inEnv(t)
	ev := se.event(t, hum, "Planning", nil)
	g := se.add(t, cal, se.gev("Dentist"))
	se.cycle(t)
	imp := se.imported(t, hum)
	if len(imp) != 1 || len(se.maps(t, hum)) != 2 {
		t.Fatalf("setup: imports %+v, maps %+v", imp, se.maps(t, hum))
	}
	for _, m := range se.maps(t, hum) {
		if err := se.fake.CancelEvent(cal, m.GoogleID); err != nil {
			t.Fatal(err)
		}
	}
	se.next()
	se.cycle(t)
	if got := se.imported(t, hum); len(got) != 0 {
		t.Fatalf("the import of %s is still live: %+v", g.ID, got)
	}
	if _, err := se.st.(store.Calendar).GetCalendarEvent(context.Background(), se.tid, hum, ev.ID); err == nil {
		t.Fatal("the member's own event is still live after its delete at google")
	}
	if m := se.maps(t, hum); len(m) != 0 {
		t.Fatalf("map rows after the deletes: %+v", m)
	}
}

// The import has its own store entry point: the member route PUT
// /v1/calendar/sync (spec 112) still refuses a gcal: key, and writes nothing.
func TestGcalSyncKeyNotOnSyncRoute(t *testing.T) {
	e, tid := syncEnv(t)
	key := "gcal:00000000-0000-4000-8000-000000000000:ev1"
	code, out := syncCall(t, e, tid, nil, []map[string]any{syncEv(tid, key, "2026-10-06")})
	if code != http.StatusBadRequest {
		t.Fatalf("PUT %s with a gcal: key: %d %v, want 400", syncPath, code, out)
	}
	if got := liveKeys(t, e, tid); got != "" {
		t.Fatalf("live synced keys %q, want none", got)
	}
}
