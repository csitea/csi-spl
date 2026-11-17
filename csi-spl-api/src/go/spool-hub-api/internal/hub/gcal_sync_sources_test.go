package hub_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"maps"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal/fakegcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Owner poll d93654e1 B (SPL-3852, spec 149 section 2.10): the member's
// existing Google calendars (primary, a team calendar) come into Spool
// read-only, as the member's private events, when the cnf scopes hold a read
// scope. Against fakegcal; memory, and Postgres under SPOOL_TEST_PG_DSN.

// gcalSources is a sync env reading existing calendars, with the member's
// primary calendar and a team calendar on the fake, one event in each, and
// a hidden calendar with one event.
type gcalSources struct {
	*gcalSyncEnv
	hum, primary, team, hidden string
}

func gcalSourcesOf(t *testing.T) *gcalSources {
	t.Helper()
	se := gcalSyncEnvOf(t)
	se.gc.ReadCalendars = true
	gs := &gcalSources{gcalSyncEnv: se, hum: se.member(t)}
	gs.primary = se.fake.AddCalendar(fakegcal.DefaultEmail, fakegcal.DefaultEmail, true)
	gs.team = se.fake.AddCalendar(fakegcal.DefaultEmail, "CSITEA", false)
	gs.hidden = se.fake.AddCalendar(fakegcal.DefaultEmail, "Holidays", false)
	se.fake.SelectCalendar(gs.hidden, false)
	gs.add(t, gs.primary, "Standup")
	gs.add(t, gs.team, "Team review")
	gs.add(t, gs.hidden, "Bank holiday")
	return gs
}

// add writes an event at Google, a day after the clock.
func (gs *gcalSources) add(t *testing.T, cal, summary string) gcal.Event {
	t.Helper()
	at := gs.clock.now().Add(24 * time.Hour)
	ev, err := gs.fake.AddEvent(cal, gcal.Event{Summary: summary, Status: "confirmed",
		Start: gcal.EventTime{DateTime: at}, End: gcal.EventTime{DateTime: at.Add(time.Hour)}})
	if err != nil {
		t.Fatal(err)
	}
	return ev
}

// titles answers the titles of the live events viewer reads in the
// workspace, sorted.
func (gs *gcalSources) titles(t *testing.T, viewer string) []string {
	t.Helper()
	evs, err := gs.st.(store.CalendarSearch).SearchCalendarEvents(context.Background(), gs.tid, viewer,
		store.CalendarQuery{Range: store.CalendarRange{Start: gcalSyncT0.AddDate(-1, 0, 0), End: gcalSyncT0.AddDate(1, 0, 0)}})
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range evs {
		out = append(out, e.Title)
	}
	slices.Sort(out)
	return out
}

func (gs *gcalSources) cycle(t *testing.T) {
	t.Helper()
	gs.next()
	if !gs.gcalSyncEnv.cycle(t) {
		t.Fatal("the due connection was not claimed")
	}
}

// B: the primary and the team calendar come in as the member's private
// events; the hidden one does not; another member reads none of them;
// nothing is written to those calendars, and the out half does not copy the
// imports into the "Spool Hub" calendar.
func TestGcalSourcesImportExistingCalendars(t *testing.T) {
	gs := gcalSourcesOf(t)
	gs.cycle(t)
	if got := gs.titles(t, gs.hum); !slices.Equal(got, []string{"Standup", "Team review"}) {
		t.Fatalf("member's events %v, want Standup and Team review", got)
	}
	other := seat(t, gs.env, gs.tid, rbac.Developer)
	if got := gs.titles(t, other); len(got) != 0 {
		t.Fatalf("another member reads %v, want none", got)
	}
	c := gs.conn(t, gs.hum)
	if got := gs.fake.Events(c.CalendarID); len(got) != 0 {
		t.Fatalf("the Spool Hub calendar got %+v, want none (imports never go back out)", got)
	}
	if len(gs.fake.Events(gs.primary)) != 1 || len(gs.fake.Events(gs.team)) != 1 {
		t.Fatal("an existing calendar was written to")
	}
	if len(c.SourceSync) != 2 || c.SourceSync[gs.primary] == "" || c.SourceSync[gs.team] == "" {
		t.Fatalf("source_sync %v, want a token for the primary and the team calendar", c.SourceSync)
	}
	if c.StatusDetail != "" {
		t.Fatalf("status detail %q, want none", c.StatusDetail)
	}
	// a second cycle with no change at Google writes nothing
	before := gs.titles(t, gs.hum)
	gs.cycle(t)
	if got := gs.titles(t, gs.hum); !slices.Equal(got, before) {
		t.Fatalf("second cycle: %v, want %v", got, before)
	}
}

