package hub_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 149 section 14 (SPL-6250): a member removed from the workspace gets
// no more of its events in their Google calendar, and nothing from that
// calendar reaches Spool; the connection is paused, not dropped, so a
// member admitted again syncs on. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// admitAs invites the identity of email to tid as a developer and admits
// it: the first call seats a new human, a later one the same human again.
func admitAs(t *testing.T, se *gcalSyncEnv, email string) string {
	t.Helper()
	h := se.st.(store.Humans)
	now := time.Now()
	if err := h.PutInvite(context.Background(), store.Invite{TenantID: se.tid, Email: email, Role: rbac.Developer,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	hum, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email},
		se.tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return hum
}

// removedEnv is a connected member synced once with a workspace event of
// another member on Google, then removed from the workspace; after it the
// other member adds a workspace event and a Google event appears in the
// removed member's target calendar.
func removedEnv(t *testing.T) (se *gcalSyncEnv, email, hum, cal string) {
	t.Helper()
	se = gcalSyncEnvOf(t)
	b := make([]byte, 5)
	rand.Read(b) //nolint:errcheck
	email = hex.EncodeToString(b) + "@example.com"
	hum = admitAs(t, se, email)
	gcalConnectMember(t, se.gcalTestEnv, se.tid, hum)
	t.Cleanup(func() {
		se.st.(store.Gcal).DeleteGcalConnection(context.Background(), se.tid, hum) //nolint:errcheck // gone is fine
	})
	other := seat(t, se.env, se.tid, rbac.Developer)
	workspace := func(e *store.CalendarEvent) { e.Audience = store.CalendarWorkspace }
	se.event(t, other, "Before", workspace)
	se.cycle(t)
	cal = se.conn(t, hum).CalendarID
	if got := se.fake.Events(cal); len(got) != 1 || got[0].Summary != "Before" {
		t.Fatalf("before the removal google holds %+v, want Before", got)
	}
	if err := se.st.(store.Humans).RemoveMember(context.Background(), se.tid, hum); err != nil {
		t.Fatal(err)
	}
	se.next()
	se.event(t, other, "After", workspace)
	se.add(t, cal, se.gev("From google"))
	return se, email, hum, cal
}

// googleTitles are the summaries of cal's events at Google, by summary.
func (se *gcalSyncEnv) googleTitles(cal string) map[string]bool {
	out := map[string]bool{}
	for _, e := range se.fake.Events(cal) {
		out[e.Summary] = true
	}
	return out
}

// The removed member's cycle makes no Google call: the workspace event
// added after the removal never reaches their calendar, the Google event
// never comes into Spool, and what the calendar held is left as it was.
// The connection is kept, paused with its reason, due again in an hour.
func TestGcalSyncRemovedMemberPaused(t *testing.T) {
	se, _, hum, cal := removedEnv(t)
	se.fake.ResetCalls()
	if !se.cycle(t) {
		t.Fatal("the removed member's connection was not claimed")
	}
	if n := se.calls("token", "calendars.insert", "events.insert", "events.patch", "events.delete", "events.list"); n != 0 {
		t.Fatalf("the removed member's cycle made %d google calls, want 0", n)
	}
	if g := se.googleTitles(cal); g["After"] || !g["Before"] || len(g) != 2 {
		t.Fatalf("google holds %v, want Before and From google only", g)
	}
	if got := se.imported(t, hum); len(got) != 0 {
		t.Fatalf("the removed member's google event came into the workspace: %+v", got)
	}
	c := se.conn(t, hum)
	if c.Status != store.GcalConnected || c.StatusDetail != "not a member of this workspace: sync paused" || c.SyncLeaseUntil != nil {
		t.Fatalf("paused row: status %s, detail %q, lease %v", c.Status, c.StatusDetail, c.SyncLeaseUntil)
	}
	se.next()
	if se.cycle(t) {
		t.Fatal("a paused connection was due again within the hour")
	}
}

// A member admitted again syncs on from where the cycle paused: the
// workspace event goes to Google and the Google event comes in.
func TestGcalSyncReadmittedMemberResumes(t *testing.T) {
	se, email, hum, cal := removedEnv(t)
	se.cycle(t)
	if again := admitAs(t, se, email); again != hum {
		t.Fatalf("admitted again as %s, want %s", again, hum)
	}
	se.clock.add(gcalOffRecheckTest)
	if !se.cycle(t) {
		t.Fatal("the paused connection was not due after the recheck")
	}
	if g := se.googleTitles(cal); !g["After"] {
		t.Fatalf("google holds %v after the member came back, want After", g)
	}
	if got := se.imported(t, hum); len(got) != 1 || got[0].Title != "From google" {
		t.Fatalf("imported %+v after the member came back, want From google", got)
	}
}

// gcalOffRecheckTest is past the hub's gcalOffRecheck (an hour).
const gcalOffRecheckTest = time.Hour + time.Minute

// Spec 149 section 14, owner msg 08cec636 (poll 2c0013de A, SPL-6272): a
// connection paused longer than cnf gcal.paused_drop_after (the hub's
// fallback, 30 days, in these tests) is revoked at Google and deleted.

// gcalDropAfterTest is the hub's fallback of gcal.paused_drop_after.
const gcalDropAfterTest = 30 * 24 * time.Hour

// pausedOnce runs the removed member's first paused cycle and answers when
// the pause started.
func pausedOnce(t *testing.T, se *gcalSyncEnv, hum string) time.Time {
	t.Helper()
	se.cycle(t)
	c := se.conn(t, hum)
	if c.PausedAt == nil {
		t.Fatal("the first paused cycle recorded no pause start")
	}
	return *c.PausedAt
}

// Before the limit nothing is revoked and the pause start stays as it was
// through the hourly rechecks; a member admitted again then syncs on with no
// reconnect, and the pause start is cleared.
func TestGcalSyncPausedKeptBeforeLimit(t *testing.T) {
	se, email, hum, cal := removedEnv(t)
	start := pausedOnce(t, se, hum)
	se.fake.ResetCalls()
	for _, step := range []time.Duration{gcalOffRecheckTest, gcalDropAfterTest - 2*gcalOffRecheckTest} {
		se.clock.add(step)
		se.cycle(t)
		c := se.conn(t, hum)
		if c.PausedAt == nil || !c.PausedAt.Equal(start) {
			t.Fatalf("pause start %v after a recheck, want %v kept", c.PausedAt, start)
		}
	}
	if n := se.fake.Calls("revoke"); n != 0 {
		t.Fatalf("%d revoke calls before the limit, want 0", n)
	}
	if again := admitAs(t, se, email); again != hum {
		t.Fatalf("admitted again as %s, want %s", again, hum)
	}
	se.clock.add(gcalOffRecheckTest)
	if !se.cycle(t) {
		t.Fatal("the paused connection was not due after the recheck")
	}
	if c := se.conn(t, hum); c.PausedAt != nil || c.StatusDetail == "not a member of this workspace: sync paused" {
		t.Fatalf("after the member came back: pause start %v, detail %q, want cleared", c.PausedAt, c.StatusDetail)
	}
	if g := se.googleTitles(cal); !g["After"] {
		t.Fatalf("google holds %v after the member came back, want After", g)
	}
}

// Past the limit the cycle revokes the grant at Google once, then deletes
// the connection with its map rows.
func TestGcalSyncPausedDroppedAfterLimit(t *testing.T) {
	se, _, hum, _ := removedEnv(t)
	ctx := context.Background()
	tok, err := se.st.(store.Gcal).GcalTokens(ctx, se.tid, hum)
	if err != nil {
		t.Fatal(err)
	}
	refresh, err := se.gc.Sealer.Open(ctx, tok.RefreshSealed)
	if err != nil {
		t.Fatal(err)
	}
	pausedOnce(t, se, hum)
	se.clock.add(gcalDropAfterTest + time.Minute)
	se.fake.ResetCalls()
	if !se.cycle(t) {
		t.Fatal("the connection paused past the limit was not claimed")
	}
	if n := se.fake.Calls("revoke"); n != 1 || !se.fake.Revoked(refresh.Reveal()) {
		t.Fatalf("revoke calls %d, revoked %v, want the one grant revoked once", n, se.fake.Revoked(refresh.Reveal()))
	}
	if n := se.calls(); n != 0 {
		t.Fatalf("the drop made %d sync calls at google, want 0", n)
	}
	if _, err := gcalRow(t, se.gcalTestEnv, se.tid, hum); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("the connection is still there: %v", err)
	}
	if maps, _ := se.st.(store.Gcal).GcalEventMaps(ctx, se.tid, hum); len(maps) != 0 {
		t.Fatalf("%d map rows left", len(maps))
	}
}

// A revoke Google refuses keeps the row, paused: a connection is never
// deleted while its grant may still be live at Google.
func TestGcalSyncPausedDropKeepsRowOnRevokeFailure(t *testing.T) {
	se, _, hum, _ := removedEnv(t)
	pausedOnce(t, se, hum)
	se.clock.add(gcalDropAfterTest + time.Minute)
	se.hook.set(func(r *http.Request) {
		if r.Method == http.MethodPost && strings.Contains(r.URL.Path, "revoke") {
			r.URL.Path += "-unreachable" // the fake answers 404
		}
	})
	t.Cleanup(func() { se.hook.set(nil) })
	se.cycle(t)
	c, err := gcalRow(t, se.gcalTestEnv, se.tid, hum)
	if err != nil {
		t.Fatalf("the row went although the revoke failed: %v", err)
	}
	if c.PausedAt == nil || c.SyncLeaseUntil != nil {
		t.Fatalf("after a failed revoke: pause start %v, lease %v, want kept and released", c.PausedAt, c.SyncLeaseUntil)
	}
}
