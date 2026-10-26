package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/154 B2 (sections 2.2, 2.6; case C2e): the contacts binding store
// and the purge, through the store, on Memory and Postgres (the driver of
// personal_contacts_test.go).

// TestContactsSyncBinding is spec 2.2 step 3 through the store: one binding
// per person; a second one in another workspace is ErrContactsSyncElsewhere
// and leaves the first unchanged (C7d's store half); no seat or no Google
// connection is ErrNotFound; off touches only a binding in that workspace;
// "Sync now" waits for a held lease; the operator read finds the binding
// from anywhere (N4).
func TestContactsSyncBinding(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, p2 := realmPersons()
		f.addHuman(t, p1)
		f.addHuman(t, p2)
		w1, w2 := f.newTenant(t), f.newTenant(t)
		f.seat(t, w1, p1)
		f.seat(t, w2, p1)
		f.seat(t, w2, p2)
		if _, err := f.st.SetContactsSync(ctx, w1, p2, true, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("P2 has no seat in W1: %v, want ErrNotFound", err)
		}
		b, err := f.st.SetContactsSync(ctx, w1, p1, true, now)
		if err != nil || !b.Enabled || b.Tenant != w1 || b.Human != p1 {
			t.Fatalf("P1's binding in W1: %+v (%v)", b, err)
		}
		if _, err := f.st.SetContactsSync(ctx, w2, p1, true, now); !errors.Is(err, ErrContactsSyncElsewhere) {
			t.Errorf("C7d P1's second binding, in W2: %v, want ErrContactsSyncElsewhere", err)
		}
		if got, err := f.st.ContactsSyncIn(ctx, w1, p1); err != nil || !got.Enabled || got.Tenant != w1 {
			t.Errorf("C7d W1's binding after the refusal: %+v (%v), want unchanged", got, err)
		}
		if _, err := f.st.ContactsSyncIn(ctx, w2, p1); !errors.Is(err, ErrNotFound) {
			t.Errorf("W2 reads P1's binding in W1: %v, want ErrNotFound", err)
		}
		if got, err := f.st.ContactsSyncOf(ctx, p1); err != nil || got.Tenant != w1 {
			t.Errorf("N4 P1's binding from anywhere: %+v (%v), want W1's", got, err)
		}
		if _, err := f.st.ContactsSyncOf(ctx, p2); !errors.Is(err, ErrNotFound) {
			t.Errorf("N4 P2 has no binding: %v, want ErrNotFound", err)
		}
		if _, err := f.st.SetContactsSync(ctx, w2, p2, true, now); err != nil {
			t.Errorf("C7d twin: P2's binding in W2: %v", err)
		}
		// off: only where the binding is.
		if _, err := f.st.SetContactsSync(ctx, w2, p1, false, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("off in W2 where P1 has no binding: %v, want ErrNotFound", err)
		}
		if got, err := f.st.SetContactsSync(ctx, w1, p1, false, now); err != nil || got.Enabled {
			t.Errorf("off in W1: %+v (%v), want enabled false", got, err)
		}
		if err := f.st.MarkContactsSyncDue(ctx, w1, p1, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("sync now on a binding that is off: %v, want ErrNotFound", err)
		}
		later := now.Add(time.Minute)
		if got, err := f.st.SetContactsSync(ctx, w1, p1, true, later); err != nil || !got.Enabled || got.DueAt.Before(later.Add(-time.Millisecond)) {
			t.Errorf("on again in W1: %+v (%v), want enabled and due now", got, err)
		}
		if err := f.st.MarkContactsSyncDue(ctx, w1, p1, later); err != nil {
			t.Errorf("sync now: %v", err)
		}
		f.lease(t, w1, p1, later.Add(time.Minute))
		if err := f.st.MarkContactsSyncDue(ctx, w1, p1, later); !errors.Is(err, ErrContactsSyncBusy) {
			t.Errorf("sync now under a held lease: %v, want ErrContactsSyncBusy", err)
		}
		if err := f.st.MarkContactsSyncDue(ctx, w1, p1, later.Add(2*time.Minute)); err != nil {
			t.Errorf("sync now after the lease ran out: %v", err)
		}
	})
}