// B, the changes: an edit at Google comes in on the sync token, a cancel
// trashes the import, a 410 lists in full without a duplicate, and a
// calendar the member stops showing takes its imports with it.
func TestGcalSourcesFollowGoogleChanges(t *testing.T) {
	gs := gcalSourcesOf(t)
	late := gs.add(t, gs.primary, "Retro")
	gs.cycle(t)
	evs := gs.fake.Events(gs.primary)
	standup := evs[slices.IndexFunc(evs, func(e gcal.Event) bool { return e.Summary == "Standup" })]
	if err := gs.fake.UpdateEvent(gs.primary, standup.ID, func(e *gcal.Event) { e.Summary = "Standup, moved" }); err != nil {
		t.Fatal(err)
	}
	if err := gs.fake.CancelEvent(gs.primary, late.ID); err != nil {
		t.Fatal(err)
	}
	gs.cycle(t)
	if got := gs.titles(t, gs.hum); !slices.Equal(got, []string{"Standup, moved", "Team review"}) {
		t.Fatalf("after the edit and the cancel: %v", got)
	}
	gs.fake.ExpireSyncTokens(gs.team)
	gs.cycle(t)
	if got := gs.titles(t, gs.hum); !slices.Equal(got, []string{"Standup, moved", "Team review"}) {
		t.Fatalf("after a 410: %v, want no duplicate", got)
	}
	gs.fake.SelectCalendar(gs.team, false)
	gs.cycle(t)
	if got := gs.titles(t, gs.hum); !slices.Equal(got, []string{"Standup, moved"}) {
		t.Fatalf("after hiding the team calendar: %v", got)
	}
	if c := gs.conn(t, gs.hum); len(c.SourceSync) != 1 {
		t.Fatalf("source_sync %v, want the primary calendar only", c.SourceSync)
	}
}

// B is off without a read scope: no calendar list call, nothing imported
// (the red control of the gate: with ReadCalendars on, TestGcalSources*
// import).
func TestGcalSourcesOffWithoutReadScope(t *testing.T) {
	gs := gcalSourcesOf(t)
	gs.gc.ReadCalendars = false
	gs.cycle(t)
	if n := gs.fake.Calls("calendarList.list"); n != 0 {
		t.Fatalf("calendarList.list %d times without a read scope", n)
	}
	if got := gs.titles(t, gs.hum); len(got) != 0 {
		t.Fatalf("imported %v without a read scope", got)
	}
}

// B: disconnect with remove_imported=1 trashes the read-only imports too.
func TestGcalSourcesDisconnectRemovesImports(t *testing.T) {
	gs := gcalSourcesOf(t)
	gs.cycle(t)
	if got := gs.titles(t, gs.hum); len(got) != 2 { // else the check below passes on an empty import
		t.Fatalf("before disconnect: %v, want the two imports", got)
	}
	if resp := gcalDo(t, gs.gcalTestEnv, gs.tid, http.MethodDelete, "/v1/me/google-calendar?remove_imported=1", gs.hum); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("disconnect: %d, want 204", resp.StatusCode)
	}
	if got := gs.titles(t, gs.hum); len(got) != 0 {
		t.Fatalf("after disconnect with remove_imported=1: %v, want none", got)
	}
}

func TestGcalReadsCalendars(t *testing.T) {
	for scopes, want := range map[string]bool{
		"openid email https://www.googleapis.com/auth/calendar.app.created":                                                   false,
		"openid email https://www.googleapis.com/auth/calendar.app.created https://www.googleapis.com/auth/calendar.readonly": true,
		"openid email https://www.googleapis.com/auth/calendar":                                                               true,
		"openid email https://www.googleapis.com/auth/calendar.events.readonly":                                               false,
	} {
		if got := hub.GcalReadsCalendars(scopes); got != want {
			t.Errorf("GcalReadsCalendars(%q) = %v, want %v", scopes, got, want)
		}
	}
}

// gcalTwoHubs is a member of two workspaces who connects both with the same
// Google account (SPL-5782): two "Spool Hub" calendars on one Google
// calendar list, next to the primary and the team calendar, one private
// Spool event in each workspace, synced out.
type gcalTwoHubs struct {
	*gcalSources
	tidB, humB string
}

