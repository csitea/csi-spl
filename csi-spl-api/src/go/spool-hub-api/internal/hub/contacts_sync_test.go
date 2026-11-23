package hub_test

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal/fakegcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 154 B8 (amended; SPL-6253): the Google Contacts sync cycle against
// fakegcal's People API and a fake KMS; no test reaches Google. Cases C12,
// C15-C23f and C41-C43 of spec 154 sections 5 and 11.7. Memory, and
// Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full). The clock starts at
// gcalSyncT0, so a claim never takes a binding another test left due at the
// wall clock in a shared Postgres. Fixtures are FirstName LastName and
// example.com.

// contactsWriteCalls are the fake People calls that write.
var contactsWriteCalls = []string{"people.createContact", "people.updateContact", "people.deleteContact"}

type csEnv struct {
	*gcalSyncEnv
	hum string
}

// contactsSyncEnvOf is one workspace on both switches, a member connected
// with the contacts scope only and the Contacts switch on.
func contactsSyncEnvOf(t *testing.T) *csEnv {
	t.Helper()
	ids := mktIDs(1)
	tid := ids[0]
	clock := &gcalClock{t: gcalSyncT0}
	f := fakegcal.New(t)
	f.Now = clock.now
	cfg := f.Config(gcalApp+hub.GcalCallbackPath, gcalTestScopes)
	hook := &gcalHookRT{base: cfg.HTTP.Transport}
	cfg.HTTP = &http.Client{Transport: hook}
	google, err := gcal.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k",
		marketing.WithPurpose(hub.GcalPurpose))
	if err != nil {
		t.Fatal(err)
	}
	gc := &hub.GcalConnect{Google: google, Sealer: sealer, Workspaces: ids, CookieName: gcalCookie,
		WorkspaceURL: hub.GcalWorkspaceURL("{tenant}."+gcalApexDom, tid, gcalApp), ContactsScopes: gcalContactsTestScope}
	buf := &syncBuf{}
	e := mktEnvWith(t, nil, func(o *hub.Options) {
		o.Gcal = gc
		o.Log = zerolog.New(buf)
		o.Now = clock.now
		o.ContactsWorkspaces = ids
	}, ids...)
	te := &gcalTestEnv{env: e, fake: f, gc: gc, clock: clock, log: buf, apex: tid}
	ce := &csEnv{gcalSyncEnv: &gcalSyncEnv{gcalTestEnv: te, tid: tid, hook: hook}}
	ce.hum = ce.bound(t)
	return ce
}

// bound seats a developer, connects contacts only and turns the switch on.
func (ce *csEnv) bound(t *testing.T) string {
	t.Helper()
	hum := seat(t, ce.env, ce.tid, rbac.Developer)
	t.Cleanup(func() {
		ce.st.(store.Gcal).DeleteGcalConnection(context.Background(), ce.tid, hum) //nolint:errcheck // gone is fine
	})
	if loc := gcalConnectContactsOnly(t, ce.gcalTestEnv, ce.tid, hum); !strings.HasSuffix(loc, "gcal=connected") {
		t.Fatalf("contacts connect landed on %s", loc)
	}
	if _, err := ce.st.(store.ContactsSyncs).SetContactsSync(context.Background(), ce.tid, hum, true, ce.clock.now()); err != nil {
		t.Fatal(err)
	}
	return hum
}

func (ce *csEnv) pc() store.PersonalContacts { return ce.st.(store.PersonalContacts) }

// sync runs one ContactsSyncOnce, which must claim, then moves the clock
// past the 10 minute cycle.
func (ce *csEnv) sync(t *testing.T) {
	t.Helper()
	claimed, err := ce.srv.ContactsSyncOnce(context.Background())
	if err != nil {
		t.Fatalf("contacts cycle: %v", err)
	}
	if !claimed {
		t.Fatal("contacts cycle claimed nothing")
	}
	ce.clock.add(11 * time.Minute)
}

func (ce *csEnv) writes() int { return ce.calls(contactsWriteCalls...) }

// list is the member's live contacts.
func (ce *csEnv) list(t *testing.T) []store.Contact {
	t.Helper()
	cs, err := ce.pc().ExportContacts(context.Background(), ce.hum)
	if err != nil {
		t.Fatal(err)
	}
	return cs
}