// TestContactsC2ePurgeThroughStore is C2e: PurgeDeletedContacts deletes
// every person's rows soft-deleted more than 30 days ago and names each
// person once, pending only for a member's delete of a linked contact; rows
// 29 days old and live rows stay. MarkContactsPurgePending then sets the
// status line of each pending person's binding, and of no other. Twin on
// Postgres: the runtime's own DELETE under the operator scope deletes 0
// rows. TestPersonScopeCallers (C3c) proves neither call mixes scopes.
func TestContactsC2ePurgeThroughStore(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		day := 24 * time.Hour
		p1, p2 := realmPersons()
		f.addHuman(t, p1)
		f.addHuman(t, p2)
		w := f.newTenant(t)
		for _, p := range []string{p1, p2} {
			f.seat(t, w, p)
			if _, err := f.st.SetContactsSync(ctx, w, p, true, now); err != nil {
				t.Fatal(err)
			}
		}
		add := func(person string, linked bool, by string, age time.Duration) {
			t.Helper()
			c, err := f.st.CreateContact(ctx, person, ffContact(), now.Add(-age-day))
			if err != nil {
				t.Fatal(err)
			}
			if linked {
				f.link(t, person, c.ID)
			}
			if by != "" {
				if err := f.st.DeleteContact(ctx, person, c.ID, by, now.Add(-age)); err != nil {
					t.Fatal(err)
				}
			}
		}
		add(p1, true, ContactDeletedByMember, 31*day)  // an unsent Google delete
		add(p1, false, ContactDeletedByMember, 31*day) // nothing to send
		add(p2, true, ContactDeletedByGoogle, 31*day)  // came from Google
		for _, p := range []string{p1, p2} {
			add(p, true, ContactDeletedByMember, 29*day)
			add(p, false, "", 0)
		}

		if f.pg != nil {
			rt := f.st.(*Postgres)
			var n int64
			if err := rt.asOperator(ctx, func(tx pgx.Tx) error {
				tag, err := tx.Exec(ctx, `DELETE FROM personal.contacts WHERE person_id IN ($1, $2)`, p1, p2)
				n = tag.RowsAffected()
				return err
			}); err != nil || n != 0 {
				t.Errorf("C2e twin: the runtime's own DELETE under the operator scope: %d row(s) (%v), want 0", n, err)
			}
		}

		purged, err := f.st.PurgeDeletedContacts(ctx, now.Add(-30*day))
		if err != nil {
			t.Fatalf("C2e PurgeDeletedContacts: %v", err)
		}
		got := map[string][]bool{}
		var pending []string
		for _, p := range purged {
			if p.Person == p1 || p.Person == p2 {
				got[p.Person] = append(got[p.Person], p.PendingGoogle)
				if p.PendingGoogle {
					pending = append(pending, p.Person)
				}
			}
		}
		if len(got) != 2 || len(got[p1]) != 1 || len(got[p2]) != 1 || !got[p1][0] || got[p2][0] {
			t.Errorf("C2e purge result: %v, want each person once: %s pending, %s not", got, p1, p2)
		}
		n, err := f.st.MarkContactsPurgePending(ctx, pending, now)
		if err != nil || n != 1 {
			t.Errorf("C2e MarkContactsPurgePending(%v): %d binding(s) (%v), want 1", pending, n, err)
		}
		for _, c := range []struct {
			who, want string
		}{{p1, ContactsPurgePendingDetail}, {p2, ""}} {
			b, err := f.st.ContactsSyncOf(ctx, c.who)
			if err != nil || b.StatusDetail != c.want {
				t.Errorf("C2e %s's status line: %q (%v), want %q", c.who, b.StatusDetail, err, c.want)
			}
		}
		for _, p := range []string{p1, p2} {
			if left, err := f.st.EraseContacts(ctx, p); err != nil || left != 2 {
				t.Errorf("C2e %s's rows after the purge: %d (%v), want 2 (the 29-day-old and the live)", p, left, err)
			}
		}
		if n, err := f.st.MarkContactsPurgePending(ctx, nil, now); err != nil || n != 0 {
			t.Errorf("no persons: %d (%v), want 0", n, err)
		}
	})
}

