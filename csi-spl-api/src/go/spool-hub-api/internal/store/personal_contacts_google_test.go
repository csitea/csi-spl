package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

// specs/154 B8 (amended; sections 2.5 "In", "Conflicts", "Deletes", 11.2.2,
// 11.3): the In half's store call ApplyGooglePeople, the out read's keyset
// over a tie, and the two gcal_connections writes the contacts cycle makes
// without the calendar's lease. Memory and Postgres (hub-pg.tst.sh).
// Fixtures are FirstName LastName and example.com.

const googleTestAccount = "first.last@example.com"

// gPerson is a Google person of the fixture's values.
func gPerson(resource, etag string, at time.Time) GooglePerson {
	return GooglePerson{Resource: resource, ETag: etag, UpdatedAt: at,
		Values: Contact{FirstName: "FirstName", LastName: "LastName", Email: "first.last@example.com", Phone: "+1 555 010 0000"}}
}

// applyG is one ApplyGooglePeople that must not fail.
func applyG(t *testing.T, f contactsFix, person string, a GoogleApply, now time.Time, people ...GooglePerson) GoogleApplied {
	t.Helper()
	n, err := f.st.ApplyGooglePeople(context.Background(), person, a, people, now)
	if err != nil {
		t.Fatalf("ApplyGooglePeople: %v", err)
	}
	return n
}

// outRows is every row of the person the out read answers, by resource.
func outRows(t *testing.T, f contactsFix, person string) map[string]ContactOut {
	t.Helper()
	rows, err := f.st.ContactsChangedSince(context.Background(), person, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]ContactOut{}
	for _, r := range rows {
		out[r.GoogleResource] = r
	}
	return out
}

// C15, C16, C41 (store half), C42 (in_only): a new person is inserted with
// its link and hash; the same person again writes nothing; a new etag alone
// is stored without moving updated_at.
func TestContactsGoogleApplyInsertEcho(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		t0 := time.Now().UTC().Truncate(time.Second)
		p1, p2 := realmPersons()
		f.addHuman(t, p1)
		f.addHuman(t, p2)
		a := GoogleApply{Account: "First.Last@Example.com"}
		p := gPerson("people/c1", "e1", t0)
		p.Values.Company, p.Values.JobTitle, p.Values.Birthday, p.Values.Notes = "Example Org", "Engineer", "--05-17", "a note"
		p.Values.InOnly = true
		if n := applyG(t, f, p1, a, t0, p); n.Added != 1 {
			t.Fatalf("C15 a new person: %+v, want 1 added", n)
		}
		r := outRows(t, f, p1)["people/c1"]
		if r.GoogleAccount != googleTestAccount || r.Email != "first.last@example.com" || r.Company != "Example Org" ||
			r.JobTitle != "Engineer" || r.Birthday != "--05-17" || r.Notes != "a note" || !r.InOnly ||
			r.SyncHash != ContactSyncHash(r.Contact) || r.GoogleETag != "e1" {
			t.Errorf("C15/C41 stored row: %+v, want the values, the link, in_only and the hash", r)
		}
		if n := applyG(t, f, p1, a, t0.Add(time.Minute), p); n.Unchanged != 1 || n.Added+n.Updated+n.Linked != 0 {
			t.Errorf("C16 echo: %+v, want 1 unchanged and no write", n)
		}
		p.ETag = "e2"
		applyG(t, f, p1, a, t0.Add(2*time.Minute), p)
		r2 := outRows(t, f, p1)["people/c1"]
		if r2.GoogleETag != "e2" || !r2.UpdatedAt.Equal(r.UpdatedAt) {
			t.Errorf("C16 a new etag alone: %+v, want etag e2 and updated_at kept", r2)
		}
		if rows := outRows(t, f, p2); len(rows) != 0 {
			t.Errorf("P2 holds %d rows after P1's sync, want 0", len(rows))
		}
	})
}

