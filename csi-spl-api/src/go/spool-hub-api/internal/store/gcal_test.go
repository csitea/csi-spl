package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// Spec 149 B2 / SPL-3170 (rdb 0217): the Google Calendar store, on Memory and
// on Postgres (drivers: Postgres when $SPOOL_TEST_PG_DSN is set). C3 is the
// member isolation inside one workspace; the rest pin the lease fencing the
// sync cycle (B6a) and the push lookup (B7) build on. No test reaches Google:
// the sealed columns hold fake text.

var (
	_ Gcal = (*Memory)(nil)
	_ Gcal = (*Postgres)(nil)
)

// gcalFix is one workspace with two members, M1 and M2, on one driver.
type gcalFix struct {
	st       Store
	g        Gcal
	tenant   string
	m1, m2   string
	now      time.Time
	eventIDs []string
}

func newGcalFix(t *testing.T, st Store) *gcalFix {
	t.Helper()
	ctx := context.Background()
	f := &gcalFix{st: st, g: st.(Gcal), tenant: newTenant(t, st), now: time.Now().UTC().Truncate(time.Microsecond)}
	hs := st.(Humans)
	for _, p := range []*string{&f.m1, &f.m2} {
		sub := uid("gcal-")
		h, err := hs.Admit(ctx, Identity{Provider: "google", Subject: sub, Email: sub + "@example.com", Name: "FirstName LastName"}, "", AdmitPolicy{}, f.now)
		if err != nil {
			t.Fatal(err)
		}
		*p = h
	}
	t.Cleanup(func() {
		for _, h := range []string{f.m1, f.m2} {
			f.g.DeleteGcalConnection(context.Background(), f.tenant, h) //nolint:errcheck // gone already is fine
		}
	})
	return f
}

