package store

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/154 B2 (sections 2.3, 2.6, 4, 5; cases C3, C3b): the contacts
// store. Each case runs on Memory and, under hub-pg.tst.sh or
// hub-live-stack.sh with SPOOL_TEST_PG_DSN and SPOOL_TEST_PG_RUNTIME_DSN, on
// Postgres as the runtime login (no superuser, no BYPASSRLS). C3c is
// TestPersonScopeCallers (personal_scope_test.go); C2e and the binding are
// contacts_sync_test.go's. Fixtures are FirstName LastName and example.com.

// contactsStore is both halves of spec 154 B2's store, and B8a's cycle.
type contactsStore interface {
	PersonalContacts
	ContactsSyncs
	ContactsCycle
}

// contactsFix is one driver: the store, and how to seed what the store
// does not write itself (a human, a workspace seat with its Google
// connection, a Google link, a held sync lease).
type contactsFix struct {
	st        contactsStore
	pg        *Postgres // the migrate login; nil on Memory
	addHuman  func(t *testing.T, person string)
	newTenant func(t *testing.T) string
	seat      func(t *testing.T, tenant, human string)
	link      func(t *testing.T, person, contactID string)
	lease     func(t *testing.T, tenant, human string, until time.Time)
	gcalState func(t *testing.T, tenant, human, status string)          // the Google connection's status (B8a)
	backoff   func(t *testing.T, tenant, human string, until time.Time) // contacts_sync.backoff_until (B8a)
}

func memContactsFix(*testing.T) contactsFix {
	rf := memRealmFix()
	m := rf.st.(*Memory)
	return contactsFix{st: m, addHuman: rf.addHuman,
		newTenant: func(*testing.T) string { return uid("t-c605-") },
		seat: func(_ *testing.T, tenant, human string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.hum.init()
			m.hum.members[[2]string{tenant, human}] = memMember{role: "developer"}
			g := m.gcalLocked()
			id := memUUID()
			g.conns[id] = &GcalConnection{ID: id, Tenant: tenant, Human: human, GoogleEmail: "first.last@example.com",
				Status: GcalConnected}
		},
		link: func(t *testing.T, person, contactID string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			c, err := m.liveContactLocked(person, contactID)
			if err != nil {
				t.Fatal(err)
			}
			c.GoogleAccount, c.GoogleResource = "first.last@example.com", "people/c"+contactID[:8]
		},
		lease: func(_ *testing.T, tenant, human string, until time.Time) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.bindingInLocked(tenant, human).SyncLeaseUntil = &until
		},
		gcalState: func(_ *testing.T, tenant, human, status string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.gcalLocked().member(tenant, human).Status = status
		},
		backoff: func(_ *testing.T, tenant, human string, until time.Time) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.bindingInLocked(tenant, human).BackoffUntil = &until
		},
	}
}

