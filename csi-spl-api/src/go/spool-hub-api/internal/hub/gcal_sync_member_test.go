package hub_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
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
