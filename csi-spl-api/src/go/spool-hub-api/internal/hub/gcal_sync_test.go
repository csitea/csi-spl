package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal/fakegcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 149 B6a (SPL-3226): the sync cycle's Spool -> Google half, its claim,
// lease and token refresh, against fakegcal and a fake KMS; no test reaches
// Google. Cases C13, C13b, C13c, C14, C20 and C21 of spec 149 section 5,
// plus the kill switch (2.9). Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full).
//
// The clock starts in the past (gcalSyncT0): a claim takes only rows due by
// then, so the connections the B5 tests leave in a shared Postgres are never
// claimed here: those are due at the wall clock, or 20 years before it
// (TestGcalDisconnect), both after 2001.

var gcalSyncT0 = time.Date(2001, 3, 2, 9, 0, 0, 0, time.UTC)

// gcalWriteCalls are the fake's calls that write or authorize.
var gcalWriteCalls = []string{"token", "calendars.insert", "events.insert", "events.patch", "events.delete", "calendars.get"}

// gcalHookRT runs fn before each request to the fake.
type gcalHookRT struct {
	base http.RoundTripper
	mu   sync.Mutex
	fn   func(*http.Request)
}

func (h *gcalHookRT) RoundTrip(r *http.Request) (*http.Response, error) {
	h.mu.Lock()
	fn := h.fn
	h.mu.Unlock()
	if fn != nil {
		fn(r)
	}
	return h.base.RoundTrip(r)
}

func (h *gcalHookRT) set(fn func(*http.Request)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.fn = fn
}

type gcalSyncEnv struct {
	*gcalTestEnv
	tid  string
	hook *gcalHookRT
}

// gcalSyncEnvOf is one listed workspace on the fake Google, the clock at
// gcalSyncT0, every request to the fake through a hook.
func gcalSyncEnvOf(t *testing.T) *gcalSyncEnv {
	t.Helper()
	ids := mktIDs(1)
	e := gcalEnvOf(t, ids, ids...)
	e.clock.mu.Lock()
	e.clock.t = gcalSyncT0
	e.clock.mu.Unlock()
	cfg := e.fake.Config(gcalApp+hub.GcalCallbackPath, gcalTestScopes)
	hook := &gcalHookRT{base: cfg.HTTP.Transport}
	cfg.HTTP = &http.Client{Transport: hook}
	google, err := gcal.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	e.gc.Google = google
	return &gcalSyncEnv{gcalTestEnv: e, tid: ids[0], hook: hook}
}

// member seats a developer and connects their Google Calendar; the
// connection goes with the test.
func (se *gcalSyncEnv) member(t *testing.T) string {
	t.Helper()
	hum := seat(t, se.env, se.tid, rbac.Developer)
	gcalConnectMember(t, se.gcalTestEnv, se.tid, hum)
	t.Cleanup(func() {
		se.st.(store.Gcal).DeleteGcalConnection(context.Background(), se.tid, hum) //nolint:errcheck // gone is fine
	})
	return hum
}

// cycle runs one GcalSyncOnce and fails the test on an error.
func (se *gcalSyncEnv) cycle(t *testing.T) bool {
	t.Helper()
	claimed, err := se.srv.GcalSyncOnce(context.Background())
	if err != nil {
		t.Fatalf("sync cycle: %v", err)
	}
	return claimed
}

// event creates a private event of hum, a day after the clock.
func (se *gcalSyncEnv) event(t *testing.T, hum, title string, mut func(*store.CalendarEvent)) store.CalendarEvent {
	t.Helper()
	now := se.clock.now()
	e := store.CalendarEvent{Title: title, Kind: "other", Audience: store.CalendarPrivate, CreatorType: "human", CreatorID: hum,
		StartsAt: now.Add(24 * time.Hour), EndsAt: now.Add(25 * time.Hour)}
	if mut != nil {
		mut(&e)
	}
	ev, err := se.st.(store.Calendar).CreateCalendarEvent(context.Background(), se.tid, e, now)
	if err != nil {
		t.Fatal(err)
	}
	return ev
}