func pgContactsFix(t *testing.T) contactsFix {
	rf, pg, rt := pgRealmFix(t)
	ctx := context.Background()
	asOwner := func(t *testing.T, person, tenant, sql string, args ...any) {
		t.Helper()
		err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if err := scope(ctx, tx, person, tenant, ""); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, sql, args...)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return contactsFix{st: rt, pg: pg, addHuman: rf.addHuman,
		newTenant: func(t *testing.T) string {
			w := uid("t-c605-")
			if err := pg.CreateTenant(ctx, Tenant{ID: w, RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
			return w
		},
		seat: func(t *testing.T, tenant, human string) {
			asOwner(t, "", tenant, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by)
				VALUES ($1, $2, 'developer', 'operator')`, tenant, human)
			if err := seedGcalConnection(ctx, pg, tenant, human); err != nil {
				t.Fatal(err)
			}
		},
		link: func(t *testing.T, person, contactID string) {
			asOwner(t, person, "", `UPDATE personal.contacts SET google_account = 'first.last@example.com',
				google_resource = 'people/c' || left($2::text, 8) WHERE person_id = $1 AND contact_id = $2::uuid`, person, contactID)
		},
		lease: func(t *testing.T, tenant, human string, until time.Time) {
			asOwner(t, "", tenant, `UPDATE contacts_sync SET sync_lease_until = $3 WHERE tenant_id = $1 AND human_id = $2`,
				tenant, human, until)
		},
		gcalState: func(t *testing.T, tenant, human, status string) {
			asOwner(t, "", tenant, `UPDATE gcal_connections SET status = $3 WHERE tenant_id = $1 AND human_id = $2`,
				tenant, human, status)
		},
		backoff: func(t *testing.T, tenant, human string, until time.Time) {
			asOwner(t, "", tenant, `UPDATE contacts_sync SET backoff_until = $3 WHERE tenant_id = $1 AND human_id = $2`,
				tenant, human, until)
		},
	}
}

func eachContactsDriver(t *testing.T, run func(t *testing.T, f contactsFix)) {
	for name, mk := range map[string]func(*testing.T) contactsFix{"memory": memContactsFix, "postgres": pgContactsFix} {
		t.Run(name, func(t *testing.T) { run(t, mk(t)) })
	}
}

// ffContact is the spec's fixture contact (C5).
func ffContact() Contact {
	return Contact{FirstName: "FirstName", LastName: "LastName", Email: "First.Last@Example.com", Phone: "+1 555 010 0000"}
}

// contactsPair is two seeded persons, P1 holding the fixture contact.
func contactsPair(t *testing.T, f contactsFix, now time.Time) (p1, p2 string, c Contact) {
	t.Helper()
	p1, p2 = realmPersons()
	f.addHuman(t, p1)
	f.addHuman(t, p2)
	c, err := f.st.CreateContact(context.Background(), p1, ffContact(), now)
	if err != nil {
		t.Fatal(err)
	}
	return p1, p2, c
}

// contactIDs is the ids of a list, in order.
func contactIDs(cs []Contact) []string {
	out := []string{}
	for _, c := range cs {
		out = append(out, c.ID)
	}
	return out
}

// listAll is every contact of person matching q, through ListContacts.
func listAll(t *testing.T, st PersonalContacts, person, q string) []Contact {
	t.Helper()
	p, err := st.ListContacts(context.Background(), person, ContactQuery{Q: q})
	if err != nil {
		t.Fatal(err)
	}
	return p.Contacts
}

// TestContactsC3OtherPerson is C3: P2 lists, reads, patches and deletes
// P1's contact: not found, nothing changed. Twin: P1 does each.
func TestContactsC3OtherPerson(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, p2, c := contactsPair(t, f, now)
		if got := listAll(t, f.st, p2, ""); len(got) != 0 {
			t.Errorf("C3 P2's list holds %d contact(s), want 0", len(got))
		}
		if _, err := f.st.ContactOf(ctx, p2, c.ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("C3 P2 reads P1's contact: %v, want ErrNotFound", err)
		}
		other := "Other"
		if _, err := f.st.PatchContact(ctx, p2, c.ID, ContactPatch{FirstName: &other}, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("C3 P2 patches P1's contact: %v, want ErrNotFound", err)
		}
		for _, by := range []string{"", ContactDeletedByMember} {
			if err := f.st.DeleteContact(ctx, p2, c.ID, by, now); !errors.Is(err, ErrNotFound) {
				t.Errorf("C3 P2 deletes P1's contact (by %q): %v, want ErrNotFound", by, err)
			}
		}
		if n, err := f.st.EraseContacts(ctx, p2); err != nil || n != 0 {
			t.Errorf("C3 P2's erase: %d row(s) (%v), want 0", n, err)
		}
		got, err := f.st.ContactOf(ctx, p1, c.ID)
		if err != nil || got != c {
			t.Fatalf("C3 nothing changed: P1 reads %+v (%v), want %+v", got, err, c)
		}
		// twin: P1 does each.
		if ids := contactIDs(listAll(t, f.st, p1, "")); len(ids) != 1 || ids[0] != c.ID {
			t.Errorf("C3 twin: P1's list %v, want [%s]", ids, c.ID)
		}
		patched, err := f.st.PatchContact(ctx, p1, c.ID, ContactPatch{FirstName: &other}, now.Add(time.Second))
		if err != nil || patched.FirstName != other || patched.LastName != c.LastName || !patched.UpdatedAt.After(c.UpdatedAt) {
			t.Errorf("C3 twin: P1's patch %+v (%v), want FirstName %q, the rest kept, updated_at moved", patched, err, other)
		}
		if err := f.st.DeleteContact(ctx, p1, c.ID, "", now); err != nil {
			t.Errorf("C3 twin: P1's delete: %v", err)
		}
		if _, err := f.st.ContactOf(ctx, p1, c.ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("C3 twin: P1's deleted contact reads %v, want ErrNotFound", err)
		}
	})
}

// TestContactsC3bOneListEveryWorkspace is C3b: P1 holds a seat in W1 and in
// W2; the list is the person's, read with no workspace, so a W1 session and
// a W2 session get the same rows, and so do the export and each read.
func TestContactsC3bOneListEveryWorkspace(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, _, c := contactsPair(t, f, now)
		w1, w2 := f.newTenant(t), f.newTenant(t)
		f.seat(t, w1, p1)
		f.seat(t, w2, p1)
		second, err := f.st.CreateContact(ctx, p1, Contact{Email: "second@example.com"}, now.Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		want := []string{c.ID, second.ID}
		for _, session := range []string{w1, w2} {
			if got := contactIDs(listAll(t, f.st, p1, "")); len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
				t.Errorf("C3b P1's list from %s: %v, want %v", session, got, want)
			}
		}
		exp, err := f.st.ExportContacts(ctx, p1)
		if got := contactIDs(exp); err != nil || len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
			t.Errorf("C3b P1's export: %v (%v), want %v", got, err, want)
		}
	})
}

// TestContactsValues: the four values are cleaned (trimmed, the email
// lowercased) and checked as rdb 0226's CHECKs; none at all, or a patch
// that clears the last one, is ErrContactEmpty.
func TestContactsValues(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, _, c := contactsPair(t, f, now)
		if c.Email != "first.last@example.com" || c.Phone != "+1 555 010 0000" || c.FirstName != "FirstName" {
			t.Errorf("C5 the stored values: %+v", c)
		}
		long := strings.Repeat("a", ContactNameMax+1)
		for name, tc := range map[string]struct {
			c    Contact
			want error
		}{
			"empty":        {Contact{FirstName: "  "}, ErrContactEmpty},
			"bad email":    {Contact{Email: "first.last"}, ErrContactBadEmail},
			"spaced email": {Contact{Email: "first last@example.com"}, ErrContactBadEmail},
			"bad phone":    {Contact{Phone: "call me"}, ErrContactBadPhone},
			"long name":    {Contact{FirstName: long}, ErrRealmBad},
		} {
			if _, err := f.st.CreateContact(ctx, p1, tc.c, now); !errors.Is(err, tc.want) || !errors.Is(err, ErrRealmBad) {
				t.Errorf("%s: %v, want %v (an ErrRealmBad)", name, err, tc.want)
			}
		}
		phone := Contact{Phone: "(555) 010-0000"}
		if _, err := f.st.CreateContact(ctx, p1, phone, now); err != nil {
			t.Errorf("a phone as typed: %v", err)
		}
		if _, err := f.st.CreateContact(ctx, "HUM-7000000001", ffContact(), now); !errors.Is(err, ErrNotFound) {
			t.Errorf("no such human: %v, want ErrNotFound", err)
		}
		empty := ""
		_, err := f.st.PatchContact(ctx, p1, c.ID, ContactPatch{FirstName: &empty, LastName: &empty, Email: &empty, Phone: &empty}, now)
		if !errors.Is(err, ErrContactEmpty) {
			t.Errorf("a patch clearing all four: %v, want ErrContactEmpty", err)
		}
		got, err := f.st.PatchContact(ctx, p1, c.ID, ContactPatch{Email: &empty, Phone: &empty}, now)
		if err != nil || got.Email != "" || got.Phone != "" || got.FirstName != "FirstName" {
			t.Errorf("a patch clearing email and phone: %+v (%v)", got, err)
		}
	})
}

// TestContactsQuery is spec 2.3's rule on ListContacts: each word a prefix
// of a name or the email, case-insensitive, a word of digits within the
// phone's digits (C10b's shape), LIKE's wildcards matched as text; and the
// pages by cursor.
func TestContactsQuery(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, p2, c := contactsPair(t, f, now)
		other, err := f.st.CreateContact(ctx, p1, Contact{FirstName: "Other", LastName: "Person", Email: "o_p@example.com"}, now.Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		for q, want := range map[string][]string{
			"":                 {c.ID, other.ID},
			"firstname":        {c.ID},
			"FIRST last":       {c.ID},
			"lastname first":   {c.ID},
			"first.last@ex":    {c.ID},
			"5550100000":       {c.ID},
			"010":              {c.ID},
			"name":             {},
			"%":                {},
			"o_p":              {other.ID},
			"o_":               {other.ID},
			"first nobody":     {},
			"other person ex.": {},
		} {
			got := contactIDs(listAll(t, f.st, p1, q))
			if len(got) != len(want) || (len(want) > 0 && got[0] != want[0]) {
				t.Errorf("q %q: %v, want %v", q, got, want)
			}
		}
		if got := listAll(t, f.st, p2, "firstname"); len(got) != 0 {
			t.Errorf("P2's search finds %d of P1's contacts, want 0", len(got))
		}
		page, err := f.st.ListContacts(ctx, p1, ContactQuery{Limit: 1})
		if err != nil || len(page.Contacts) != 1 || page.Contacts[0].ID != c.ID || page.Next == "" {
			t.Fatalf("page 1: %+v (%v), want [%s] and a cursor", page, err, c.ID)
		}
		page, err = f.st.ListContacts(ctx, p1, ContactQuery{Limit: 1, After: page.Next})
		if err != nil || len(page.Contacts) != 1 || page.Contacts[0].ID != other.ID || page.Next != "" {
			t.Errorf("page 2: %+v (%v), want [%s] and no cursor", page, err, other.ID)
		}
		if _, err := f.st.ListContacts(ctx, p1, ContactQuery{After: "not-a-cursor"}); !errors.Is(err, ErrRealmBad) {
			t.Errorf("a bad cursor: %v, want ErrRealmBad", err)
		}
	})
}

// TestContactsDeleteExportErase: a soft delete leaves every read at once;
// the export holds live contacts only; the erase removes every row of the
// person, soft-deleted ones too (C8e's store half).
func TestContactsDeleteExportErase(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, p2, c := contactsPair(t, f, now)
		kept, err := f.st.CreateContact(ctx, p1, Contact{LastName: "Kept"}, now.Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		if err := f.st.DeleteContact(ctx, p1, c.ID, "someone", now); !errors.Is(err, ErrRealmBad) {
			t.Errorf("an unknown deleted_by: %v, want ErrRealmBad", err)
		}
		if err := f.st.DeleteContact(ctx, p1, c.ID, ContactDeletedByMember, now); err != nil {
			t.Fatal(err)
		}
		if _, err := f.st.ContactOf(ctx, p1, c.ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("a soft-deleted contact reads %v, want ErrNotFound", err)
		}
		if err := f.st.DeleteContact(ctx, p1, c.ID, "", now); !errors.Is(err, ErrNotFound) {
			t.Errorf("deleting it again: %v, want ErrNotFound", err)
		}
		if got := contactIDs(listAll(t, f.st, p1, "")); len(got) != 1 || got[0] != kept.ID {
			t.Errorf("the list after a soft delete: %v, want [%s]", got, kept.ID)
		}
		exp, err := f.st.ExportContacts(ctx, p1)
		if got := contactIDs(exp); err != nil || len(got) != 1 || got[0] != kept.ID {
			t.Errorf("the export: %v (%v), want [%s]", got, err, kept.ID)
		}
		p2c, err := f.st.CreateContact(ctx, p2, ffContact(), now)
		if err != nil {
			t.Fatal(err)
		}
		if n, err := f.st.EraseContacts(ctx, p1); err != nil || n != 2 {
			t.Errorf("C8e P1's erase: %d row(s) (%v), want 2 (the live and the soft-deleted)", n, err)
		}
		if got := listAll(t, f.st, p1, ""); len(got) != 0 {
			t.Errorf("C8e P1's list after the erase: %d, want 0", len(got))
		}
		if _, err := f.st.ContactOf(ctx, p2, p2c.ID); err != nil {
			t.Errorf("C8e twin: P2's contact after P1's erase: %v", err)
		}
	})
}

// TestContactsRefuseBeforeSQL: every person call refuses a non-person with
// ErrNoPerson, and a malformed id is ErrNotFound, before any SQL (the
// Postgres has no pool, so a statement would panic).
func TestContactsRefuseBeforeSQL(t *testing.T) {
	ctx := context.Background()
	now := time.Now()
	id := "00000000-0000-4000-8000-000000000000"
	for name, st := range map[string]contactsStore{"postgres": &Postgres{}, "memory": NewMemory()} {
		for _, p := range refusedPersons {
			_, e1 := st.ListContacts(ctx, p, ContactQuery{})
			_, e2 := st.ContactOf(ctx, p, id)
			_, e3 := st.CreateContact(ctx, p, ffContact(), now)
			_, e4 := st.PatchContact(ctx, p, id, ContactPatch{}, now)
			e5 := st.DeleteContact(ctx, p, id, "", now)
			_, e6 := st.ExportContacts(ctx, p)
			_, e7 := st.EraseContacts(ctx, p)
			_, e8 := st.ContactsSyncIn(ctx, "ws-1", p)
			_, e9 := st.SetContactsSync(ctx, "ws-1", p, true, now)
			e10 := st.MarkContactsSyncDue(ctx, "ws-1", p, now)
			_, e11 := st.ContactsSyncOf(ctx, p)
			_, e12 := st.MarkContactsPurgePending(ctx, []string{p}, now)
			_, e13 := st.ImportContacts(ctx, p, []Contact{ffContact()}, now)
			_, e14 := st.PreviewContactsImport(ctx, p, []Contact{ffContact()})
			_, e15 := st.PutContactPhoto(ctx, p, id, testContactPhoto("a"), now)
			_, e16 := st.ContactPhoto(ctx, p, id)
			e17 := st.DeleteContactPhoto(ctx, p, id)
			_, e18 := st.CountContactPhotos(ctx, p)
			for i, err := range []error{e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12, e13, e14, e15, e16, e17, e18} {
				if !errors.Is(err, ErrNoPerson) {
					t.Errorf("%s call %d (%q): %v, want ErrNoPerson", name, i+1, p, err)
				}
			}
		}
		if _, err := st.ContactOf(ctx, "HUM-1", "not-a-uuid"); !errors.Is(err, ErrNotFound) {
			t.Errorf("%s a malformed id: %v, want ErrNotFound", name, err)
		}
	}
}

// TestContactsC23gCycleReadsWrites is C23g at store level (seat note N2:
// B8 builds the cycle): the cycle's contact calls run in inPerson of the
// binding's human. The outbound read returns the person's contacts changed
// since the cursor in changed order, live rows and a member's soft delete
// still to send, never a Google-side delete nor another person's row; a
// link stores google_account (lowercased), google_resource, google_etag and
// sync_hash without moving updated_at; a soft-deleted row is hard-deleted
// once Google confirmed, a live one never. Postgres: the claim's operator
// scope reads 0 rows of the same contacts (the control), the person scope
// all of them (the twin).
func TestContactsC23gCycleReadsWrites(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		t0 := time.Now().UTC().Truncate(time.Second)
		p1, p2 := realmPersons()
		f.addHuman(t, p1)
		f.addHuman(t, p2)
		var c [3]Contact
		for i := range c {
			var err error
			if c[i], err = f.st.CreateContact(ctx, p1, ffContact(), t0.Add(time.Duration(i)*time.Second)); err != nil {
				t.Fatal(err)
			}
		}
		other, err := f.st.CreateContact(ctx, p2, ffContact(), t0)
		if err != nil {
			t.Fatal(err)
		}
		changed := func(person string, since *time.Time) []string {
			t.Helper()
			rows, err := f.st.ContactsChangedSince(ctx, person, since)
			if err != nil {
				t.Fatalf("C23g ContactsChangedSince: %v", err)
			}
			ids := []string{}
			for _, r := range rows {
				ids = append(ids, r.ID)
			}
			return ids
		}
		if got := changed(p1, nil); strings.Join(got, ",") != c[0].ID+","+c[1].ID+","+c[2].ID {
			t.Errorf("C23g outbound read, no cursor: %v, want P1's three in changed order", got)
		}
		if got := changed(p1, &t0); strings.Join(got, ",") != c[1].ID+","+c[2].ID {
			t.Errorf("C23g outbound read since t0: %v, want the two changed after it", got)
		}
		if got := changed(p2, nil); len(got) != 1 || got[0] != other.ID {
			t.Errorf("C23g P2's outbound read: %v, want only [%s]", got, other.ID)
		}

		hash := strings.Repeat("0123456789abcdef", 4)
		link := ContactLink{Account: "First.Last@Example.com", Resource: "people/c1", ETag: "etag-1", SyncHash: hash}
		got, err := f.st.LinkContact(ctx, p1, c[0].ID, link)
		if err != nil || got.GoogleAccount != "first.last@example.com" || got.GoogleResource != "people/c1" || !got.UpdatedAt.Equal(c[0].UpdatedAt) {
			t.Errorf("C23g link: %+v (%v), want the account lowercased, the resource set, updated_at kept", got, err)
		}
		last := t0.Add(2 * time.Second)
		if ids := changed(p1, &last); len(ids) != 0 {
			t.Errorf("C23g a link is no change to send: %v, want none", ids)
		}
		if rows, _ := f.st.ContactsChangedSince(ctx, p1, nil); len(rows) == 0 || rows[0].GoogleETag != "etag-1" || rows[0].SyncHash != hash {
			t.Errorf("C23g the outbound read carries the link: %+v", rows)
		}
		if _, err := f.st.LinkContact(ctx, p1, c[1].ID, link); !errors.Is(err, ErrConflict) {
			t.Errorf("C23g the same link on a second contact: %v, want ErrConflict", err)
		}
		if _, err := f.st.LinkContact(ctx, p1, c[1].ID, ContactLink{Account: "first.last@example.com"}); !errors.Is(err, ErrRealmBad) {
			t.Errorf("C23g an account with no resource: %v, want ErrRealmBad", err)
		}
		if _, err := f.st.LinkContact(ctx, p2, c[0].ID, link); !errors.Is(err, ErrNotFound) {
			t.Errorf("C23g P2 links P1's contact: %v, want ErrNotFound", err)
		}

		// A member's delete is sent; Google's own delete is not sent back.
		if err := f.st.DeleteContact(ctx, p1, c[0].ID, ContactDeletedByMember, t0.Add(5*time.Second)); err != nil {
			t.Fatal(err)
		}
		if err := f.st.DeleteContact(ctx, p1, c[1].ID, ContactDeletedByGoogle, t0.Add(6*time.Second)); err != nil {
			t.Fatal(err)
		}
		rows, err := f.st.ContactsChangedSince(ctx, p1, &last)
		if err != nil || len(rows) != 1 || rows[0].ID != c[0].ID || rows[0].DeletedAt == nil || !rows[0].ChangedAt.Equal(t0.Add(5*time.Second)) {
			t.Errorf("C23g pending Google delete: %+v (%v), want only %s, deleted, changed at its delete", rows, err, c[0].ID)
		}

		if err := f.st.DropDeletedContact(ctx, p1, c[2].ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("C23g hard delete of a live contact: %v, want ErrNotFound", err)
		}
		if err := f.st.DropDeletedContact(ctx, p2, c[0].ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("C23g P2 hard-deletes P1's contact: %v, want ErrNotFound", err)
		}
		if f.pg != nil {
			c23gScopes(t, f.st.(*Postgres), p1, 3)
		}
		if err := f.st.DropDeletedContact(ctx, p1, c[0].ID); err != nil {
			t.Errorf("C23g hard delete once Google confirmed: %v", err)
		}
		if err := f.st.DropDeletedContact(ctx, p1, c[0].ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("C23g the row is gone: %v, want ErrNotFound", err)
		}
		if n, err := f.st.EraseContacts(ctx, p1); err != nil || n != 2 {
			t.Errorf("C23g P1's rows left: %d (%v), want 2", n, err)
		}
	})
}

// c23gScopes is C23g's control and twin on Postgres: the operator scope
// the claim runs in reads 0 of person's contacts; inPerson reads want.
func c23gScopes(t *testing.T, rt *Postgres, person string, want int) {
	t.Helper()
	ctx := context.Background()
	const q = `SELECT count(*) FROM personal.contacts WHERE person_id = $1`
	var asOp, asPerson int
	if err := rt.asOperator(ctx, func(tx pgx.Tx) error { return tx.QueryRow(ctx, q, person).Scan(&asOp) }); err != nil || asOp != 0 {
		t.Errorf("C23g control: the operator scope reads %d contact(s) (%v), want 0", asOp, err)
	}
	if err := rt.inPerson(ctx, person, func(tx pgx.Tx) error { return tx.QueryRow(ctx, q, person).Scan(&asPerson) }); err != nil || asPerson != want {
		t.Errorf("C23g twin: inPerson reads %d contact(s) (%v), want %d", asPerson, err, want)
	}
}

// TestContactsMainAttributes is spec 11.3: the four text values are stored,
// read back everywhere and patched ("" clears, nil keeps); each cap and the
// birthday rule are refused before the CHECK; a company alone is not a contact.
func TestContactsMainAttributes(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		c := ffContact()
		c.Company, c.JobTitle, c.Birthday, c.Notes = " Example Org ", "Engineer", "1990-01-31", "first line\nsecond line"
		c.InOnly = true
		got, err := f.st.CreateContact(ctx, p1, c, now)
		if err != nil {
			t.Fatal(err)
		}
		if got.Company != "Example Org" || got.JobTitle != "Engineer" || got.Birthday != "1990-01-31" ||
			got.Notes != "first line\nsecond line" || got.InOnly || got.PhotoSHA256 != "" {
			t.Errorf("the created values: %+v", got)
		}
		read, err := f.st.ContactOf(ctx, p1, got.ID)
		if err != nil || read != got {
			t.Errorf("ContactOf: %+v (%v), want %+v", read, err, got)
		}
		if l := listAll(t, f.st, p1, ""); len(l) != 1 || l[0] != got {
			t.Errorf("ListContacts: %+v, want the one created", l)
		}
		exp, err := f.st.ExportContacts(ctx, p1)
		if err != nil || len(exp) != 1 || exp[0] != got {
			t.Errorf("ExportContacts: %+v (%v), want the one created", exp, err)
		}
		empty, title, noYear := "", "Manager", "--02-29"
		patched, err := f.st.PatchContact(ctx, p1, got.ID, ContactPatch{JobTitle: &title, Birthday: &noYear, Notes: &empty}, now)
		if err != nil || patched.JobTitle != "Manager" || patched.Birthday != "--02-29" || patched.Notes != "" ||
			patched.Company != "Example Org" {
			t.Errorf("a patch: %+v (%v)", patched, err)
		}
		cleared, err := f.st.PatchContact(ctx, p1, got.ID, ContactPatch{Birthday: &empty}, now)
		if err != nil || cleared.Birthday != "" {
			t.Errorf("clearing the birthday: %+v (%v)", cleared, err)
		}
		for name, tc := range map[string]struct {
			c    Contact
			want error
		}{
			"long company":  {Contact{LastName: "L", Company: strings.Repeat("é", ContactCompanyMax+1)}, ErrContactTooLong},
			"long title":    {Contact{LastName: "L", JobTitle: strings.Repeat("a", ContactJobTitleMax+1)}, ErrContactTooLong},
			"long notes":    {Contact{LastName: "L", Notes: strings.Repeat("a", ContactNotesMax+1)}, ErrContactTooLong},
			"long name":     {Contact{LastName: strings.Repeat("a", ContactNameMax+1)}, ErrContactTooLong},
			"month 13":      {Contact{LastName: "L", Birthday: "1990-13-01"}, ErrContactBadBirthday},
			"no year 02-30": {Contact{LastName: "L", Birthday: "--02-30"}, ErrContactBadBirthday},
			"three dashes":  {Contact{LastName: "L", Birthday: "---02-01"}, ErrContactBadBirthday},
			"free text":     {Contact{LastName: "L", Birthday: "in May"}, ErrContactBadBirthday},
			"company alone": {Contact{Company: "Example Org"}, ErrContactEmpty},
		} {
			if _, err := f.st.CreateContact(ctx, p1, tc.c, now); !errors.Is(err, tc.want) || !errors.Is(err, ErrRealmBad) {
				t.Errorf("%s: %v, want %v (an ErrRealmBad)", name, err, tc.want)
			}
		}
		for name, c := range map[string]Contact{
			"caps": {LastName: "L", Company: strings.Repeat("é", ContactCompanyMax),
				JobTitle: strings.Repeat("a", ContactJobTitleMax), Notes: strings.Repeat("a", ContactNotesMax)},
			"a leap day": {LastName: "L", Birthday: "2000-02-29"},
		} {
			if _, err := f.st.CreateContact(ctx, p1, c, now); err != nil {
				t.Errorf("twin, %s: %v", name, err)
			}
		}
	})
}

// wantImport compares the counts of an import or a preview.
func wantImport(t *testing.T, name string, got ContactImportCounts, err error, want ContactImportCounts) {
	t.Helper()
	if err != nil || got != want {
		t.Errorf("%s: %+v (%v), want %+v", name, got, err, want)
	}
}

// TestContactsC32ImportMatch is C32: of 3 rows, 1 matches a live contact by
// email and 1 by name (no email), so 1 is added and nothing overwritten; the
// preview answers the same and writes nothing. Twin: an empty list adds 3.
func TestContactsC32ImportMatch(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, p2, c := contactsPair(t, f, now)
		if _, err := f.st.CreateContact(ctx, p1, Contact{FirstName: "Only", LastName: "Name"}, now); err != nil {
			t.Fatal(err)
		}
		rows := []Contact{
			{FirstName: "Other", LastName: "Words", Email: " FIRST.LAST@example.com", Company: "Example Org"},
			{FirstName: "Only", LastName: "Name", Phone: "+1 555 010 0009"},
			{FirstName: "New", LastName: "Row", Email: "new.row@example.com", Company: "Example Org", Birthday: "--03-04", Notes: "n"},
		}
		want := ContactImportCounts{Add: 1, AlreadyThere: 2}
		got, err := f.st.PreviewContactsImport(ctx, p1, rows)
		wantImport(t, "the preview", got, err, want)
		if l := listAll(t, f.st, p1, ""); len(l) != 2 {
			t.Fatalf("the preview wrote: %d contacts, want 2", len(l))
		}
		got, err = f.st.ImportContacts(ctx, p1, rows, now)
		wantImport(t, "C32", got, err, want)
		l := listAll(t, f.st, p1, "")
		if len(l) != 3 {
			t.Fatalf("C32 the list: %d contacts, want 3", len(l))
		}
		for _, x := range l {
			if x.ID == c.ID && (x.FirstName != "FirstName" || x.Company != "") {
				t.Errorf("C32 a match was overwritten: %+v", x)
			}
			if x.Email == "new.row@example.com" && (x.Company != "Example Org" || x.Birthday != "--03-04" || x.Notes != "n") {
				t.Errorf("C32 the added row: %+v", x)
			}
		}
		got, err = f.st.ImportContacts(ctx, p1, rows, now)
		wantImport(t, "the same rows again", got, err, ContactImportCounts{AlreadyThere: 3})
		got, err = f.st.ImportContacts(ctx, p2, rows, now)
		wantImport(t, "C32 twin, an empty list", got, err, ContactImportCounts{Add: 3})
		got, err = f.st.ImportContacts(ctx, p2, nil, now)
		wantImport(t, "no rows", got, err, ContactImportCounts{})
		dup := []Contact{{Email: "twice@example.com"}, {Email: "TWICE@example.com"}, {LastName: "Twice"}, {LastName: "Twice"}}
		got, err = f.st.ImportContacts(ctx, p2, dup, now)
		wantImport(t, "duplicates inside the file", got, err, ContactImportCounts{Add: 2, FileDuplicates: 2})
		if _, err := f.st.ImportContacts(ctx, "HUM-7000000002", rows, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("no such human: %v, want ErrNotFound", err)
		}
	})
}

// TestContactsC32bPhoneOnlyRows is C32b: rows with no email and no name match
// on the phone's digits. Twin: two different phones both add; on the name
// rule alone the second would read as already there.
func TestContactsC32bPhoneOnlyRows(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, _, _ := contactsPair(t, f, now) // holds +1 555 010 0000, with a name and an email
		got, err := f.st.ImportContacts(ctx, p1, []Contact{{Phone: "+1 555 010 0001"}, {Phone: "+1 555 010 0002"}}, now)
		wantImport(t, "C32b twin, two different phones", got, err, ContactImportCounts{Add: 2})
		got, err = f.st.ImportContacts(ctx, p1, []Contact{{Phone: "15550100001"}}, now)
		wantImport(t, "C32b one number written two ways", got, err, ContactImportCounts{AlreadyThere: 1})
		got, err = f.st.ImportContacts(ctx, p1, []Contact{{Phone: "(1) 555-010-0000"}}, now)
		wantImport(t, "C32b the phone of a named contact", got, err, ContactImportCounts{AlreadyThere: 1})
		got, err = f.st.ImportContacts(ctx, p1, []Contact{{Phone: "+1 555 010 0003"}, {Phone: "1 555 010 0003"}}, now)
		wantImport(t, "C32b a file duplicate", got, err, ContactImportCounts{Add: 1, FileDuplicates: 1})
		got, err = f.st.ImportContacts(ctx, p1, []Contact{{LastName: "Named", Phone: "+1 555 010 0001"}}, now)
		wantImport(t, "a named row keeps the seed's rule", got, err, ContactImportCounts{Add: 1})
		gone := listAll(t, f.st, p1, "5550100002")
		if len(gone) != 1 {
			t.Fatalf("the phone search: %d, want 1", len(gone))
		}
		if err := f.st.DeleteContact(ctx, p1, gone[0].ID, ContactDeletedByMember, now); err != nil {
			t.Fatal(err)
		}
		got, err = f.st.ImportContacts(ctx, p1, []Contact{{Phone: "15550100002"}}, now)
		wantImport(t, "C32b a soft-deleted one", got, err, ContactImportCounts{DeletedHere: 1})
	})
}

// TestContactsC33ImportAllOrNone is C33: a third row that is bad adds nothing,
// through the public call on both stores and, on Postgres, past the cleaning
// so that a real CHECK fires inside the transaction. Twin: without it, 3.
func TestContactsC33ImportAllOrNone(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		good := []Contact{{Email: "one@example.com"}, {Email: "two@example.com"}}
		bad := append(append([]Contact{}, good...), Contact{Phone: "call me"})
		if _, err := f.st.ImportContacts(ctx, p1, bad, now); !errors.Is(err, ErrContactBadPhone) {
			t.Errorf("C33 the public call: %v, want ErrContactBadPhone", err)
		}
		if _, err := f.st.PreviewContactsImport(ctx, p1, bad); !errors.Is(err, ErrContactBadPhone) {
			t.Errorf("C33 the preview: %v, want ErrContactBadPhone", err)
		}
		if rt, ok := f.st.(*Postgres); ok {
			err := rt.inPerson(ctx, p1, func(tx pgx.Tx) error {
				_, err := importContactsTx(ctx, tx, p1, bad, now)
				return err
			})
			if got := sqlState(err); got != "23514" {
				t.Errorf("C33 past the cleaning: %v (state %q), want the CHECK's 23514", err, got)
			}
		}
		if l := listAll(t, f.st, p1, ""); len(l) != 0 {
			t.Errorf("C33 rows after the refusal: %d, want 0", len(l))
		}
		got, err := f.st.ImportContacts(ctx, p1, append(good, Contact{Email: "three@example.com"}), now)
		wantImport(t, "C33 twin", got, err, ContactImportCounts{Add: 3})
	})
}

// TestContactsC33bImportRace is C33b: two imports of the same new rows at once
// add each row once. The red control is the commit's: without the advisory
// lock this test adds the rows twice.
func TestContactsC33bImportRace(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		const rounds, perRound = 10, 30
		for round := 0; round < rounds; round++ {
			rows := make([]Contact, perRound)
			for i := range rows {
				rows[i] = Contact{Email: fmt.Sprintf("r%d.n%d@example.com", round, i)}
			}
			var wg sync.WaitGroup
			start := make(chan struct{})
			counts := make([]ContactImportCounts, 2)
			errs := make([]error, 2)
			for w := range counts {
				wg.Add(1)
				go func() {
					defer wg.Done()
					<-start
					counts[w], errs[w] = f.st.ImportContacts(ctx, p1, rows, now)
				}()
			}
			close(start)
			wg.Wait()
			if errs[0] != nil || errs[1] != nil {
				t.Fatalf("round %d: %v, %v", round, errs[0], errs[1])
			}
			if added := counts[0].Add + counts[1].Add; added != perRound {
				t.Errorf("C33b round %d: %d added in all, want %d", round, added, perRound)
			}
		}
		exp, err := f.st.ExportContacts(ctx, p1)
		if err != nil || len(exp) != rounds*perRound {
			t.Errorf("C33b the list: %d contacts (%v), want %d", len(exp), err, rounds*perRound)
		}
	})
}

// TestContactsC37bImportSoftDeleted is C37b, the store's half: a row matching
// a soft-deleted contact, by either deleter, is deleted_here and adds nothing;
// a live match wins. Twin: after the purge the row adds.
func TestContactsC37bImportSoftDeleted(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		old := now.Add(-40 * 24 * time.Hour)
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		for _, by := range []string{ContactDeletedByMember, ContactDeletedByGoogle} {
			row := Contact{Email: by + "@example.com"}
			c, err := f.st.CreateContact(ctx, p1, row, now)
			if err != nil {
				t.Fatal(err)
			}
			if err := f.st.DeleteContact(ctx, p1, c.ID, by, old); err != nil {
				t.Fatal(err)
			}
			got, err := f.st.ImportContacts(ctx, p1, []Contact{row}, now)
			wantImport(t, "C37b deleted by "+by, got, err, ContactImportCounts{DeletedHere: 1})
		}
		if l := listAll(t, f.st, p1, ""); len(l) != 0 {
			t.Errorf("C37b an import resurrected: %d live, want 0", len(l))
		}
		both := Contact{LastName: "Both"}
		first, err := f.st.CreateContact(ctx, p1, both, now)
		if err != nil {
			t.Fatal(err)
		}
		if err := f.st.DeleteContact(ctx, p1, first.ID, ContactDeletedByMember, now); err != nil {
			t.Fatal(err)
		}
		if _, err := f.st.CreateContact(ctx, p1, both, now); err != nil {
			t.Fatal(err)
		}
		got, err := f.st.ImportContacts(ctx, p1, []Contact{both}, now)
		wantImport(t, "a live match beside a soft-deleted one", got, err, ContactImportCounts{AlreadyThere: 1})
		if _, err := f.st.PurgeDeletedContacts(ctx, now.Add(-39*24*time.Hour)); err != nil {
			t.Fatal(err)
		}
		got, err = f.st.ImportContacts(ctx, p1, []Contact{{Email: ContactDeletedByMember + "@example.com"}}, now)
		wantImport(t, "C37b twin, after the purge", got, err, ContactImportCounts{Add: 1})
	})
}

// testContactPhoto is a picture whose source URL hash is 64 times hexChar.
func testContactPhoto(hexChar string) ContactPhoto {
	return ContactPhoto{Mime: "image/png", Bytes: []byte("\x89PNG" + hexChar), SourceURLHash: strings.Repeat(hexChar, 64)}
}

// wantPhotos is CountContactPhotos of person.
func wantPhotos(t *testing.T, st PersonalContacts, name, person string, want int) {
	t.Helper()
	if n, err := st.CountContactPhotos(context.Background(), person); err != nil || n != want {
		t.Errorf("%s: %d picture(s) of %s (%v), want %d", name, n, person, err, want)
	}
}

// TestContactsC31PhotoOtherPerson is C31: P2 reads, writes or deletes P1's
// picture through the store: not found, nothing changed, and not the primary
// key's duplicate that a plain INSERT answers (B13's reviewer, N5). Twin: P1
// does each.
func TestContactsC31PhotoOtherPerson(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, p2, c := contactsPair(t, f, now)
		if _, err := f.st.ContactPhoto(ctx, p1, c.ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("no picture yet: %v, want ErrNotFound", err)
		}
		if err := f.st.DeleteContactPhoto(ctx, p1, c.ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("deleting no picture: %v, want ErrNotFound", err)
		}
		in := testContactPhoto("a")
		put, err := f.st.PutContactPhoto(ctx, p1, c.ID, in, now)
		sum := sha256.Sum256(in.Bytes)
		if err != nil || put.SHA256 != hex.EncodeToString(sum[:]) || !bytes.Equal(put.Bytes, in.Bytes) || put.FetchedAt.IsZero() {
			t.Fatalf("C31 twin, P1 writes: %+v (%v)", put, err)
		}
		if _, err := f.st.PutContactPhoto(ctx, p2, c.ID, testContactPhoto("b"), now); !errors.Is(err, ErrNotFound) {
			t.Errorf("C31 P2 writes: %v, want ErrNotFound", err)
		}
		if _, err := f.st.ContactPhoto(ctx, p2, c.ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("C31 P2 reads: %v, want ErrNotFound", err)
		}
		if err := f.st.DeleteContactPhoto(ctx, p2, c.ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("C31 P2 deletes: %v, want ErrNotFound", err)
		}
		wantPhotos(t, f.st, "C31 P2 after its tries", p2, 0)
		got, err := f.st.ContactPhoto(ctx, p1, c.ID)
		if err != nil || got.SHA256 != put.SHA256 || got.SourceURLHash != in.SourceURLHash || got.Mime != in.Mime ||
			!bytes.Equal(got.Bytes, in.Bytes) {
			t.Errorf("C31 twin, P1 reads what it wrote: %+v (%v)", got, err)
		}
		read, err := f.st.ContactOf(ctx, p1, c.ID)
		if err != nil || read.PhotoSHA256 != put.SHA256 || !read.UpdatedAt.Equal(c.UpdatedAt) {
			t.Errorf("the contact after a picture: %+v (%v), want its hash and the same updated_at", read, err)
		}
		if l := listAll(t, f.st, p1, ""); len(l) != 1 || l[0].PhotoSHA256 != put.SHA256 {
			t.Errorf("the list after a picture: %+v", l)
		}
		next, err := f.st.PutContactPhoto(ctx, p1, c.ID, testContactPhoto("b"), now)
		if err != nil || next.SHA256 == put.SHA256 {
			t.Errorf("a new picture: %+v (%v), want a new hash", next, err)
		}
		wantPhotos(t, f.st, "a replaced picture is one", p1, 1)
		if err := f.st.DeleteContactPhoto(ctx, p1, c.ID); err != nil {
			t.Errorf("C31 twin, P1 deletes: %v", err)
		}
		wantPhotos(t, f.st, "C31 twin, after P1's delete", p1, 0)
		if read, err := f.st.ContactOf(ctx, p1, c.ID); err != nil || read.PhotoSHA256 != "" {
			t.Errorf("the contact after the delete: %+v (%v), want no hash", read, err)
		}
	})
}

// TestContactsPhotoValues is rdb 0265's picture CHECKs before any SQL, and a
// soft-deleted contact's picture gone from reads though its row still counts.
func TestContactsPhotoValues(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, _, c := contactsPair(t, f, now)
		ok := testContactPhoto("a")
		for name, mutate := range map[string]func(p *ContactPhoto){
			"a gif":          func(p *ContactPhoto) { p.Mime = "image/gif" },
			"no bytes":       func(p *ContactPhoto) { p.Bytes = nil },
			"one byte over":  func(p *ContactPhoto) { p.Bytes = make([]byte, ContactPhotoMax+1) },
			"a bad URL hash": func(p *ContactPhoto) { p.SourceURLHash = "abc" },
		} {
			p := ok
			mutate(&p)
			if _, err := f.st.PutContactPhoto(ctx, p1, c.ID, p, now); !errors.Is(err, ErrContactPhotoBad) || !errors.Is(err, ErrRealmBad) {
				t.Errorf("%s: %v, want ErrContactPhotoBad", name, err)
			}
		}
		wantPhotos(t, f.st, "after the refusals", p1, 0)
		atCap := ok
		atCap.Bytes = make([]byte, ContactPhotoMax)
		if _, err := f.st.PutContactPhoto(ctx, p1, c.ID, atCap, now); err != nil {
			t.Errorf("twin, at the cap: %v", err)
		}
		if err := f.st.DeleteContact(ctx, p1, c.ID, ContactDeletedByMember, now); err != nil {
			t.Fatal(err)
		}
		if _, err := f.st.ContactPhoto(ctx, p1, c.ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("a soft-deleted contact's picture reads %v, want ErrNotFound", err)
		}
		if _, err := f.st.PutContactPhoto(ctx, p1, c.ID, ok, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("a picture on a soft-deleted contact: %v, want ErrNotFound", err)
		}
		wantPhotos(t, f.st, "a soft-deleted contact's picture still counts", p1, 1)
	})
}

// TestContactsC39PhotosGoWithTheList is C39: erase all, on both stores, leaves
// 0 pictures of that person; twin: P2's stay. A human delete is Postgres only:
// Memory's human paths hold no contact, and the FK's cascade is the thing tested.
func TestContactsC39PhotosGoWithTheList(t *testing.T) {
	eachContactsDriver(t, func(t *testing.T, f contactsFix) {
		ctx := context.Background()
		now := time.Now()
		p1, p2, c := contactsPair(t, f, now)
		c2, err := f.st.CreateContact(ctx, p2, ffContact(), now)
		if err != nil {
			t.Fatal(err)
		}
		soft, err := f.st.CreateContact(ctx, p1, Contact{LastName: "Soft"}, now)
		if err != nil {
			t.Fatal(err)
		}
		for _, x := range []struct{ person, id string }{{p1, c.ID}, {p1, soft.ID}, {p2, c2.ID}} {
			if _, err := f.st.PutContactPhoto(ctx, x.person, x.id, testContactPhoto("a"), now); err != nil {
				t.Fatal(err)
			}
		}
		if err := f.st.DeleteContact(ctx, p1, soft.ID, ContactDeletedByMember, now); err != nil {
			t.Fatal(err)
		}
		wantPhotos(t, f.st, "before the erase", p1, 2)
		if _, err := f.st.EraseContacts(ctx, p1); err != nil {
			t.Fatal(err)
		}
		wantPhotos(t, f.st, "C39 after P1's erase", p1, 0)
		wantPhotos(t, f.st, "C39 twin, P2's after P1's erase", p2, 1)
		if f.pg == nil {
			return
		}
		p3, _ := realmPersons()
		f.addHuman(t, p3)
		c3, err := f.st.CreateContact(ctx, p3, ffContact(), now)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.st.PutContactPhoto(ctx, p3, c3.ID, testContactPhoto("a"), now); err != nil {
			t.Fatal(err)
		}
		wantPhotos(t, f.st, "before the human delete", p3, 1)
		if _, err := f.pg.pool.Exec(ctx, `DELETE FROM humans WHERE human_id = $1`, p3); err != nil {
			t.Fatal(err)
		}
		wantPhotos(t, f.st, "C39 after the human delete", p3, 0)
		wantPhotos(t, f.st, "C39 twin, P2's after the human delete", p2, 1)
	})
}