// claimAll claims every due binding at now (a shared Postgres may hold other
// due rows) and returns each claimed human's binding and lease, in claim
// order; the claim that ends it is ErrNotFound.
func claimAll(t *testing.T, st ContactsSyncs, now time.Time) (order []string, got map[string]ContactsLease) {
	t.Helper()
	got = map[string]ContactsLease{}
	for range 1000 {
		b, l, err := st.ClaimContactsSync(context.Background(), now, 5*time.Minute)
		if errors.Is(err, ErrNotFound) {
			return order, got
		}
		if err != nil {
			t.Fatalf("claim: %v", err)
		}
		if b.SyncLeaseUntil == nil || !b.SyncLeaseUntil.Equal(l.Until) || l.Tenant != b.Tenant || l.Human != b.Human {
			t.Fatalf("claim returned %+v with lease %+v", b, l)
		}
		order, got[b.Human] = append(order, b.Human), l
	}
	t.Fatal("the claims never ran out")
	return nil, nil
}

// indexOf is the position of s in xs, or -1.
func indexOf(xs []string, s string) int {
	for i, x := range xs {
		if x == s {
			return i
		}
	}
	return -1
}

// TestContactsC23hClaim is C23h: the claim (operator scope) takes the due
// bindings of every workspace, the one due longest first, each with its
// fencing token; it skips a binding whose Google connection is not
// connected, one that is off, one under a held lease and one in backoff.
// Twin: once none is due or connected, the claim is ErrNotFound; when the
// backoff ends, that binding is claimed.
func TestContactsC23hClaim(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		// Ten years back: rows other tests left due "now" are not due here.
		now := time.Now().UTC().AddDate(-10, 0, 0).Truncate(time.Second)
		older, due := realmPersons()
		revoked, off := realmPersons()
		leased, backed := realmPersons()
		w1, w2 := f.newTenant(t), f.newTenant(t)
		for i, p := range []string{older, due, revoked, off, leased, backed} {
			w := w1
			if i%2 == 1 {
				w = w2
			}
			f.addHuman(t, p)
			f.seat(t, w, p)
			if _, err := f.st.SetContactsSync(ctx, w, p, true, now.Add(-time.Duration(10-i)*time.Minute)); err != nil {
				t.Fatal(err)
			}
		}
		f.gcalState(t, w1, revoked, GcalRevoked)
		if _, err := f.st.SetContactsSync(ctx, w2, off, false, now); err != nil {
			t.Fatal(err)
		}
		f.lease(t, w1, leased, now.Add(time.Hour))
		f.backoff(t, w2, backed, now.Add(10*time.Minute))

		order, got := claimAll(t, f.st, now)
		if _, ok := got[older]; !ok {
			t.Errorf("C23h the due binding in W1 was not claimed: %v", order)
		}
		if l, ok := got[due]; !ok || l.Tenant != w2 {
			t.Errorf("C23h the due binding in W2: %+v (claimed %v), want its lease in W2", l, ok)
		}
		if i, j := indexOf(order, older), indexOf(order, due); i < 0 || j < 0 || i > j {
			t.Errorf("C23h claim order %v: the one due longest (%s) first", order, older)
		}
		for _, p := range []string{revoked, off, leased, backed} {
			if _, ok := got[p]; ok {
				t.Errorf("C23h %s claimed, want it skipped (not connected, off, leased or in backoff)", p)
			}
		}
		if _, _, err := f.st.ClaimContactsSync(ctx, now, 5*time.Minute); !errors.Is(err, ErrNotFound) {
			t.Errorf("C23h twin: nothing left due: %v, want ErrNotFound", err)
		}
		later := now.Add(11 * time.Minute)
		order, got = claimAll(t, f.st, later)
		if _, ok := got[backed]; !ok {
			t.Errorf("C23h twin: the backoff ended, its binding is not claimed: %v", order)
		}
		for _, p := range []string{revoked, off, leased} {
			if _, ok := got[p]; ok {
				t.Errorf("C23h %s claimed after the backoff ended, want it still skipped", p)
			}
		}
	})
}