// one is the member's only contact.
func (ce *csEnv) one(t *testing.T) store.Contact {
	t.Helper()
	cs := ce.list(t)
	if len(cs) != 1 {
		t.Fatalf("%d contacts, want 1: %+v", len(cs), cs)
	}
	return cs[0]
}

func (ce *csEnv) add(t *testing.T, c store.Contact) store.Contact {
	t.Helper()
	out, err := ce.pc().CreateContact(context.Background(), ce.hum, c, ce.clock.now())
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func (ce *csEnv) patch(t *testing.T, id string, p store.ContactPatch) {
	t.Helper()
	if _, err := ce.pc().PatchContact(context.Background(), ce.hum, id, p, ce.clock.now()); err != nil {
		t.Fatal(err)
	}
}

func strp(s string) *string { return &s }

// gperson is the fixture as a Google person, with a second phone.
func gperson() gcal.Person {
	return gcal.Person{
		Names:          []gcal.Name{{GivenName: "FirstName", FamilyName: "LastName"}},
		EmailAddresses: []gcal.EmailAddress{{Value: "First.Last@Example.com"}},
		PhoneNumbers:   []gcal.PhoneNumber{{Value: "+1 555 010 0000", Metadata: gcal.FieldMetadata{Primary: true}}, {Value: "+1 555 010 0099"}},
	}
}

// C15, C15b, C41, C16: a new person comes in with the four values, the
// link and the attributes of 11.3 (the primary of two emails, a birthday
// without a year, a plain text biography); the next cycle writes nothing.
func TestContactsSyncInNewPerson(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	p := gperson()
	p.EmailAddresses = []gcal.EmailAddress{{Value: "other@example.com"}, {Value: "First.Last@Example.com", Metadata: gcal.FieldMetadata{Primary: true}}}
	p.Organizations = []gcal.Organization{{Name: "Example Org", Title: "Engineer"}}
	p.Birthdays = []gcal.Birthday{{Date: &gcal.Date{Month: 5, Day: 17}}}
	p.Biographies = []gcal.Biography{{Value: "met at the fair", ContentType: "TEXT_PLAIN"}}
	g := ce.fake.AddPerson(fakegcal.DefaultEmail, p)
	ce.sync(t)
	c := ce.one(t)
	if c.FirstName != "FirstName" || c.LastName != "LastName" || c.Phone != "+1 555 010 0000" ||
		c.GoogleAccount != fakegcal.DefaultEmail || c.GoogleResource != g.ResourceName {
		t.Errorf("C15: %+v, want the four values linked under %s %s", c, fakegcal.DefaultEmail, g.ResourceName)
	}
	if c.Email != "first.last@example.com" {
		t.Errorf("C15b: email %q, want the primary one, lowercased", c.Email)
	}
	if c.Company != "Example Org" || c.JobTitle != "Engineer" || c.Birthday != "--05-17" || c.Notes != "met at the fair" || c.InOnly {
		t.Errorf("C41: %+v, want company, job title, --05-17, notes, not in_only", c)
	}
	if n := ce.writes(); n != 0 {
		t.Errorf("C15: %d Google writes for a person that came in, want 0", n)
	}
	ce.fake.ResetCalls()
	ce.sync(t)
	if n := ce.writes(); n != 0 {
		t.Errorf("C16 echo: %d Google writes, want 0", n)
	}
	if again := ce.one(t); !again.UpdatedAt.Equal(c.UpdatedAt) {
		t.Errorf("C16 echo: updated_at moved %v -> %v", c.UpdatedAt, again.UpdatedAt)
	}
}

// C41 twin: a birthday with only Google's free-form text stores no
// birthday, and a later Spool edit sends no birthdays, so the text stays.
// C43: a Spool edit of the job title changes the primary organization only.
func TestContactsSyncBirthdayTextAndOrganizations(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	p := gperson()
	p.Birthdays = []gcal.Birthday{{Text: "spring"}}
	p.Organizations = []gcal.Organization{{Name: "Second Org", Title: "Advisor"},
		{Name: "Example Org", Title: "Engineer", Metadata: gcal.FieldMetadata{Primary: true}}}
	g := ce.fake.AddPerson(fakegcal.DefaultEmail, p)
	ce.sync(t)
	c := ce.one(t)
	if c.Birthday != "" || c.Company != "Example Org" {
		t.Fatalf("C41 twin: %+v, want no birthday and the primary organization", c)
	}
	ce.patch(t, c.ID, store.ContactPatch{JobTitle: strp("Lead")})
	ce.fake.ResetCalls()
	ce.sync(t)
	got, _ := ce.fake.Person(fakegcal.DefaultEmail, g.ResourceName)
	if ce.fake.Calls("people.updateContact") != 1 {
		t.Fatalf("one Spool edit sent %d updates, want 1", ce.fake.Calls("people.updateContact"))
	}
	if len(got.Birthdays) != 1 || got.Birthdays[0].Text != "spring" {
		t.Errorf("C41 twin: Google's birthday %+v, want its text kept", got.Birthdays)
	}
	if len(got.Organizations) != 2 || got.Organizations[1].Title != "Lead" || got.Organizations[0].Title != "Advisor" {
		t.Errorf("C43: organizations %+v, want the primary's title Lead and the second kept", got.Organizations)
	}
}

// C17: a Spool edit is one update with the stored etag; the second phone
// Google keeps stays. C17b: a Spool delete is one delete at Google, then the
// row is gone.
func TestContactsSyncOutEditDelete(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	g := ce.fake.AddPerson(fakegcal.DefaultEmail, gperson())
	ce.sync(t)
	c := ce.one(t)
	ce.patch(t, c.ID, store.ContactPatch{Phone: strp("+1 555 010 0001")})
	ce.fake.ResetCalls()
	ce.sync(t)
	got, _ := ce.fake.Person(fakegcal.DefaultEmail, g.ResourceName)
	if ce.fake.Calls("people.updateContact") != 1 || len(got.PhoneNumbers) != 2 ||
		got.PhoneNumbers[0].Value != "+1 555 010 0001" || got.PhoneNumbers[1].Value != "+1 555 010 0099" {
		t.Errorf("C17: %d updates, phones %+v; want 1 and the primary changed, the second kept", ce.fake.Calls("people.updateContact"), got.PhoneNumbers)
	}
	ce.fake.ResetCalls()
	ce.sync(t)
	if n := ce.writes(); n != 0 {
		t.Errorf("C17: the cycle after the update wrote %d, want 0 (echo)", n)
	}
	if err := ce.pc().DeleteContact(context.Background(), ce.hum, c.ID, store.ContactDeletedByMember, ce.clock.now()); err != nil {
		t.Fatal(err)
	}
	ce.fake.ResetCalls()
	ce.sync(t)
	if _, ok := ce.fake.Person(fakegcal.DefaultEmail, g.ResourceName); ok || ce.fake.Calls("people.deleteContact") != 1 {
		t.Errorf("C17b: %d deletes, person still at google %t; want 1 and gone", ce.fake.Calls("people.deleteContact"), ok)
	}
	rows, err := ce.st.(store.ContactsCycle).ContactsChangedSince(context.Background(), ce.hum, nil, "")
	if err != nil || len(rows) != 0 {
		t.Errorf("C17b: %d rows left (%v), want the row hard-deleted", len(rows), err)
	}
}

// C18: both sides edited, Google later: Google's values, no update sent.
// Twin: Spool later: one update with Spool's values.
func TestContactsSyncConflict(t *testing.T) {
	for _, spoolLater := range []bool{false, true} {
		t.Run(fmt.Sprintf("spool_later=%t", spoolLater), func(t *testing.T) {
			ce := contactsSyncEnvOf(t)
			g := ce.fake.AddPerson(fakegcal.DefaultEmail, gperson())
			ce.sync(t)
			c := ce.one(t)
			edits := []func(){
				func() { ce.patch(t, c.ID, store.ContactPatch{FirstName: strp("SpoolName")}) },
				func() {
					_ = ce.fake.EditPerson(fakegcal.DefaultEmail, g.ResourceName, func(p *gcal.Person) { p.Names[0].GivenName = "GoogleName" })
				},
			}
			if spoolLater {
				edits[0], edits[1] = edits[1], edits[0]
			}
			edits[0]()
			ce.clock.add(time.Second)
			edits[1]()
			ce.fake.ResetCalls()
			ce.sync(t)
			got := ce.one(t)
			gp, _ := ce.fake.Person(fakegcal.DefaultEmail, g.ResourceName)
			switch {
			case !spoolLater && (got.FirstName != "GoogleName" || ce.fake.Calls("people.updateContact") != 0):
				t.Errorf("C18 Google later: Spool %q, %d updates; want GoogleName and 0", got.FirstName, ce.fake.Calls("people.updateContact"))
			case spoolLater && (got.FirstName != "SpoolName" || ce.fake.Calls("people.updateContact") != 1 || gp.Names[0].GivenName != "SpoolName"):
				t.Errorf("C18 Spool later: Spool %q, Google %q, %d updates; want SpoolName on both, 1 update",
					got.FirstName, gp.Names[0].GivenName, ce.fake.Calls("people.updateContact"))
			}
		})
	}
}

// C19: an expired sync token: a full list, no duplicates, no deletes.
func TestContactsSyncExpiredToken(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	g := ce.fake.AddPerson(fakegcal.DefaultEmail, gperson())
	ce.sync(t)
	ce.add(t, store.Contact{FirstName: "Spool", LastName: "Only"})
	ce.sync(t) // created at Google
	ce.fake.ExpirePeopleSyncTokens(fakegcal.DefaultEmail)
	if err := ce.fake.RemovePerson(fakegcal.DefaultEmail, g.ResourceName); err != nil {
		t.Fatal(err)
	}
	ce.fake.ResetCalls()
	ce.sync(t)
	if n := len(ce.list(t)); n != 2 {
		t.Errorf("C19: %d contacts after the full list, want 2 (no duplicate, no delete)", n)
	}
	if ce.fake.Calls("people.connections.list") != 2 {
		t.Errorf("C19: %d lists, want 2 (the refused token, then the full list)", ce.fake.Calls("people.connections.list"))
	}
	b, _ := ce.st.(store.ContactsSyncs).ContactsSyncIn(context.Background(), ce.tid, ce.hum)
	if b.SyncToken == "" {
		t.Error("C19: no new sync token stored after the full list")
	}
}

// C20, C20b: the first sync links the older Spool contact with the Google
// person's email; the newer stays unlinked; no duplicate.
func TestContactsSyncFirstSyncLinks(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	older := ce.add(t, store.Contact{FirstName: "Older", Email: "first.last@example.com"})
	ce.clock.add(time.Second)
	newer := ce.add(t, store.Contact{FirstName: "Newer", Email: "first.last@example.com"})
	ce.clock.add(time.Second)
	g := ce.fake.AddPerson(fakegcal.DefaultEmail, gperson())
	ce.sync(t)
	byID := map[string]store.Contact{}
	for _, c := range ce.list(t) {
		byID[c.ID] = c
	}
	if len(byID) != 2 || byID[older.ID].GoogleResource != g.ResourceName {
		t.Errorf("C20/C20b: %+v, want 2 contacts, the older linked to %s", byID, g.ResourceName)
	}
	if byID[newer.ID].GoogleResource == g.ResourceName {
		t.Error("C20b: the newer contact got the link too")
	}
}

// C21: a 429: backoff_until set, the status line says so, no further call
// that cycle; the binding is not claimed again before it.
func TestContactsSyncRateLimited(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	ce.fake.FailPeople(http.StatusTooManyRequests, 1, 0)
	ce.fake.ResetCalls()
	claimed, err := ce.srv.ContactsSyncOnce(context.Background())
	if err != nil || !claimed {
		t.Fatalf("cycle: %t %v", claimed, err)
	}
	if n := ce.fake.Calls("people.connections.list") + ce.writes(); n != 1 {
		t.Errorf("C21: %d People calls, want 1 (none after the 429)", n)
	}
	b, err := ce.st.(store.ContactsSyncs).ContactsSyncIn(context.Background(), ce.tid, ce.hum)
	if err != nil || b.BackoffUntil == nil || !b.BackoffUntil.After(ce.clock.now()) || !strings.Contains(b.StatusDetail, "(try 1)") {
		t.Fatalf("C21: binding %+v (%v), want backoff_until ahead and a try 1 status line", b, err)
	}
	if claimed, _ := ce.srv.ContactsSyncOnce(context.Background()); claimed {
		t.Error("C21: claimed again inside the backoff")
	}
	ce.clock.add(2 * time.Minute)
	ce.sync(t)
	if b, _ := ce.st.(store.ContactsSyncs).ContactsSyncIn(context.Background(), ce.tid, ce.hum); b.BackoffUntil != nil || b.StatusDetail != "" {
		t.Errorf("C21: after a good cycle %+v, want the backoff and the line cleared", b)
	}
}

// C22: 300 Spool contacts to create: 200 this cycle, 100 the next.
func TestContactsSyncWriteCap(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	rows := make([]store.Contact, 300)
	for i := range rows {
		rows[i] = store.Contact{FirstName: "FirstName", LastName: fmt.Sprintf("LastName%03d", i)}
	}
	if _, err := ce.pc().ImportContacts(context.Background(), ce.hum, rows, ce.clock.now()); err != nil {
		t.Fatal(err)
	}
	ce.fake.ResetCalls()
	ce.sync(t)
	if n := ce.fake.Calls("people.createContact"); n != 200 {
		t.Fatalf("C22 first cycle: %d creates, want 200", n)
	}
	ce.fake.ResetCalls()
	ce.sync(t)
	if n := ce.fake.Calls("people.createContact"); n != 100 {
		t.Errorf("C22 second cycle: %d creates, want 100", n)
	}
	if n := len(ce.fake.People(fakegcal.DefaultEmail)); n != 300 {
		t.Errorf("C22: %d people at Google, want 300", n)
	}
}

// C23: two cycles at once sync each binding once. Then, one cycle at a
// time (two at once share the pool, so one's statement would overlap the
// other's Google call), no pool connection is held during any Google call
// on Postgres: no transaction is open during it.
func TestContactsSyncTwoCycles(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	ce.bound(t) // a second member's binding
	ce.fake.ResetCalls()
	var claims atomic.Int32
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				claimed, err := ce.srv.ContactsSyncOnce(context.Background())
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
		t.Fatalf("C23: %v", err)
	}
	if claims.Load() != 2 || ce.fake.Calls("people.connections.list") != 2 {
		t.Errorf("C23: %d claims, %d lists; want 2 and 2", claims.Load(), ce.fake.Calls("people.connections.list"))
	}

	pg, _ := ce.st.(*store.Postgres)
	var held, seen atomic.Int32
	ce.hook.set(func(*http.Request) {
		seen.Add(1)
		if pg != nil && pg.Pool().Stat().AcquiredConns() != 0 {
			held.Add(1)
		}
	})
	g := ce.fake.AddPerson(fakegcal.DefaultEmail, gperson())
	c := ce.add(t, store.Contact{FirstName: "Spool", LastName: "Only"})
	ce.clock.add(11 * time.Minute)
	ce.sync(t)
	ce.patch(t, c.ID, store.ContactPatch{LastName: strp("Edited")})
	_ = ce.fake.EditPerson(fakegcal.DefaultEmail, g.ResourceName, func(p *gcal.Person) { p.Names[0].GivenName = "Edited" })
	ce.fake.ExpireAccessTokens()
	ce.sync(t)
	if seen.Load() < 5 {
		t.Fatalf("CONTROL: the hook saw %d Google calls, want list, create, token, list, get, update", seen.Load())
	}
	if n := held.Load(); n != 0 {
		t.Errorf("C23: %d Google call(s) made holding a pool connection, want 0", n)
	}
}