func (se *gcalSyncEnv) conn(t *testing.T, hum string) store.GcalConnection {
	t.Helper()
	c, err := gcalRow(t, se.gcalTestEnv, se.tid, hum)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func (se *gcalSyncEnv) maps(t *testing.T, hum string) []store.GcalEventMap {
	t.Helper()
	m, err := se.st.(store.Gcal).GcalEventMaps(context.Background(), se.tid, hum)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// calls sums the fake's counts of names (all of gcalWriteCalls when none).
func (se *gcalSyncEnv) calls(names ...string) int {
	if len(names) == 0 {
		names = gcalWriteCalls
	}
	n := 0
	for _, name := range names {
		n += se.fake.Calls(name)
	}
	return n
}

// next moves the clock past the connection's next due time.
func (se *gcalSyncEnv) next() { se.clock.add(61 * time.Second) }

// C13: a Spool event the member created goes to a target calendar the
// cycle creates ("Spool Hub (<workspace>)"), with a map row holding its
// Google id and sync hash.
func TestGcalSyncInsertsEvent(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	ev := se.event(t, hum, "Planning", func(e *store.CalendarEvent) { e.Description = "the plan" })
	se.fake.ResetCalls()
	if !se.cycle(t) {
		t.Fatal("the due connection was not claimed")
	}
	c := se.conn(t, hum)
	cals := se.fake.Calendars(fakegcal.DefaultEmail)
	if c.CalendarID == "" || len(cals) != 1 || cals[0].ID != c.CalendarID || cals[0].Summary != "Spool Hub ("+se.tid+")" {
		t.Fatalf("target calendar: row %q, google %+v", c.CalendarID, cals)
	}
	got := se.fake.Events(c.CalendarID)
	if len(got) != 1 || got[0].Summary != "Planning" || got[0].Description != "the plan" || got[0].Visibility != "private" ||
		!got[0].Start.DateTime.Equal(ev.StartsAt) {
		t.Fatalf("google events %+v, want Planning", got)
	}
	m := se.maps(t, hum)
	if len(m) != 1 || m[0].EventID != ev.ID || m[0].GoogleID != got[0].ID || m[0].SyncHash != hub.GcalSyncHash(ev) {
		t.Fatalf("map rows %+v, want %s -> %s", m, ev.ID, got[0].ID)
	}
	if c.SyncLeaseUntil != nil || c.LastSyncedAt == nil || c.OutCursor == nil || c.Status != store.GcalConnected {
		t.Fatalf("finished row: lease %v, last sync %v, cursor %v, status %s", c.SyncLeaseUntil, c.LastSyncedAt, c.OutCursor, c.Status)
	}
	if n := se.fake.Calls("events.insert"); n != 1 {
		t.Fatalf("events.insert %d times, want 1", n)
	}
}

// C14: an edit in Spool is one PATCH; a second cycle with no change makes
// no call at all.
func TestGcalSyncPatchesOnceThenIdle(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	ev := se.event(t, hum, "Planning", nil)
	se.cycle(t)
	se.next()
	title := "Planning, moved"
	if _, err := se.st.(store.Calendar).UpdateCalendarEvent(context.Background(), se.tid, hum, ev.ID,
		store.CalendarPatch{Title: &title}, se.clock.now()); err != nil {
		t.Fatal(err)
	}
	se.fake.ResetCalls()
	se.cycle(t)
	if p, i := se.fake.Calls("events.patch"), se.fake.Calls("events.insert"); p != 1 || i != 0 {
		t.Fatalf("after an edit: %d patch, %d insert; want 1, 0", p, i)
	}
	cal := se.conn(t, hum).CalendarID
	if got := se.fake.Events(cal); len(got) != 1 || got[0].Summary != title {
		t.Fatalf("google events %+v, want one %q", got, title)
	}
	se.next()
	se.fake.ResetCalls()
	if !se.cycle(t) {
		t.Fatal("the connection was not due again")
	}
	if n := se.calls(); n != 0 {
		t.Fatalf("a cycle with no change made %d google calls, want 0", n)
	}
}

// C13b: the event moved to trash in Spool is one DELETE at Google and its
// map row goes. Twin: the trash leaves updated_at as it was, so a cursor on
// updated_at alone would never see it; the cycle finds it through the map.
func TestGcalSyncDeletesTrashedEvent(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	ev := se.event(t, hum, "Planning", nil)
	se.cycle(t)
	gid := se.maps(t, hum)[0].GoogleID
	se.next()
	trashed, err := se.st.(store.Calendar).TrashCalendarEvent(context.Background(), se.tid, hum, ev.ID, time.Time{}, se.clock.now())
	if err != nil {
		t.Fatal(err)
	}
	if c := se.conn(t, hum); !trashed.UpdatedAt.Equal(ev.UpdatedAt) || c.OutCursor == nil || trashed.UpdatedAt.After(*c.OutCursor) {
		t.Fatalf("the trash moved updated_at (%v -> %v, cursor %v): this twin no longer shows an updated_at cursor missing it",
			ev.UpdatedAt, trashed.UpdatedAt, c.OutCursor)
	}
	se.fake.ResetCalls()
	se.cycle(t)
	if n := se.fake.Calls("events.delete"); n != 1 {
		t.Fatalf("events.delete %d times, want 1", n)
	}
	if g, ok := se.fake.Event(se.conn(t, hum).CalendarID, gid); !ok || g.Status != "cancelled" {
		t.Fatalf("google event %s: %+v (found %v), want cancelled", gid, g, ok)
	}
	if m := se.maps(t, hum); len(m) != 0 {
		t.Fatalf("map rows after the delete: %+v", m)
	}
	se.next()
	se.fake.ResetCalls()
	se.cycle(t)
	if n := se.calls(); n != 0 {
		t.Fatalf("the cycle after the delete made %d google calls, want 0", n)
	}
}

// C13c: a series with one changed occurrence goes to Google once, as the
// series with its RRULE; the exception row is not sent.
func TestGcalSyncSkipsOccurrenceException(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	series := se.event(t, hum, "Standup", func(e *store.CalendarEvent) { e.RRule = "FREQ=DAILY;COUNT=5" })
	occ := series.ID + "_" + series.StartsAt.Add(24*time.Hour).UTC().Format("20060102T150405Z")
	moved := "Standup, later"
	if _, err := se.st.(store.Calendar).UpdateCalendarEvent(context.Background(), se.tid, hum, occ,
		store.CalendarPatch{Title: &moved, Scope: store.CalendarScopeThis}, se.clock.now()); err != nil {
		t.Fatal(err)
	}
	rows, err := se.st.(store.CalendarSearch).SearchCalendarEvents(context.Background(), se.tid, hum,
		store.CalendarQuery{Guest: hum, Range: store.CalendarRange{Start: gcalSyncT0, End: gcalSyncT0.AddDate(1, 0, 0)}})
	if err != nil {
		t.Fatal(err)
	}
	exceptions := 0
	for _, r := range rows {
		if r.RecurringEventID == series.ID {
			exceptions++
		}
	}
	if exceptions != 1 {
		t.Fatalf("the store holds %d exception rows of the series, want 1 (else this case proves nothing)", exceptions)
	}
	se.fake.ResetCalls()
	se.cycle(t)
	if n := se.fake.Calls("events.insert"); n != 1 {
		t.Fatalf("events.insert %d times, want 1 (the series only)", n)
	}
	got := se.fake.Events(se.conn(t, hum).CalendarID)
	if len(got) != 1 || got[0].Summary != "Standup" || len(got[0].Recurrence) != 1 || got[0].Recurrence[0] != "RRULE:FREQ=DAILY;COUNT=5" {
		t.Fatalf("google events %+v, want the series with its RRULE", got)
	}
	if m := se.maps(t, hum); len(m) != 1 || m[0].EventID != series.ID {
		t.Fatalf("map rows %+v, want the series only", m)
	}
}

// C20: the access token is due for a refresh and Google answers
// invalid_grant: the connection is revoked and no further call is made, in
// this cycle or later.
func TestGcalSyncInvalidGrantRevokes(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	se.event(t, hum, "Planning", nil)
	se.fake.RevokeGrant(fakegcal.DefaultEmail)
	se.clock.add(56 * time.Minute) // the fake's access token lives 1 h: inside gcalRefreshAhead
	se.fake.ResetCalls()
	if !se.cycle(t) {
		t.Fatal("the due connection was not claimed")
	}
	c := se.conn(t, hum)
	if c.Status != store.GcalRevoked || !strings.Contains(c.StatusDetail, "invalid_grant") || c.SyncLeaseUntil != nil {
		t.Fatalf("row: status %q detail %q lease %v, want revoked, lease cleared", c.Status, c.StatusDetail, c.SyncLeaseUntil)
	}
	if tk, n := se.fake.Calls("token"), se.calls(); tk != 1 || n != 1 {
		t.Fatalf("google calls: %d token, %d in all; want the one refresh", tk, n)
	}
	for range 3 {
		se.next()
		if se.cycle(t) {
			t.Fatal("a revoked connection was claimed again")
		}
	}
	if n := se.calls(); n != 1 {
		t.Fatalf("google calls after the revoke: %d in all, want still 1", n)
	}
}

// A 401 on a stored access token that has not expired yet (Google revoked
// it early) is refreshed once and the call made again.
func TestGcalSyncRefreshesOnUnauthorized(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	se.event(t, hum, "Planning", nil)
	se.fake.ExpireAccessTokens()
	se.fake.ResetCalls()
	se.cycle(t)
	if tk, cal := se.fake.Calls("token"), se.fake.Calls("calendars.insert"); tk != 1 || cal != 2 {
		t.Fatalf("token %d, calendars.insert %d; want one refresh and the call made again", tk, cal)
	}
	if got := se.fake.Events(se.conn(t, hum).CalendarID); len(got) != 1 {
		t.Fatalf("google events %+v after the refresh, want 1", got)
	}
}

// 2.9: with gcal.workspaces empty nothing is claimed; a connection of a
// workspace off a non-empty list is put back with no Google call.
func TestGcalSyncKillSwitch(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	se.event(t, hum, "Planning", nil)
	before := se.conn(t, hum)
	se.fake.ResetCalls()
	se.gc.Workspaces = nil
	if se.cycle(t) {
		t.Fatal("an empty workspace list claimed a connection")
	}
	if c := se.conn(t, hum); c.LastSyncedAt != nil || !c.DueAt.Equal(before.DueAt) || c.SyncLeaseUntil != nil {
		t.Fatalf("an empty list touched the row: %+v", c)
	}
	se.gc.Workspaces = []string{"another-workspace"}
	if !se.cycle(t) {
		t.Fatal("the connection was not claimed")
	}
	c := se.conn(t, hum)
	if c.CalendarID != "" || c.SyncLeaseUntil != nil || !c.DueAt.After(se.clock.now()) || len(se.maps(t, hum)) != 0 {
		t.Fatalf("an unlisted workspace's connection: %+v", c)
	}
	if n := se.calls(); n != 0 {
		t.Fatalf("an unlisted workspace made %d google calls, want 0", n)
	}
}

// C21: two cycles at once each sync a connection once (one claim each, no
// event written twice). Twin: past the 5 min lease a second cycle claims
// the connection while the first is in a Google call; the first cycle's
// next write matches no row (store.ErrGcalLeaseLost) and it stops, making
// no call after it. On Postgres every Google call is made with no pool
// connection held: no transaction is open during it.
func TestGcalSyncLease(t *testing.T) {
	se := gcalSyncEnvOf(t)
	pg, _ := se.st.(*store.Postgres)
	var held atomic.Int32
	noTx := func(*http.Request) {
		if pg != nil && pg.Pool().Stat().AcquiredConns() != 0 {
			held.Add(1)
		}
	}
	m1, m2 := se.member(t), se.member(t)
	for _, h := range []string{m1, m2} {
		se.event(t, h, "a", nil)
		se.event(t, h, "b", nil)
	}
	se.fake.ResetCalls()
	var claims atomic.Int32
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				claimed, err := se.srv.GcalSyncOnce(context.Background())
				if err != nil {
					errs <- err
					return
				}
				if !claimed {
					return
				}
				claims.Add(1)
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("concurrent cycle: %v", err)
	}
	if n := claims.Load(); n != 2 {
		t.Fatalf("%d claims for 2 due connections, want 2", n)
	}
	if i, c := se.fake.Calls("events.insert"), se.fake.Calls("calendars.insert"); i != 4 || c != 2 {
		t.Fatalf("events.insert %d, calendars.insert %d; want 4 and 2 (each connection once)", i, c)
	}

	// the twin: one fresh connection, its lease taken over mid-cycle
	m3 := se.member(t)
	se.event(t, m3, "c", nil)
	se.event(t, m3, "d", nil)
	se.fake.ResetCalls()
	var took atomic.Bool
	var bClaimed bool
	var bErr error
	var afterB int
	se.hook.set(func(r *http.Request) {
		noTx(r)
		if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/events") && took.CompareAndSwap(false, true) {
			se.clock.add(6 * time.Minute)
			bClaimed, bErr = se.srv.GcalSyncOnce(context.Background())
			afterB = se.calls()
		}
	})
	aClaimed, aErr := se.srv.GcalSyncOnce(context.Background())
	if !aClaimed || !errors.Is(aErr, store.ErrGcalLeaseLost) {
		t.Fatalf("first cycle: claimed %v, err %v; want the lease lost", aClaimed, aErr)
	}
	if !took.Load() || !bClaimed || bErr != nil {
		t.Fatalf("second cycle past the lease: ran %v, claimed %v, err %v", took.Load(), bClaimed, bErr)
	}
	// after the second cycle: only the first cycle's insert that was in flight
	if n := se.calls(); n != afterB+1 {
		t.Fatalf("google calls: %d after the takeover, %d in all; the first cycle went on after its lease was lost", afterB, n)
	}
	if m := se.maps(t, m3); len(m) != 2 {
		t.Fatalf("map rows %+v, want the second cycle's 2", m)
	}
	if c := se.conn(t, m3); c.SyncLeaseUntil != nil || c.LastSyncedAt == nil {
		t.Fatalf("after the takeover: lease %v, last sync %v; want the second cycle's finish", c.SyncLeaseUntil, c.LastSyncedAt)
	}
	if n := held.Load(); n != 0 {
		t.Fatalf("%d google calls ran while a pool connection was held (a transaction open)", n)
	}
	if pg == nil {
		t.Log("memory store: the open-transaction check runs on Postgres (SPOOL_TEST_PG_DSN)")
	}
}