// TestContactsC23iFencedWrites is C23i: in the binding's workspace scope,
// the renewal moves the lease to a new fencing token, the backoff write
// stores backoff_until and the status line, the finish stores the cursors,
// last_synced_at and due_at and clears the lease. The stale token, a lease
// naming another workspace and a finished lease are each refused with
// ErrContactsLeaseLost and change nothing.
func TestContactsC23iFencedWrites(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now().UTC().AddDate(-10, 0, 0).Add(time.Hour).Truncate(time.Second)
		p, _ := realmPersons()
		f.addHuman(t, p)
		w, other := f.newTenant(t), f.newTenant(t)
		f.seat(t, w, p)
		if _, err := f.st.SetContactsSync(ctx, w, p, true, now.Add(-time.Minute)); err != nil {
			t.Fatal(err)
		}
		_, got := claimAll(t, f.st, now)
		l, ok := got[p]
		if !ok {
			t.Fatal("C23i the binding was not claimed")
		}
		l2, err := f.st.RenewContactsLease(ctx, l, now.Add(time.Minute), 5*time.Minute)
		if err != nil || l2.Until.Equal(l.Until) || l2.Tenant != w || l2.Human != p {
			t.Fatalf("C23i renewal: %+v (%v), want a new token", l2, err)
		}
		lost := func(what string, err error) {
			t.Helper()
			if !errors.Is(err, ErrContactsLeaseLost) {
				t.Errorf("C23i %s: %v, want ErrContactsLeaseLost", what, err)
			}
		}
		_, err = f.st.RenewContactsLease(ctx, l, now.Add(time.Minute), 5*time.Minute)
		lost("renewal with the stale token", err)
		lost("backoff with the stale token", f.st.SetContactsBackoff(ctx, l, nil, "stale", now))
		lost("finish with the stale token", f.st.FinishContactsSync(ctx, l, ContactsSyncDone{NextDue: now}, now))
		elsewhere := l2
		elsewhere.Tenant = other
		lost("a lease naming another workspace", f.st.FinishContactsSync(ctx, elsewhere, ContactsSyncDone{NextDue: now}, now))

		until := now.Add(30 * time.Minute)
		detail := "Google asked to wait (429)."
		if err := f.st.SetContactsBackoff(ctx, l2, &until, strings.Repeat("x", ContactsStatusDetailMax+1), now); !errors.Is(err, ErrContactsSyncBad) {
			t.Errorf("C23i a status line above %d characters: %v, want ErrContactsSyncBad", ContactsStatusDetailMax, err)
		}
		if err := f.st.SetContactsBackoff(ctx, l2, &until, detail, now.Add(2*time.Minute)); err != nil {
			t.Errorf("C23i fenced backoff: %v", err)
		}
		cursor := now.Add(90 * time.Second)
		next := now.Add(10 * time.Minute)
		if err := f.st.FinishContactsSync(ctx, l2, ContactsSyncDone{SyncToken: "tok-1", OutCursor: &cursor, NextDue: next}, now.Add(3*time.Minute)); err != nil {
			t.Fatalf("C23i finish: %v", err)
		}
		b, err := f.st.ContactsSyncIn(ctx, w, p)
		switch {
		case err != nil:
			t.Fatalf("C23i read back: %v", err)
		case b.SyncLeaseUntil != nil:
			t.Errorf("C23i finish left the lease: %v", b.SyncLeaseUntil)
		case b.LastSyncedAt == nil || !b.LastSyncedAt.Equal(now.Add(3*time.Minute)) || !b.DueAt.Equal(next):
			t.Errorf("C23i finish: last_synced_at %v, due_at %v, want %v and %v", b.LastSyncedAt, b.DueAt, now.Add(3*time.Minute), next)
		case b.SyncToken != "tok-1" || b.OutCursor == nil || !b.OutCursor.Equal(cursor):
			t.Errorf("C23i finish: sync token %q, out cursor %v, want tok-1 and %v", b.SyncToken, b.OutCursor, cursor)
		case b.BackoffUntil == nil || !b.BackoffUntil.Equal(until) || b.StatusDetail != detail:
			t.Errorf("C23i the backoff after the finish: %v %q, want %v %q kept", b.BackoffUntil, b.StatusDetail, until, detail)
		}
		lost("finish with a finished lease", f.st.FinishContactsSync(ctx, l2, ContactsSyncDone{NextDue: now}, now))
		if again, err := f.st.ContactsSyncIn(ctx, w, p); err != nil || !again.DueAt.Equal(next) || again.SyncToken != "tok-1" {
			t.Errorf("C23i the refused writes changed the binding: %+v (%v)", again, err)
		}
	})
}