// C23b: invalid_grant from Google revokes the connection and the binding
// is not synced again; a connected twin is synced.
func TestContactsSyncInvalidGrant(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	ce.fake.RevokeGrant(fakegcal.DefaultEmail)
	ce.fake.ExpireAccessTokens()
	ce.fake.ResetCalls()
	claimed, err := ce.srv.ContactsSyncOnce(context.Background())
	if err != nil || !claimed {
		t.Fatalf("cycle: %t %v", claimed, err)
	}
	c, _ := ce.st.(store.Gcal).GcalConnection(context.Background(), ce.tid, ce.hum)
	if c.Status != store.GcalRevoked {
		t.Errorf("C23b: status %q, want revoked", c.Status)
	}
	ce.clock.add(2 * time.Hour)
	if claimed, _ := ce.srv.ContactsSyncOnce(context.Background()); claimed {
		t.Error("C23b: a revoked connection's binding was claimed")
	}
}

// C23c (hub half): a contacts cycle that refreshes the access token keeps
// the calendar cycle's due_at and sync token.
func TestContactsSyncRefreshKeepsCalendar(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	before, _ := ce.st.(store.Gcal).GcalConnection(context.Background(), ce.tid, ce.hum)
	ce.fake.ExpireAccessTokens()
	ce.fake.ResetCalls()
	ce.sync(t)
	after, _ := ce.st.(store.Gcal).GcalConnection(context.Background(), ce.tid, ce.hum)
	if ce.fake.Calls("token") != 1 || !after.DueAt.Equal(before.DueAt) || after.SyncToken != before.SyncToken {
		t.Errorf("C23c: %d refreshes, due_at %v -> %v; want 1 and kept", ce.fake.Calls("token"), before.DueAt, after.DueAt)
	}
}