// C20, C20b, C23d: an unknown person links the oldest live contact of its
// email that is not linked under the account; the newer side's values win.
func TestContactsGoogleApplyLinkByEmail(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		t0 := time.Now().UTC().Truncate(time.Second)
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		old, err := f.st.CreateContact(ctx, p1, Contact{FirstName: "Old", Email: "first.last@example.com"}, t0)
		if err != nil {
			t.Fatal(err)
		}
		newer, err := f.st.CreateContact(ctx, p1, Contact{FirstName: "New", Email: "first.last@example.com"}, t0.Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		a := GoogleApply{Account: googleTestAccount}
		if n := applyG(t, f, p1, a, t0.Add(time.Hour), gPerson("people/c1", "e1", t0.Add(time.Minute))); n.Linked != 1 || n.Added != 0 {
			t.Fatalf("C20 first sync: %+v, want 1 linked, 0 added", n)
		}
		rows := outRows(t, f, p1)
		got := rows["people/c1"]
		if got.ID != old.ID || got.FirstName != "FirstName" {
			t.Errorf("C20b linked %s (%q), want the older %s with Google's (newer) values", got.ID, got.FirstName, old.ID)
		}
		if r := rows[""]; r.ID != newer.ID {
			t.Errorf("C20b the newer contact: %+v, want it unlinked", r)
		}
		// Spool newer than Google: linked with Spool's values and no hash, so the Out half sends them.
		p2, _ := realmPersons()
		f.addHuman(t, p2)
		mine, err := f.st.CreateContact(ctx, p2, Contact{FirstName: "Mine", Email: "first.last@example.com"}, t0.Add(time.Hour))
		if err != nil {
			t.Fatal(err)
		}
		applyG(t, f, p2, a, t0.Add(2*time.Hour), gPerson("people/c9", "e9", t0))
		if r := outRows(t, f, p2)["people/c9"]; r.ID != mine.ID || r.FirstName != "Mine" || r.SyncHash != "" {
			t.Errorf("C20 Spool newer: %+v, want Spool's values linked with no hash", r)
		}
		// C23d: the binding moves to another account: linked again by email under it.
		b := GoogleApply{Account: "second.account@example.com"}
		n := applyG(t, f, p1, b, t0.Add(3*time.Hour), gPerson("people/x1", "x1", t0.Add(3*time.Hour)))
		if n.Linked != 1 || n.OtherAccount != 0 {
			t.Errorf("C23d move: %+v, want the a@ contact relinked under b@ by email", n)
		}
		n = applyG(t, f, p1, b, t0.Add(3*time.Hour))
		if n.OtherAccount != 0 {
			t.Errorf("C23d after the move: %d contacts under another account, want 0", n.OtherAccount)
		}
		if n := applyG(t, f, p1, a, t0.Add(4*time.Hour)); n.OtherAccount != 1 {
			t.Errorf("C23d twin: bound to a@ again, %d under another account, want 1", n.OtherAccount)
		}
	})
}