func (f *gcalFix) connect(t *testing.T, human, email string) GcalConnection {
	t.Helper()
	c, err := f.g.ConnectGcal(context.Background(), GcalConnection{Tenant: f.tenant, Human: human, GoogleEmail: email},
		GcalTokens{AccessSealed: "v1.sealed-a." + human, RefreshSealed: "v1.sealed-r." + human, KMSKeyID: "fake-kms/1",
			AccessExpiry: f.now.Add(time.Hour)}, f.now)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// event makes one calendar event of human, for a map row's foreign key.
func (f *gcalFix) event(t *testing.T, human string) string {
	t.Helper()
	ev, err := f.st.(Calendar).CreateCalendarEvent(context.Background(), f.tenant, CalendarEvent{Title: "gcal", Kind: "other",
		StartsAt: f.now, EndsAt: f.now.Add(time.Hour), CreatorType: "human", CreatorID: human, Audience: "private"}, f.now)
	if err != nil {
		t.Fatal(err)
	}
	return ev.ID
}

// claim claims until it gets connection id (a shared Postgres may hold other
// due rows), at now.
func (f *gcalFix) claim(t *testing.T, id string, now time.Time) (GcalLease, error) {
	t.Helper()
	for range 200 {
		c, l, err := f.g.ClaimGcalConnection(context.Background(), now, 5*time.Minute)
		if err != nil {
			return GcalLease{}, err
		}
		if c.ID == id {
			if c.SyncLeaseUntil == nil || !c.SyncLeaseUntil.Equal(l.Until) || l.Tenant != f.tenant {
				t.Fatalf("claim returned %+v with lease %+v", c, l)
			}
			return l, nil
		}
	}
	t.Fatalf("connection %s never claimed", id)
	return GcalLease{}, nil
}

var gcalHash = strings.Repeat("a", 64)

// TestGcalMemberIsolation: spec 149 C3. M1 and M2 are members of the same
// workspace; M2 connected. M1 reads, tokens, maps, marks due and deletes
// nothing of M2's. CONTROL (the twin): M2 reads its own connection, tokens
// and map row, so the not-found is not an empty store.
func TestGcalMemberIsolation(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			f := newGcalFix(t, st)
			c2 := f.connect(t, f.m2, "m2@example.com")
			l, err := f.claim(t, c2.ID, f.now)
			if err != nil {
				t.Fatal(err)
			}
			ev := f.event(t, f.m2)
			if err := f.g.PutGcalEventMap(ctx, l, GcalEventMap{EventID: ev, GoogleID: "g-1", SyncHash: gcalHash}, f.now); err != nil {
				t.Fatal(err)
			}

			if _, err := f.g.GcalConnection(ctx, f.tenant, f.m1); !errors.Is(err, ErrNotFound) {
				t.Errorf("C3: M1 reads a connection (%v), want ErrNotFound", err)
			}
			if _, err := f.g.GcalTokens(ctx, f.tenant, f.m1); !errors.Is(err, ErrNotFound) {
				t.Errorf("C3: M1 reads tokens (%v), want ErrNotFound", err)
			}
			if ms, err := f.g.GcalEventMaps(ctx, f.tenant, f.m1); err != nil || len(ms) != 0 {
				t.Errorf("C3: M1 reads %d map rows (%v), want 0", len(ms), err)
			}
			if err := f.g.MarkGcalDue(ctx, f.tenant, f.m1, f.now); !errors.Is(err, ErrNotFound) {
				t.Errorf("C3: M1 marks due (%v), want ErrNotFound", err)
			}
			if _, err := f.g.DeleteGcalConnection(ctx, f.tenant, f.m1); !errors.Is(err, ErrNotFound) {
				t.Errorf("C3: M1 deletes (%v), want ErrNotFound", err)
			}
			// the lease fences on the member too: M1 holding M2's lease writes nothing
			if err := f.g.SetGcalCalendar(ctx, GcalLease{Tenant: f.tenant, Human: f.m1, ConnectionID: l.ConnectionID, Until: l.Until}, "cal-x", f.now); !errors.Is(err, ErrGcalLeaseLost) {
				t.Errorf("C3: a lease naming M1 wrote M2's row (%v), want ErrGcalLeaseLost", err)
			}

			got, err := f.g.GcalConnection(ctx, f.tenant, f.m2)
			if err != nil || got.ID != c2.ID || got.GoogleEmail != "m2@example.com" || got.CalendarID != "" {
				t.Fatalf("C3 control: M2 reads %+v, %v", got, err)
			}
			if tok, err := f.g.GcalTokens(ctx, f.tenant, f.m2); err != nil || tok.AccessSealed != "v1.sealed-a."+f.m2 {
				t.Fatalf("C3 control: M2 tokens %+v, %v", tok, err)
			}
			if ms, err := f.g.GcalEventMaps(ctx, f.tenant, f.m2); err != nil || len(ms) != 1 || ms[0].EventID != ev {
				t.Fatalf("C3 control: M2 map rows %+v, %v", ms, err)
			}
			// M1's own connection is another row
			if c1 := f.connect(t, f.m1, "m1@example.com"); c1.ID == c2.ID {
				t.Fatalf("M1's connection reused M2's id %s", c1.ID)
			}
		})
	}
}