// C23d: the binding moves to another Google account: contacts linked
// under the first are linked by email or created under the second; the
// first account's contacts are not touched.
func TestContactsSyncAccountMove(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	ce.fake.AddPerson(fakegcal.DefaultEmail, gperson())
	alone := gcal.Person{Names: []gcal.Name{{GivenName: "Only", FamilyName: "AtFirst"}}}
	ce.fake.AddPerson(fakegcal.DefaultEmail, alone)
	ce.sync(t)
	firstBook := ce.fake.People(fakegcal.DefaultEmail)
	const b = "second.account@example.com"
	ce.fake.AddPerson(b, gperson()) // the same email at the second account
	ce.reconnectAs(t, b)
	ce.fake.ResetCalls()
	ce.sync(t)
	for _, c := range ce.list(t) {
		if c.GoogleAccount != b {
			t.Errorf("C23d: %q linked under %q, want %s", c.FirstName, c.GoogleAccount, b)
		}
	}
	if n := len(ce.list(t)); n != 2 {
		t.Errorf("C23d: %d contacts, want 2 (linked by email, no duplicate)", n)
	}
	if n := ce.fake.Calls("people.createContact"); n != 1 {
		t.Errorf("C23d: %d creates at %s, want 1 (the one with no email)", n, b)
	}
	if got := ce.fake.People(fakegcal.DefaultEmail); fmt.Sprint(got) != fmt.Sprint(firstBook) {
		t.Errorf("C23d: the first account's people changed")
	}
}