// C18, C23e, C23f, C19 (no deletes): the conflict table on a linked contact.
func TestContactsGoogleApplyConflicts(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		t0 := time.Now().UTC().Truncate(time.Second)
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		a := GoogleApply{Account: googleTestAccount}
		applyG(t, f, p1, a, t0, gPerson("people/c1", "e1", t0), gPerson("people/c2", "e1", t0), gPerson("people/c3", "e1", t0))
		rows := outRows(t, f, p1)
		edit := func(id, name string, at time.Time) {
			if _, err := f.st.PatchContact(ctx, p1, id, ContactPatch{FirstName: &name}, at); err != nil {
				t.Fatal(err)
			}
		}
		// C18: both edited, Google later -> Google's values; Spool later -> Spool kept.
		edit(rows["people/c1"].ID, "SpoolEdit", t0.Add(time.Minute))
		g1 := gPerson("people/c1", "e2", t0.Add(2*time.Minute))
		g1.Values.FirstName = "GoogleEdit"
		edit(rows["people/c2"].ID, "SpoolEdit", t0.Add(3*time.Minute))
		g2 := gPerson("people/c2", "e2", t0.Add(2*time.Minute))
		g2.Values.FirstName = "GoogleEdit"
		n := applyG(t, f, p1, a, t0.Add(4*time.Minute), g1, g2)
		rows = outRows(t, f, p1)
		if n.Updated != 1 || n.SpoolKept != 1 || rows["people/c1"].FirstName != "GoogleEdit" || rows["people/c2"].FirstName != "SpoolEdit" {
			t.Errorf("C18: %+v c1=%q c2=%q, want Google later wins c1, Spool later keeps c2", n, rows["people/c1"].FirstName, rows["people/c2"].FirstName)
		}
		if r := rows["people/c2"]; r.GoogleETag != "e2" || r.SyncHash == ContactSyncHash(r.Contact) {
			t.Errorf("C18 Spool kept: %+v, want Google's etag stored and the hash still Google's old one (the Out half sends)", r)
		}
		// C19: the full list after an expired token never deletes.
		gone := gPerson("people/c3", "e3", t0.Add(5*time.Minute))
		gone.Deleted = true
		if n := applyG(t, f, p1, GoogleApply{Account: googleTestAccount, NoDeletes: true}, t0.Add(5*time.Minute), gone); n.Deleted != 0 {
			t.Errorf("C19 NoDeletes: %+v, want no delete", n)
		}
		// C23e: edited in Spool, deleted at Google -> soft-deleted by google-sync, not sent back.
		edit(rows["people/c3"].ID, "SpoolEdit", t0.Add(6*time.Minute))
		if n := applyG(t, f, p1, a, t0.Add(7*time.Minute), gone); n.Deleted != 1 {
			t.Errorf("C23e: %+v, want 1 deleted", n)
		}
		if _, ok := outRows(t, f, p1)["people/c3"]; ok {
			t.Errorf("C23e: a Google-side delete is in the out read, want it never sent back")
		}
		// C23f: deleted in Spool, edited at Google -> nothing in, the delete stays to send.
		if err := f.st.DeleteContact(ctx, p1, rows["people/c1"].ID, ContactDeletedByMember, t0.Add(8*time.Minute)); err != nil {
			t.Fatal(err)
		}
		g1.ETag, g1.UpdatedAt, g1.Values.FirstName = "e4", t0.Add(9*time.Minute), "Again"
		if n := applyG(t, f, p1, a, t0.Add(10*time.Minute), g1); n.Unchanged != 1 || n.Added != 0 {
			t.Errorf("C23f: %+v, want the person not re-imported", n)
		}
		if r := outRows(t, f, p1)["people/c1"]; r.DeletedAt == nil {
			t.Errorf("C23f: %+v, want the member's delete still to send", r)
		}
	})
}

// The B14 lock (11.6 B8 amended): an import and a sync page of the same new
// people, released at once, add each person once, round after round (the
// form of C33b). On Memory s.mu serialises them; the Postgres twin is the
// lock itself.
func TestContactsGoogleApplyBesideImport(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		t0 := time.Now().UTC().Truncate(time.Second)
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		const rounds, perRound = 10, 30
		for round := range rounds {
			rows := make([]Contact, perRound)
			people := make([]GooglePerson, perRound)
			for i := range rows {
				email := fmt.Sprintf("r%d.n%d@example.com", round, i)
				rows[i] = Contact{Email: email}
				people[i] = GooglePerson{Resource: fmt.Sprintf("people/r%dn%d", round, i), ETag: "e", UpdatedAt: t0,
					Values: Contact{Email: email}}
			}
			var wg sync.WaitGroup
			start := make(chan struct{})
			errs := make([]error, 2)
			wg.Add(2)
			go func() {
				defer wg.Done()
				<-start
				_, errs[0] = f.st.ImportContacts(ctx, p1, rows, t0)
			}()
			go func() {
				defer wg.Done()
				<-start
				_, errs[1] = f.st.ApplyGooglePeople(ctx, p1, GoogleApply{Account: googleTestAccount}, people, t0)
			}()
			close(start)
			wg.Wait()
			if errs[0] != nil || errs[1] != nil {
				t.Fatalf("round %d: %v, %v", round, errs[0], errs[1])
			}
		}
		all, err := f.st.ExportContacts(ctx, p1)
		if err != nil || len(all) != rounds*perRound {
			t.Errorf("an import beside the sync: %d contacts (%v), want %d", len(all), err, rounds*perRound)
		}
	})
}