// TestGcalLeaseFencing: spec 149 2.5 / C21's store half. One claim per due
// connection; a second claim finds nothing while the lease runs; past it a
// new claim wins and the old lease's writes match no row.
func TestGcalLeaseFencing(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			f := newGcalFix(t, st)
			c := f.connect(t, f.m1, "m1@example.com")
			l1, err := f.claim(t, c.ID, f.now)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := f.claim(t, c.ID, f.now.Add(time.Minute)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second claim inside the lease = %v, want ErrNotFound", err)
			}
			if err := f.g.SetGcalCalendar(ctx, l1, "cal-1", f.now); err != nil {
				t.Fatalf("holder write: %v", err)
			}
			// the holder renews; the old token is spent
			l1b, err := f.g.RenewGcalLease(ctx, l1, f.now.Add(time.Minute), 5*time.Minute)
			if err != nil {
				t.Fatal(err)
			}
			if err := f.g.SetGcalCalendar(ctx, l1, "cal-stale", f.now); !errors.Is(err, ErrGcalLeaseLost) {
				t.Fatalf("write with the pre-renew token = %v, want ErrGcalLeaseLost", err)
			}
			// past the renewed lease another cycle claims; the first one is fenced off
			l2, err := f.claim(t, c.ID, f.now.Add(7*time.Minute))
			if err != nil {
				t.Fatal(err)
			}
			if err := f.g.SetGcalTokens(ctx, l1b, GcalTokens{AccessSealed: "x", RefreshSealed: "y", KMSKeyID: "k", AccessExpiry: f.now}, f.now); !errors.Is(err, ErrGcalLeaseLost) {
				t.Fatalf("old cycle's write after the takeover = %v, want ErrGcalLeaseLost", err)
			}
			if err := f.g.FinishGcalSync(ctx, l1b, GcalSyncDone{NextDue: f.now}, f.now); !errors.Is(err, ErrGcalLeaseLost) {
				t.Fatalf("old cycle's finish = %v, want ErrGcalLeaseLost", err)
			}
			cur := f.now.Add(-time.Hour)
			next := f.now.Add(time.Hour)
			if err := f.g.FinishGcalSync(ctx, l2, GcalSyncDone{SyncToken: "tok-1", OutCursor: &cur, NextDue: next}, f.now.Add(8*time.Minute)); err != nil {
				t.Fatal(err)
			}
			got, err := f.g.GcalConnection(ctx, f.tenant, f.m1)
			if err != nil || got.SyncLeaseUntil != nil || got.SyncToken != "tok-1" || got.OutCursor == nil || !got.OutCursor.Equal(cur) ||
				!got.DueAt.Equal(next) || got.LastSyncedAt == nil || got.CalendarID != "cal-1" {
				t.Fatalf("after finish: %+v, %v", got, err)
			}
			if err := f.g.SetGcalCalendar(ctx, l2, "cal-2", f.now); !errors.Is(err, ErrGcalLeaseLost) {
				t.Fatalf("write after finish = %v, want ErrGcalLeaseLost", err)
			}
			// not due before next; revoked is never claimed
			if _, err := f.claim(t, c.ID, f.now.Add(30*time.Minute)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("claim before due_at = %v, want ErrNotFound", err)
			}
			l3, err := f.claim(t, c.ID, next)
			if err != nil {
				t.Fatal(err)
			}
			if err := f.g.SetGcalStatus(ctx, l3, GcalRevoked, "invalid_grant", next); err != nil {
				t.Fatal(err)
			}
			if err := f.g.FinishGcalSync(ctx, l3, GcalSyncDone{NextDue: next}, next); err != nil {
				t.Fatal(err)
			}
			if _, err := f.claim(t, c.ID, next.Add(time.Hour)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("claim of a revoked connection = %v, want ErrNotFound", err)
			}
			// a re-connect revives it, and a disconnect fences off any holder
			f.connect(t, f.m1, "m1@example.com")
			l4, err := f.claim(t, c.ID, f.now.Add(time.Second))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := f.g.DeleteGcalConnection(ctx, f.tenant, f.m1); err != nil {
				t.Fatal(err)
			}
			if err := f.g.SetGcalCalendar(ctx, l4, "cal-3", f.now); !errors.Is(err, ErrGcalLeaseLost) {
				t.Fatalf("write after disconnect = %v, want ErrGcalLeaseLost", err)
			}
		})
	}
}