// reconnectAs replaces the member's connection with one of account email,
// its tokens from the fake (Google's consent signs one account in).
func (ce *csEnv) reconnectAs(t *testing.T, email string) {
	t.Helper()
	ctx := context.Background()
	tok, err := ce.gc.Google.Exchange(ctx, ce.fake.IssueCode(email), ce.clock.now())
	if err != nil {
		t.Fatal(err)
	}
	var st store.GcalTokens
	st.AccessExpiry = tok.ExpiresAt
	if st.AccessSealed, st.KMSKeyID, err = ce.gc.Sealer.Seal(ctx, tok.Access); err != nil {
		t.Fatal(err)
	}
	if st.RefreshSealed, _, err = ce.gc.Sealer.Seal(ctx, tok.Refresh); err != nil {
		t.Fatal(err)
	}
	if _, err := ce.st.(store.Gcal).ConnectGcal(ctx, store.GcalConnection{Tenant: ce.tid, Human: ce.hum, GoogleEmail: email,
		GrantedScopes: "openid email " + gcalContactsTestScope}, st, ce.clock.now()); err != nil {
		t.Fatal(err)
	}
}

// C23e: edited in Spool, then deleted at Google: soft-deleted, 0 updates.
// C23f: deleted in Spool, then edited at Google: one delete, not re-imported.
func TestContactsSyncDeleteWins(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	e := ce.fake.AddPerson(fakegcal.DefaultEmail, gperson())
	f := ce.fake.AddPerson(fakegcal.DefaultEmail, gcal.Person{Names: []gcal.Name{{GivenName: "Second", FamilyName: "Person"}}})
	ce.sync(t)
	byRes := map[string]store.Contact{}
	for _, c := range ce.list(t) {
		byRes[c.GoogleResource] = c
	}
	ce.patch(t, byRes[e.ResourceName].ID, store.ContactPatch{LastName: strp("Edited")})
	_ = ce.fake.RemovePerson(fakegcal.DefaultEmail, e.ResourceName)
	if err := ce.pc().DeleteContact(context.Background(), ce.hum, byRes[f.ResourceName].ID, store.ContactDeletedByMember, ce.clock.now()); err != nil {
		t.Fatal(err)
	}
	_ = ce.fake.EditPerson(fakegcal.DefaultEmail, f.ResourceName, func(p *gcal.Person) { p.Names[0].GivenName = "Edited" })
	ce.fake.ResetCalls()
	ce.sync(t)
	if n := len(ce.list(t)); n != 0 {
		t.Errorf("C23e/C23f: %d live contacts, want 0", n)
	}
	if u, d := ce.fake.Calls("people.updateContact"), ce.fake.Calls("people.deleteContact"); u != 0 || d != 1 {
		t.Errorf("C23e/C23f: %d updates, %d deletes; want 0 and 1", u, d)
	}
	if _, ok := ce.fake.Person(fakegcal.DefaultEmail, f.ResourceName); ok {
		t.Error("C23f: the Spool-deleted person is still at Google")
	}
}