// Owner poll d93654e1 A (SPL-3852): the member's Google gets the
// workspace's events, not only their own: another member's workspace event
// is sent, their private event is not (the private filter), and neither is
// another member's Google import (private, source_key gcal:).
func TestGcalSyncSendsWorkspaceEvents(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := se.member(t)
	other := seat(t, se.env, se.tid, rbac.Developer)
	shared := se.event(t, other, "All hands", func(e *store.CalendarEvent) { e.Audience = store.CalendarWorkspace })
	se.event(t, other, "Dentist", nil)
	if !se.cycle(t) {
		t.Fatal("the due connection was not claimed")
	}
	c := se.conn(t, hum)
	got := se.fake.Events(c.CalendarID)
	if len(got) != 1 || got[0].Summary != "All hands" || got[0].Visibility == "private" {
		t.Fatalf("google events %+v, want the workspace event All hands only", got)
	}
	m := se.maps(t, hum)
	if len(m) != 1 || m[0].EventID != shared.ID {
		t.Fatalf("map rows %+v, want %s", m, shared.ID)
	}
	// the other member turns it private: it leaves this member's Google
	priv := store.CalendarPrivate
	se.next()
	if _, err := se.st.(store.Calendar).UpdateCalendarEvent(context.Background(), se.tid, other, shared.ID,
		store.CalendarPatch{Audience: &priv}, se.clock.now()); err != nil {
		t.Fatal(err)
	}
	se.next()
	se.cycle(t)
	if got := se.fake.Events(c.CalendarID); len(got) != 0 {
		t.Fatalf("google events %+v after the event turned private, want none", got)
	}
}