// The out read's keyset: more rows than one page at one changed time are
// read whole, page by page, by (time, id).
func TestContactsChangedSinceTie(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		t0 := time.Now().UTC().Truncate(time.Second)
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		rows := make([]Contact, ContactsCycleMax+5)
		for i := range rows {
			rows[i] = Contact{FirstName: "FirstName", LastName: fmt.Sprintf("LastName%04d", i)}
		}
		if _, err := f.st.ImportContacts(ctx, p1, rows, t0); err != nil {
			t.Fatal(err)
		}
		first, err := f.st.ContactsChangedSince(ctx, p1, nil, "")
		if err != nil || len(first) != ContactsCycleMax {
			t.Fatalf("first page: %d (%v)", len(first), err)
		}
		last := first[len(first)-1]
		next, err := f.st.ContactsChangedSince(ctx, p1, &last.ChangedAt, last.ID)
		if err != nil || len(next) != 5 {
			t.Errorf("the tie's rest: %d rows (%v), want 5", len(next), err)
		}
		if old, _ := f.st.ContactsChangedSince(ctx, p1, &last.ChangedAt, ""); len(old) != 0 {
			t.Errorf("control, time only: %d rows, want 0 (the tie is lost without the id)", len(old))
		}
	})
}

// C23b, C23c (store half): the contacts cycle's token write and revoke
// touch only their columns: a calendar cycle holding its lease keeps it,
// its due_at and its sync token; no connection is ErrNotFound.
func TestGcalSharedWrites(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Second)
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		w := f.newTenant(t)
		f.seat(t, w, p1)
		gs := any(f.st).(Gcal)
		sh := any(f.st).(GcalShared)
		before, err := gs.GcalConnection(ctx, w, p1)
		if err != nil {
			t.Fatal(err)
		}
		_, l, err := gs.ClaimGcalMember(ctx, w, p1, now, time.Minute)
		if err != nil {
			t.Fatal(err)
		}
		tok := GcalTokens{AccessSealed: "sealed-a2", RefreshSealed: "sealed-r1", KMSKeyID: "k1", AccessExpiry: now.Add(time.Hour)}
		if err := sh.SetGcalAccess(ctx, w, p1, tok, now); err != nil {
			t.Fatal(err)
		}
		got, err := gs.GcalTokens(ctx, w, p1)
		if err != nil || got.AccessSealed != "sealed-a2" {
			t.Errorf("SetGcalAccess: %+v (%v)", got, err)
		}
		after, _ := gs.GcalConnection(ctx, w, p1)
		if !after.DueAt.Equal(before.DueAt) || after.SyncToken != before.SyncToken {
			t.Errorf("C23c: due_at %v -> %v, sync token %q -> %q, want both kept", before.DueAt, after.DueAt, before.SyncToken, after.SyncToken)
		}
		if _, err := gs.RenewGcalLease(ctx, l, now, time.Minute); err != nil {
			t.Errorf("C23c: the calendar cycle's lease after the contacts write: %v, want held", err)
		}
		if err := sh.RevokeGcalConnection(ctx, w, p1, "invalid_grant: reconnect", now); err != nil {
			t.Fatal(err)
		}
		if c, _ := gs.GcalConnection(ctx, w, p1); c.Status != GcalRevoked {
			t.Errorf("C23b revoke: status %q, want revoked", c.Status)
		}
		p2, _ := realmPersons()
		if err := sh.SetGcalAccess(ctx, w, p2, tok, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("no connection: %v, want ErrNotFound", err)
		}
	})
}