// TestGcalReconnectAndMap: a re-connect of the same Google account keeps the
// row, calendar and map; another account starts over. A Google id maps to
// one event only.
func TestGcalReconnectAndMap(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			f := newGcalFix(t, st)
			c := f.connect(t, f.m1, "m1@example.com")
			l, err := f.claim(t, c.ID, f.now)
			if err != nil {
				t.Fatal(err)
			}
			ev1, ev2 := f.event(t, f.m1), f.event(t, f.m1)
			if err := f.g.SetGcalCalendar(ctx, l, "cal-1", f.now); err != nil {
				t.Fatal(err)
			}
			if err := f.g.PutGcalEventMap(ctx, l, GcalEventMap{EventID: ev1, GoogleID: "g-1", ETag: "e1", SyncHash: gcalHash}, f.now); err != nil {
				t.Fatal(err)
			}
			if err := f.g.PutGcalEventMap(ctx, l, GcalEventMap{EventID: ev2, GoogleID: "g-1", SyncHash: gcalHash}, f.now); !errors.Is(err, ErrConflict) {
				t.Fatalf("second event on g-1 = %v, want ErrConflict", err)
			}
			if err := f.g.PutGcalEventMap(ctx, l, GcalEventMap{EventID: ev1, GoogleID: "g-1", ETag: "e2", SyncHash: strings.Repeat("b", 64)}, f.now); err != nil {
				t.Fatalf("upsert of ev1: %v", err)
			}
			if ms, _ := f.g.GcalEventMaps(ctx, f.tenant, f.m1); len(ms) != 1 || ms[0].ETag != "e2" {
				t.Fatalf("map after upsert = %+v", ms)
			}

			same := f.connect(t, f.m1, "m1@example.com")
			if same.ID != c.ID || same.CalendarID != "cal-1" || same.SyncLeaseUntil != nil {
				t.Fatalf("same-account re-connect = %+v", same)
			}
			if ms, _ := f.g.GcalEventMaps(ctx, f.tenant, f.m1); len(ms) != 1 {
				t.Fatalf("same-account re-connect dropped the map: %+v", ms)
			}
			if err := f.g.SetGcalCalendar(ctx, l, "cal-x", f.now); !errors.Is(err, ErrGcalLeaseLost) {
				t.Fatalf("pre-reconnect lease still writes: %v", err)
			}
			other := f.connect(t, f.m1, "other@example.com")
			if other.ID != c.ID || other.CalendarID != "" || other.GoogleEmail != "other@example.com" {
				t.Fatalf("other-account re-connect = %+v", other)
			}
			if ms, _ := f.g.GcalEventMaps(ctx, f.tenant, f.m1); len(ms) != 0 {
				t.Fatalf("other-account re-connect kept %d map rows", len(ms))
			}
			l2, err := f.claim(t, c.ID, f.now.Add(time.Second))
			if err != nil {
				t.Fatal(err)
			}
			if err := f.g.PutGcalEventMap(ctx, l2, GcalEventMap{EventID: ev1, GoogleID: "g-9", SyncHash: gcalHash}, f.now); err != nil {
				t.Fatal(err)
			}
			if err := f.g.DeleteGcalEventMap(ctx, l2, ev1); err != nil {
				t.Fatal(err)
			}
			if ms, _ := f.g.GcalEventMaps(ctx, f.tenant, f.m1); len(ms) != 0 {
				t.Fatalf("map after delete = %+v", ms)
			}
			if err := f.g.PutGcalEventMap(ctx, l2, GcalEventMap{EventID: ev1, GoogleID: "g-9", SyncHash: "short"}, f.now); !errors.Is(err, ErrInvalidGcal) {
				t.Fatalf("short hash = %v, want ErrInvalidGcal", err)
			}
		})
	}
}

// TestGcalWatchLookup: B7's push finds the connection by its channel id with
// no workspace; a cleared channel finds nothing.
func TestGcalWatchLookup(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			f := newGcalFix(t, st)
			c := f.connect(t, f.m1, "m1@example.com")
			l, err := f.claim(t, c.ID, f.now)
			if err != nil {
				t.Fatal(err)
			}
			ch, exp := uuid4(), f.now.Add(24*time.Hour)
			if err := f.g.SetGcalWatch(ctx, l, GcalWatch{ChannelID: ch, ResourceID: "res-1", Expiry: &exp}, f.now); err != nil {
				t.Fatal(err)
			}
			got, err := f.g.GcalConnectionByWatch(ctx, ch)
			if err != nil || got.ID != c.ID || got.Tenant != f.tenant || got.Human != f.m1 || got.WatchResourceID != "res-1" ||
				got.WatchExpiry == nil || !got.WatchExpiry.Equal(exp) {
				t.Fatalf("by watch = %+v, %v", got, err)
			}
			for _, bad := range []string{uuid4(), "not-a-uuid", ""} {
				if _, err := f.g.GcalConnectionByWatch(ctx, bad); !errors.Is(err, ErrNotFound) {
					t.Errorf("by watch %q = %v, want ErrNotFound", bad, err)
				}
			}
			if err := f.g.SetGcalWatch(ctx, l, GcalWatch{}, f.now); err != nil {
				t.Fatal(err)
			}
			if _, err := f.g.GcalConnectionByWatch(ctx, ch); !errors.Is(err, ErrNotFound) {
				t.Fatalf("cleared channel still found: %v", err)
			}
			if err := f.g.MarkGcalDue(ctx, f.tenant, f.m1, f.now.Add(-time.Hour)); err != nil {
				t.Fatal(err)
			}
			if got, _ := f.g.GcalConnection(ctx, f.tenant, f.m1); !got.DueAt.Equal(f.now.Add(-time.Hour)) {
				t.Fatalf("due_at = %v after MarkGcalDue", got.DueAt)
			}
		})
	}
}

