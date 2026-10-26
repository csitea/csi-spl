package hub_test

import (
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// "Sync now" (spec 149 2.5 and section 4, SPL-3579): POST
// /v1/me/google-calendar/sync claims the member's own connection with the
// ticker's lease and runs one cycle of the ticker's code at once. Against
// fakegcal and a fake KMS; no test reaches Google. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

const gcalSyncPath = "/v1/me/google-calendar/sync"

// gcalSyncDone waits until the member's cycle has cleared its lease.
func gcalSyncDone(t *testing.T, se *gcalSyncEnv, hum string) store.GcalConnection {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		c := se.conn(t, hum)
		if c.SyncLeaseUntil == nil {
			return c
		}
		if time.Now().After(deadline) {
			t.Fatalf("the sync cycle still holds the lease: %+v", c)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// gcalSyncCode posts "Sync now" and answers the status and the error code.
func gcalSyncCode(t *testing.T, se *gcalSyncEnv, hum string) (int, string) {
	t.Helper()
	resp := gcalDo(t, se.gcalTestEnv, se.tid, http.MethodPost, gcalSyncPath, hum)
	code, _ := gcalBody(t, resp)["error"].(string)
	return resp.StatusCode, code
}

// The route: no connection is 404 not_found; a connected member gets 202
// and the cycle runs now (the event reaches Google, though the connection is
// not due); a second click while that cycle holds the lease is 409
// sync_in_progress; once it finished, 202 again (the CONTROL that the 409
// was the lease). A revoked connection is 409 gcal_revoked, a workspace off
// the list 404.
func TestGcalSyncNow(t *testing.T) {
	se := gcalSyncEnvOf(t)
	hum := seat(t, se.env, se.tid, rbac.Developer)
	if st, code := gcalSyncCode(t, se, hum); st != http.StatusNotFound || code != "not_found" {
		t.Fatalf("sync with no connection: %d %q, want 404 not_found", st, code)
	}
	hum = se.member(t)
	ev := se.event(t, hum, "Planning", nil)
	// the ticker's last cycle made it due 60 s later: inside that, only "Sync now" runs it
	if !se.cycle(t) {
		t.Fatal("the due connection was not claimed")
	}
	se.fake.ResetCalls()
	se.clock.add(30 * time.Second)
	if claimed := se.cycle(t); claimed {
		t.Fatal("the ticker claimed a connection that is not due")
	}

	// hold the cycle at its first Google call
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	se.hook.set(func(*http.Request) {
		once.Do(func() {
			close(entered)
			<-release
		})
	})
	title := "Planning, moved"
	if _, err := se.st.(store.Calendar).UpdateCalendarEvent(context.Background(), se.tid, hum, ev.ID,
		store.CalendarPatch{Title: &title}, se.clock.now()); err != nil {
		t.Fatal(err)
	}
	if st, code := gcalSyncCode(t, se, hum); st != http.StatusAccepted {
		close(release)
		t.Fatalf("sync now: %d %q, want 202", st, code)
	}
	select {
	case <-entered:
	case <-time.After(10 * time.Second):
		close(release)
		t.Fatal("the sync cycle made no Google call")
	}
	st, code := gcalSyncCode(t, se, hum)
	close(release)
	if st != http.StatusConflict || code != "sync_in_progress" {
		t.Fatalf("sync while the lease is held: %d %q, want 409 sync_in_progress", st, code)
	}
	c := gcalSyncDone(t, se, hum)
	if n := se.fake.Calls("events.patch"); n != 1 || c.LastSyncedAt == nil || !c.LastSyncedAt.Equal(se.clock.now()) {
		t.Fatalf("after sync now: events.patch %d (want 1), last synced %v (want %v)", n, c.LastSyncedAt, se.clock.now())
	}
	se.hook.set(nil)
	if st, code := gcalSyncCode(t, se, hum); st != http.StatusAccepted {
		t.Fatalf("sync after the cycle finished: %d %q, want 202", st, code)
	}
	gcalSyncDone(t, se, hum)

	// revoked: reconnect, not sync
	_, l, err := se.st.(store.Gcal).ClaimGcalMember(context.Background(), se.tid, hum, se.clock.now(), 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	gs := se.st.(store.Gcal)
	if err := gs.SetGcalStatus(context.Background(), l, store.GcalRevoked, "invalid_grant", se.clock.now()); err != nil {
		t.Fatal(err)
	}
	if err := gs.FinishGcalSync(context.Background(), l, store.GcalSyncDone{NextDue: se.clock.now()}, se.clock.now()); err != nil {
		t.Fatal(err)
	}
	if st, code := gcalSyncCode(t, se, hum); st != http.StatusConflict || code != "gcal_revoked" {
		t.Fatalf("sync of a revoked connection: %d %q, want 409 gcal_revoked", st, code)
	}
	se.gc.Workspaces = []string{"another-workspace"}
	if st, code := gcalSyncCode(t, se, hum); st != http.StatusNotFound || code != "not_found" {
		t.Fatalf("sync in a workspace off the list: %d %q, want 404 not_found", st, code)
	}
}