// C42: a 9000 character biography is stored cut to 8000 with in_only, and
// a later Spool edit sends nothing. Twin: 7000 characters, not in_only, an
// edit sends one update.
func TestContactsSyncInOnly(t *testing.T) {
	for _, n := range []int{9000, 7000} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			ce := contactsSyncEnvOf(t)
			p := gperson()
			p.Biographies = []gcal.Biography{{Value: strings.Repeat("n", n), ContentType: "TEXT_PLAIN"}}
			ce.fake.AddPerson(fakegcal.DefaultEmail, p)
			ce.sync(t)
			c := ce.one(t)
			long := n > store.ContactNotesMax
			if len(c.Notes) != min(n, store.ContactNotesMax) || c.InOnly != long {
				t.Fatalf("C42: notes %d characters, in_only %t; want %d and %t", len(c.Notes), c.InOnly, min(n, store.ContactNotesMax), long)
			}
			ce.patch(t, c.ID, store.ContactPatch{JobTitle: strp("Lead")})
			ce.fake.ResetCalls()
			ce.sync(t)
			want := 1
			if long {
				want = 0
			}
			if got := ce.fake.Calls("people.updateContact"); got != want {
				t.Errorf("C42: %d updates after a Spool edit, want %d", got, want)
			}
		})
	}
}