// TestGcalClaimMember: "Sync now" (spec 149 2.5 and section 4, SPL-3579)
// claims the member's own connection whether due or not, never while a lease
// is live (the 409 sync_in_progress), never a revoked one, and never another
// member's. The claim is the ticker's lease: the ticker cannot take the row
// while it is held, and a fenced write with the claimed token goes through.
// CONTROL: the same member claims once the lease has ended.
func TestGcalClaimMember(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			f := newGcalFix(t, st)
			if _, _, err := f.g.ClaimGcalMember(ctx, f.tenant, f.m1, f.now, 5*time.Minute); !errors.Is(err, ErrNotFound) {
				t.Fatalf("claim with no connection = %v, want ErrNotFound", err)
			}
			c := f.connect(t, f.m1, "m1@example.com")
			// a finished cycle sets the next due 2 min ahead: not due now
			l0, err := f.claim(t, c.ID, f.now)
			if err != nil {
				t.Fatal(err)
			}
			if err := f.g.FinishGcalSync(ctx, l0, GcalSyncDone{NextDue: f.now.Add(2 * time.Minute)}, f.now); err != nil {
				t.Fatal(err)
			}
			if _, _, err := f.g.ClaimGcalMember(ctx, f.tenant, f.m2, f.now, 5*time.Minute); !errors.Is(err, ErrNotFound) {
				t.Fatalf("M2 claims M1's connection: %v, want ErrNotFound", err)
			}
			got, l1, err := f.g.ClaimGcalMember(ctx, f.tenant, f.m1, f.now, 5*time.Minute)
			if err != nil {
				t.Fatalf("claim of a connection not due: %v", err)
			}
			if got.ID != c.ID || l1.ConnectionID != c.ID || l1.Tenant != f.tenant || l1.Human != f.m1 ||
				got.SyncLeaseUntil == nil || !got.SyncLeaseUntil.Equal(l1.Until) {
				t.Fatalf("claim returned %+v with lease %+v", got, l1)
			}
			if _, _, err := f.g.ClaimGcalMember(ctx, f.tenant, f.m1, f.now.Add(time.Minute), 5*time.Minute); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second claim inside the lease = %v, want ErrNotFound", err)
			}
			if _, err := f.claim(t, c.ID, f.now.Add(3*time.Minute)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("ticker claim inside the member's lease = %v, want ErrNotFound", err)
			}
			if err := f.g.SetGcalCalendar(ctx, l1, "cal-now", f.now); err != nil {
				t.Fatalf("holder write: %v", err)
			}
			// CONTROL: past the lease the member claims again
			_, l2, err := f.g.ClaimGcalMember(ctx, f.tenant, f.m1, f.now.Add(6*time.Minute), 5*time.Minute)
			if err != nil {
				t.Fatalf("claim after the lease ended: %v", err)
			}
			if err := f.g.SetGcalStatus(ctx, l2, GcalRevoked, "invalid_grant", f.now); err != nil {
				t.Fatal(err)
			}
			if err := f.g.FinishGcalSync(ctx, l2, GcalSyncDone{NextDue: f.now}, f.now); err != nil {
				t.Fatal(err)
			}
			if _, _, err := f.g.ClaimGcalMember(ctx, f.tenant, f.m1, f.now.Add(7*time.Minute), 5*time.Minute); !errors.Is(err, ErrNotFound) {
				t.Fatalf("claim of a revoked connection = %v, want ErrNotFound", err)
			}
		})
	}
}