func gcalTwoHubsOf(t *testing.T) *gcalTwoHubs {
	t.Helper()
	ids := mktIDs(2)
	se := gcalSyncEnvIn(t, ids)
	se.gc.ReadCalendars = true
	gs := &gcalSources{gcalSyncEnv: se, hum: se.member(t)}
	gs.primary = se.fake.AddCalendar(fakegcal.DefaultEmail, fakegcal.DefaultEmail, true)
	gs.team = se.fake.AddCalendar(fakegcal.DefaultEmail, "CSITEA", false)
	gs.add(t, gs.primary, "Standup")
	gs.add(t, gs.team, "Team review")
	th := &gcalTwoHubs{gcalSources: gs, tidB: ids[1]}
	th.humB = seat(t, se.env, th.tidB, rbac.Developer)
	gcalConnectMember(t, se.gcalTestEnv, th.tidB, th.humB)
	t.Cleanup(func() {
		se.st.(store.Gcal).DeleteGcalConnection(context.Background(), th.tidB, th.humB) //nolint:errcheck // gone is fine
	})
	ctx, now := context.Background(), se.clock.now()
	for _, m := range []struct{ tid, hum, title string }{{gs.tid, gs.hum, "Plan A"}, {th.tidB, th.humB, "Plan B"}} {
		if _, err := se.st.(store.Calendar).CreateCalendarEvent(ctx, m.tid, store.CalendarEvent{Title: m.title, Kind: "other",
			Audience: store.CalendarPrivate, CreatorType: "human", CreatorID: m.hum,
			StartsAt: now.Add(24 * time.Hour), EndsAt: now.Add(25 * time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
	}
	for range 4 { // both connections, twice: hub calendars made and filled, then read
		gs.cycle(t)
	}
	a, b := th.conn(t, gs.hum), th.connB(t)
	if a.CalendarID == "" || b.CalendarID == "" || a.CalendarID == b.CalendarID {
		t.Fatalf("hub calendars %q and %q, want two", a.CalendarID, b.CalendarID)
	}
	if len(gs.fake.Events(a.CalendarID)) != 1 || len(gs.fake.Events(b.CalendarID)) != 1 {
		t.Fatal("a workspace's event did not reach its hub calendar") // else no copy could come back
	}
	return th
}

func (th *gcalTwoHubs) connB(t *testing.T) store.GcalConnection {
	t.Helper()
	c, err := gcalRow(t, th.gcalTestEnv, th.tidB, th.humB)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// titlesB is titles in workspace B.
func (th *gcalTwoHubs) titlesB(t *testing.T) []string {
	t.Helper()
	tid := th.tid
	th.tid = th.tidB
	defer func() { th.tid = tid }()
	return th.titles(t, th.humB)
}

// SPL-5782: a hub calendar of the member's other workspace is never read in
// as an existing calendar: each workspace holds its own event and the
// imports, never the other workspace's event as a private copy.
func TestGcalSourcesSkipOtherHubCalendars(t *testing.T) {
	th := gcalTwoHubsOf(t)
	if got := th.titles(t, th.hum); !slices.Equal(got, []string{"Plan A", "Standup", "Team review"}) {
		t.Errorf("workspace A: %v, want Plan A, Standup and Team review", got)
	}
	if got := th.titlesB(t); !slices.Equal(got, []string{"Plan B", "Standup", "Team review"}) {
		t.Errorf("workspace B: %v, want Plan B, Standup and Team review", got)
	}
	a, b := th.conn(t, th.hum), th.connB(t)
	for _, c := range []store.GcalConnection{a, b} {
		if _, ok := c.SourceSync[a.CalendarID]; ok {
			t.Errorf("connection %s reads hub calendar %s", c.ID, a.CalendarID)
		}
		if _, ok := c.SourceSync[b.CalendarID]; ok {
			t.Errorf("connection %s reads hub calendar %s", c.ID, b.CalendarID)
		}
	}
}

// SPL-5782, the copies a build without the skip already made: a source
// entry and an import of the other workspace's hub calendar leave on the
// next cycle (sweepSources).
func TestGcalSourcesSweepOtherHubCopies(t *testing.T) {
	th := gcalTwoHubsOf(t)
	ctx, now := context.Background(), th.clock.now()
	a, b := th.conn(t, th.hum), th.connB(t)
	g := th.st.(store.Gcal)
	_, l, err := g.ClaimGcalMember(ctx, th.tidB, th.humB, now, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	src := maps.Clone(b.SourceSync)
	src[a.CalendarID] = ""
	if err := g.FinishGcalSync(ctx, l, store.GcalSyncDone{SyncToken: b.SyncToken, SourceSync: src, NextDue: now}, now); err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256([]byte(a.CalendarID))
	key := "gcal:" + b.ID + ":src." + hex.EncodeToString(h[:6]) + ".legacy1"
	if _, err := th.st.(store.GcalImport).PutGcalImported(ctx, th.tidB, key, store.CalendarEvent{Title: "Plan A", Kind: "other",
		Audience: store.CalendarPrivate, CreatorType: "human", CreatorID: th.humB,
		StartsAt: now.Add(24 * time.Hour), EndsAt: now.Add(25 * time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	if got := th.titlesB(t); !slices.Contains(got, "Plan A") { // else the check below passes on no copy
		t.Fatalf("workspace B before the cycle: %v, want the legacy copy Plan A", got)
	}
	th.cycle(t)
	th.cycle(t)
	if got := th.titlesB(t); !slices.Equal(got, []string{"Plan B", "Standup", "Team review"}) {
		t.Errorf("workspace B after a cycle: %v, want Plan B, Standup and Team review", got)
	}
	if _, ok := th.connB(t).SourceSync[a.CalendarID]; ok {
		t.Errorf("source_sync still holds hub calendar %s", a.CalendarID)
	}
}