// C12: after a sync in and out, no contact value is in any log line.
func TestContactsSyncLogsNoValues(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	ce.fake.AddPerson(fakegcal.DefaultEmail, gperson())
	ce.add(t, store.Contact{FirstName: "Spoolfirst", LastName: "Spoollast", Email: "spool.only@example.com", Phone: "+1 555 010 0042"})
	ce.sync(t)
	ce.fake.FailPeople(http.StatusServiceUnavailable, 1, 0)
	ce.srv.ContactsSyncOnce(context.Background()) //nolint:errcheck // the 503 path logs too
	logs := ce.log.String()
	if !strings.Contains(logs, "contacts: synced") {
		t.Fatalf("CONTROL: the cycle's log line is missing: %s", logs)
	}
	for _, v := range contactLogLeaks(logs) {
		t.Errorf("C12: the log holds the contact value %q; the log:\n%s", v, logs)
	}
}

// contactLogValues are the values of TestContactsSyncLogsNoValues: gperson's
// names, email and two phones and the Spool contact's, each phone as written
// and in E.164. Never a short digit run: the log carries random hex ids (the
// tenant, the connection uuid, the request id), and a bare "555" matched one
// of them on the schedule run 45208818805 (SPL-6324).
var contactLogValues = []string{"FirstName", "LastName", "First.Last", "Spoolfirst", "Spoollast", "spool.only",
	"555 010 0000", "+15550100000", "555 010 0099", "+15550100099", "555 010 0042", "+15550100042"}

// contactLogLeaks returns the contact values the log holds, case-insensitive.
func contactLogLeaks(logs string) []string {
	low := strings.ToLower(logs)
	var hit []string
	for _, v := range contactLogValues {
		if strings.Contains(low, strings.ToLower(v)) {
			hit = append(hit, v)
		}
	}
	return hit
}

// SPL-6324 red control for C12: an unrelated "555" (a port, a hex id) is not
// a leak; the contact's phone, as written or in E.164, and its email are.
func TestContactLogLeaksControl(t *testing.T) {
	for _, c := range []struct {
		line string
		want int
	}{
		{`{"connection":"e6c30968-a722-4555-b284-4f1b8bb22571","addr":"127.0.0.1:45551","message":"http"}`, 0},
		{`{"phone":"+1 555 010 0042","message":"contacts: synced"}`, 1},
		{`{"phone":"+15550100042"}`, 1},
		{`{"email":"first.last@example.com"}`, 1},
	} {
		if got := contactLogLeaks(c.line); len(got) != c.want {
			t.Errorf("contactLogLeaks(%s) = %q, want %d hit(s)", c.line, got, c.want)
		}
	}
}

