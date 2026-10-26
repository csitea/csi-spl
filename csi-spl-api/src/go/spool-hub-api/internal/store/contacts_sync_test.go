package store

import (
	"context"
	"errors"
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
