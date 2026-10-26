package store

import (
	"context"
	"errors"
	"strings"
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

// contactsStore is both halves of spec 154 B2's store.
type contactsStore interface {
	PersonalContacts
	ContactsSyncs
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
			g.conns[id] = &GcalConnection{ID: id, Tenant: tenant, Human: human, GoogleEmail: "first.last@example.com"}
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
			for i, err := range []error{e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12} {
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