// The switches: a workspace off the contacts switch, or a grant without
// the contacts scope, is claimed and makes no Google call.
func TestContactsSyncOff(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	ce.gc.ContactsScopes = "https://scope.example/other"
	ce.fake.ResetCalls()
	ce.sync(t)
	if n := ce.calls(append(contactsWriteCalls, "people.connections.list", "token")...); n != 0 {
		t.Errorf("a grant without the contacts scope made %d People call(s), want 0", n)
	}
	ce.gc.ContactsScopes = gcalContactsTestScope
	ce.clock.add(2 * time.Hour)
	ce.sync(t)
	if ce.fake.Calls("people.connections.list") != 1 {
		t.Errorf("twin: the contacts grant listed %d times, want 1", ce.fake.Calls("people.connections.list"))
	}
}

// SPL-6252 (cnf contacts.scopes = contacts.readonly, owner poll 3e7751ee):
// a read-only grant imports and never writes to Google: a Spool edit, a new
// Spool contact and a member's delete of a linked contact send nothing, and
// the deleted row waits (out_cursor kept). Twin: once the write scope is
// granted, the next cycle sends all three.
func TestContactsSyncReadOnlyGrant(t *testing.T) {
	ce := contactsSyncEnvOf(t)
	ce.gc.ContactsScopes = gcalContactsTestScope + ".readonly"
	ce.reconnectScopes(t, "openid email "+gcalContactsTestScope+".readonly")
	g := ce.fake.AddPerson(fakegcal.DefaultEmail, gperson())
	ce.sync(t)
	c := ce.one(t)
	if c.GoogleResource != g.ResourceName {
		t.Fatalf("read-only: the import did not link %+v", c)
	}
	ce.patch(t, c.ID, store.ContactPatch{FirstName: strp("Edited")})
	ce.add(t, store.Contact{FirstName: "Spool", LastName: "Only"})
	ce.fake.ResetCalls()
	ce.sync(t)
	if n := ce.writes(); n != 0 {
		t.Errorf("read-only: %d Google writes after a Spool edit and a new contact, want 0", n)
	}
	if err := ce.pc().DeleteContact(context.Background(), ce.hum, c.ID, store.ContactDeletedByMember, ce.clock.now()); err != nil {
		t.Fatal(err)
	}
	ce.fake.ResetCalls()
	ce.sync(t)
	if _, ok := ce.fake.Person(fakegcal.DefaultEmail, g.ResourceName); !ok || ce.writes() != 0 {
		t.Errorf("read-only: a member's delete reached Google (%d writes)", ce.writes())
	}
	// twin: the write scope granted, the next cycle sends the waiting rows
	ce.gc.ContactsScopes = gcalContactsTestScope
	ce.reconnectScopes(t, "openid email "+gcalContactsTestScope)
	ce.fake.ResetCalls()
	ce.sync(t)
	if n := ce.fake.Calls("people.createContact"); n != 1 {
		t.Errorf("twin: %d creates with the write scope, want 1", n)
	}
	if _, ok := ce.fake.Person(fakegcal.DefaultEmail, g.ResourceName); ok {
		t.Errorf("twin: the member's delete did not reach Google with the write scope")
	}
}

// reconnectScopes stores the member's connection again with granted.
func (ce *csEnv) reconnectScopes(t *testing.T, granted string) {
	t.Helper()
	ctx := context.Background()
	gs := ce.st.(store.Gcal)
	tok, err := gs.GcalTokens(ctx, ce.tid, ce.hum)
	if err != nil {
		t.Fatal(err)
	}
	c, err := gs.GcalConnection(ctx, ce.tid, ce.hum)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := gs.ConnectGcal(ctx, store.GcalConnection{Tenant: ce.tid, Human: ce.hum, GoogleEmail: c.GoogleEmail,
		GrantedScopes: granted}, tok, ce.clock.now()); err != nil {
		t.Fatal(err)
	}
}
