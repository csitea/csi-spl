package hub

import (
	"context"
	"errors"
	"fmt"
	"html"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Google Contacts sync cycle (spec 154 section 2.5, v1.3 sections
// 11.2.2 and 11.3; build row B8 amended, SPL-6253). RunSweeper starts
// runContactsSync: every contactsSyncTick it syncs the bindings that are
// due, one at a time, oldest due_at first, so one person's backlog never
// delays another's.
//
// Three scopes per cycle, never nested (2.5): the claim runs as the operator
// over contacts_sync (store ClaimContactsSync); the token read and refresh
// run in the binding's workspace (GcalTokens, GcalShared.SetGcalAccess);
// every read and write of the person's contacts runs under inPerson of the
// binding's human (store ContactsCycle). Each is its own short transaction
// and none is open while Google is called.
//
// In: people.connections.list with the stored sync token (the full list
// when there is none, or when Google says it expired), one store call per
// page (ApplyGooglePeople: B14's lock, the match, the writes), the lease
// renewed after each page. Out: the contacts changed since out_cursor are
// created, updated (read first, only the primary entries changed) or
// deleted at Google, one at a time, at most contactsWritesMax a cycle. The
// conflict rules are the store's planGooglePeople (In) and the echo hash
// (Out). A contact cut to a cap on its way in (in_only) is never written
// back. No contact value is logged or put in status_detail (C12).

const (
	contactsSyncTick   = 60 * time.Second // the ticker
	contactsSyncEvery  = 10 * time.Minute // a binding's next due after a good cycle (2.5)
	contactsLease      = 5 * time.Minute  // the claim's lease, renewed after each page
	contactsPerTick    = 50               // bindings one tick syncs; the rest wait a tick
	contactsRetryAfter = 5 * time.Minute  // after a failed cycle
	contactsOffRecheck = time.Hour        // a binding the switches or the grant leave out
	contactsBackoffMax = time.Hour        // the longest 2^n backoff (2.5 "Rate limits")
	contactsWritesMax  = store.ContactsCycleMax
	contactsDetailHead = "Google contacts sync: "
)

// contactsTryRe reads the try count back from a backoff status line.
var contactsTryRe = regexp.MustCompile(`\(try ([0-9]+)\)`)

// errContactsRetry: a contact Google changed since its etag was stored; the
// next cycle's In half decides again (2.5 "Conflicts").
var errContactsRetry = errors.New("contacts: the person changed at google, retry next cycle")

// contactsStores is the store the cycle needs, each part of it.
type contactsStores struct {
	binds store.ContactsSyncs
	cycle store.ContactsCycle
	gcal  store.Gcal
	share store.GcalShared
}

func (s *Server) contactsSyncStores() (contactsStores, bool) {
	var c contactsStores
	var ok [4]bool
	c.binds, ok[0] = s.o.Store.(store.ContactsSyncs)
	c.cycle, ok[1] = s.o.Store.(store.ContactsCycle)
	c.gcal, ok[2] = s.o.Store.(store.Gcal)
	c.share, ok[3] = s.o.Store.(store.GcalShared)
	return c, ok[0] && ok[1] && ok[2] && ok[3]
}

// runContactsSync syncs due bindings every contactsSyncTick until ctx ends.
func (s *Server) runContactsSync(ctx context.Context) {
	t := time.NewTicker(contactsSyncTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			for range contactsPerTick {
				claimed, err := s.ContactsSyncOnce(ctx)
				if err != nil {
					s.o.Log.Warn().Str("err", contactsDetail(err)).Msg("contacts: sync cycle")
				}
				if !claimed {
					break
				}
			}
		}
	}
}

// ContactsSyncOnce claims the binding due longest and syncs it. It answers
// whether it claimed one; nothing is claimed while the contacts switch is
// empty, Google or its People API root is not configured, or the store
// keeps no bindings.
func (s *Server) ContactsSyncOnce(ctx context.Context) (bool, error) {
	g := s.o.Gcal
	st, ok := s.contactsSyncStores()
	if !ok || len(s.o.ContactsWorkspaces) == 0 || !g.configured() || !g.Google.PeopleConfigured() {
		return false, nil
	}
	b, l, err := st.binds.ClaimContactsSync(ctx, s.o.Now(), contactsLease)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	cy := &contactsCycle{s: s, g: g, st: st, b: b, l: l}
	return true, cy.run(ctx)
}

// contactsCycle is one claimed sync of one binding.
type contactsCycle struct {
	s       *Server
	g       *GcalConnect
	st      contactsStores
	b       store.ContactsSync
	l       store.ContactsLease
	account string // the connection's Google email, lowercased: the link's account
	// writable: the grant holds a contacts scope that is not a read-only
	// one, so the Out half runs. With cnf contacts.scopes contacts.readonly
	// (SPL-6252, owner poll 3e7751ee "read-only contacts access") the cycle
	// is the import alone: In, no Out half, no Google write, and out_cursor
	// kept, so a later write grant sends what changed in Spool meanwhile.
	writable bool
	access   marketing.Plaintext
	writes   int // Google writes this cycle
	other    int // live contacts linked under another account, after the In half
	in       store.GoogleApplied
	photo    contactsPhotoPass // the In half's pictures (contacts_photo.go, B16)
}

func (cy *contactsCycle) now() time.Time { return cy.s.o.Now() }

// run syncs and finishes the cycle. A lost lease returns at once, writing
// nothing more; invalid_grant revokes the connection; a 429 or 503 backs
// off; any other failure is due again after contactsRetryAfter.
func (cy *contactsCycle) run(ctx context.Context) error {
	t := cy.b.Tenant
	if !cy.s.contactsListed(t) || !cy.g.listed(t) {
		return cy.finish(ctx, nil, cy.now().Add(contactsOffRecheck))
	}
	conn, err := cy.st.gcal.GcalConnection(ctx, t, cy.b.Human)
	if err != nil {
		return cy.fail(ctx, nil, err)
	}
	// a calendar-only grant has no contacts to sync: no Google call
	if !gcal.HoldsAny(cy.g.ContactsScopes, conn.GrantedScopes) {
		return cy.finish(ctx, nil, cy.now().Add(contactsOffRecheck))
	}
	cy.account = strings.ToLower(conn.GoogleEmail)
	cy.writable = gcal.HoldsAny(contactsWriteScopes(cy.g.ContactsScopes), conn.GrantedScopes)
	cursor, err := cy.sync(ctx)
	if err != nil {
		return cy.fail(ctx, cursor, err)
	}
	if err := cy.photos(ctx); err != nil { // after the writes (spec 154 11.4, B16)
		return cy.fail(ctx, cursor, err)
	}
	detail := cy.photoDetail() // "" clears an earlier failure's line
	if cy.b.BackoffUntil != nil || detail != cy.b.StatusDetail && (detail != "" || strings.HasPrefix(cy.b.StatusDetail, contactsDetailHead)) {
		if err := cy.st.binds.SetContactsBackoff(ctx, cy.l, nil, detail, cy.now()); err != nil {
			return err
		}
	}
	cy.s.o.Log.Info().Str("tenant", t).Str("person", cy.b.Human).Int("added", cy.in.Added).
		Int("linked", cy.in.Linked).Int("updated", cy.in.Updated).Int("deleted", cy.in.Deleted).
		Int("kept", cy.in.SpoolKept).Int("skipped", cy.in.Skipped).Int("writes", cy.writes).Msg("contacts: synced")
	return cy.finish(ctx, cursor, cy.now().Add(contactsSyncEvery))
}

// contactsWriteScopes is the scopes of cnf contacts.scopes that write:
// every one but a ".readonly" one (no scope string is written in code).
func contactsWriteScopes(scopes string) string {
	var w []string
	for _, sc := range strings.Fields(scopes) {
		if !strings.HasSuffix(sc, ".readonly") {
			w = append(w, sc)
		}
	}
	return strings.Join(w, " ")
}

// fail records a failed cycle and finishes it.
func (cy *contactsCycle) fail(ctx context.Context, cursor *time.Time, err error) error {
	now := cy.now()
	switch {
	case errors.Is(err, store.ErrContactsLeaseLost):
		return err
	case errors.Is(err, gcal.ErrInvalidGrant):
		cy.s.o.Log.Warn().Str("tenant", cy.b.Tenant).Str("person", cy.b.Human).Msg("contacts: grant revoked at google")
		if rerr := cy.st.share.RevokeGcalConnection(ctx, cy.b.Tenant, cy.b.Human,
			"google refused the refresh token (invalid_grant): reconnect", now); rerr != nil && !errors.Is(rerr, store.ErrNotFound) {
			return rerr
		}
		return cy.finish(ctx, cursor, now.Add(contactsOffRecheck))
	case errors.Is(err, gcal.ErrRateLimited):
		wait, detail := contactsBackoff(err, cy.b.StatusDetail)
		until := now.Add(wait)
		if berr := cy.st.binds.SetContactsBackoff(ctx, cy.l, &until, detail, now); berr != nil {
			return berr
		}
		return cy.finish(ctx, cursor, until)
	}
	if berr := cy.st.binds.SetContactsBackoff(ctx, cy.l, nil, contactsDetailHead+contactsDetail(err), now); berr != nil {
		return berr
	}
	if ferr := cy.finish(ctx, cursor, now.Add(contactsRetryAfter)); ferr != nil {
		return ferr
	}
	return err
}

// finish ends the cycle: the sync token as the In half left it, the out
// cursor (nil keeps the stored one), the next due, the lease cleared.
func (cy *contactsCycle) finish(ctx context.Context, cursor *time.Time, next time.Time) error {
	return cy.st.binds.FinishContactsSync(ctx, cy.l, store.ContactsSyncDone{SyncToken: cy.b.SyncToken,
		OutCursor: cursor, NextDue: next}, cy.now())
}

// contactsBackoff is a 429 or 503's wait (Retry-After, else 2^n minutes,
// at most contactsBackoffMax; n counts the tries in a row, read back from
// the status line) and the status line to store.
func contactsBackoff(err error, prev string) (time.Duration, string) {
	n := 1
	if m := contactsTryRe.FindStringSubmatch(prev); m != nil && strings.HasPrefix(prev, contactsDetailHead) {
		if k, perr := strconv.Atoi(m[1]); perr == nil && k < 30 {
			n = k + 1
		}
	}
	wait := min(time.Duration(1<<(n-1))*time.Minute, contactsBackoffMax)
	var he *gcal.HTTPError
	if errors.As(err, &he) && he.RetryAfter > 0 {
		wait = min(he.RetryAfter, contactsBackoffMax)
	}
	return wait, fmt.Sprintf("%sGoogle asked to slow down; next try in %s (try %d)", contactsDetailHead, wait, n)
}

// contactsDetail is an error as a status line or log value: Google's status
// and reason only (its message may quote a contact value, C12), else the
// error's own text, which names fields, never values (store), short.
func contactsDetail(err error) string {
	var he *gcal.HTTPError
	if errors.As(err, &he) {
		return fmt.Sprintf("HTTP %d %s", he.Status, he.Reason)
	}
	d := err.Error()
	if len(d) > 300 {
		d = d[:300]
	}
	return d
}

// sync is the cycle's Google work: a valid access token, In, then Out
// (In alone on a read-only grant: nil keeps out_cursor).
func (cy *contactsCycle) sync(ctx context.Context) (*time.Time, error) {
	if err := cy.token(ctx, false); err != nil {
		return nil, err
	}
	if err := cy.inHalf(ctx); err != nil {
		return nil, err
	}
	if !cy.writable {
		return nil, nil
	}
	return cy.outHalf(ctx)
}

// token holds a valid access token: the stored one while it lives longer
// than gcalRefreshAhead, else (or with force) a refreshed one, sealed and
// stored by the shared write (2.5 "One token pair, two cycles").
func (cy *contactsCycle) token(ctx context.Context, force bool) error {
	tok, err := cy.st.gcal.GcalTokens(ctx, cy.b.Tenant, cy.b.Human)
	if err != nil {
		return err
	}
	now := cy.now()
	if !force && tok.AccessExpiry.After(now.Add(gcalRefreshAhead)) {
		cy.access, err = cy.g.Sealer.Open(ctx, tok.AccessSealed)
		return err
	}
	ref, err := cy.g.Sealer.Open(ctx, tok.RefreshSealed)
	if err != nil {
		return err
	}
	fresh, err := cy.g.Google.Refresh(ctx, ref, now)
	if err != nil {
		return err
	}
	next := store.GcalTokens{RefreshSealed: tok.RefreshSealed, AccessExpiry: fresh.ExpiresAt}
	if next.AccessSealed, next.KMSKeyID, err = cy.g.Sealer.Seal(ctx, fresh.Access); err != nil {
		return err
	}
	if fresh.Refresh.Reveal() != "" { // Google may rotate the refresh token
		if next.RefreshSealed, _, err = cy.g.Sealer.Seal(ctx, fresh.Refresh); err != nil {
			return err
		}
	}
	if err := cy.st.share.SetGcalAccess(ctx, cy.b.Tenant, cy.b.Human, next, now); err != nil {
		return err
	}
	cy.access = fresh.Access
	return nil
}

// call runs one Google call; an access token Google refuses (401) is
// refreshed once and the call made again.
func (cy *contactsCycle) call(ctx context.Context, fn func(marketing.Plaintext) error) error {
	err := fn(cy.access)
	if !errors.Is(err, gcal.ErrUnauthorized) {
		return err
	}
	if err := cy.token(ctx, true); err != nil {
		return err
	}
	return fn(cy.access)
}

// renew moves the lease on (after each page, 2.5).
func (cy *contactsCycle) renew(ctx context.Context) error {
	l, err := cy.st.binds.RenewContactsLease(ctx, cy.l, cy.now(), contactsLease)
	if err != nil {
		return err
	}
	cy.l = l
	return nil
}

// inHalf is Google -> Spool. With no stored token (the first sync of a
// binding, or a binding that moved to another Google account) the full
// list never deletes; an expired token is cleared and
// the full list read, never deleting either (2.5, C19).
func (cy *contactsCycle) inHalf(ctx context.Context) error {
	// contacts linked under another account: the binding moved account
	// (C23d), and the stored token is the old account's: the full list
	n, err := cy.st.cycle.ApplyGooglePeople(ctx, cy.b.Human, store.GoogleApply{Account: cy.account}, nil, cy.now())
	if err != nil {
		return err
	}
	if n.OtherAccount > 0 {
		cy.b.SyncToken = ""
	}
	err = cy.inPages(ctx, cy.b.SyncToken)
	if errors.Is(err, gcal.ErrSyncTokenGone) && cy.b.SyncToken != "" {
		cy.s.o.Log.Info().Str("tenant", cy.b.Tenant).Str("person", cy.b.Human).Msg("contacts: sync token expired, full list")
		cy.b.SyncToken = ""
		err = cy.inPages(ctx, "")
	}
	return err
}

// inPages reads every page of one list and applies each.
func (cy *contactsCycle) inPages(ctx context.Context, syncToken string) error {
	apply := store.GoogleApply{Account: cy.account, NoDeletes: syncToken == ""}
	pageToken := ""
	for {
		var page gcal.ConnectionsPage
		err := cy.call(ctx, func(a marketing.Plaintext) error {
			var err error
			page, err = cy.g.Google.ListConnections(ctx, a, gcal.PeopleListOptions{SyncToken: syncToken, PageToken: pageToken})
			return err
		})
		if err != nil {
			return err
		}
		cy.notePhotos(page.Connections)
		people := make([]store.GooglePerson, 0, len(page.Connections))
		for _, p := range page.Connections {
			people = append(people, contactFromGoogle(p))
		}
		n, err := cy.st.cycle.ApplyGooglePeople(ctx, cy.b.Human, apply, people, cy.now())
		if err != nil {
			return err
		}
		cy.addIn(n)
		if err := cy.renew(ctx); err != nil {
			return err
		}
		if page.NextPageToken == "" {
			cy.b.SyncToken = page.NextSyncToken
			return nil
		}
		pageToken = page.NextPageToken
	}
}

// addIn adds one page's counts; OtherAccount is the last page's.
func (cy *contactsCycle) addIn(n store.GoogleApplied) {
	cy.in.Added += n.Added
	cy.in.Linked += n.Linked
	cy.in.Updated += n.Updated
	cy.in.Deleted += n.Deleted
	cy.in.SpoolKept += n.SpoolKept
	cy.in.Skipped += n.Skipped
	cy.other = n.OtherAccount
}

// outHalf is Spool -> Google over the contacts changed since out_cursor
// (from the start when contacts are linked under another account: the
// binding moved, C23d), page by page, at most contactsWritesMax writes. It
// answers the cursor to store: every row changed at or before it is done.
// A contact to retry, or the write cap, holds it just before that row, so
// the next cycle reads it again (a done row then skips by its hash).
func (cy *contactsCycle) outHalf(ctx context.Context) (*time.Time, error) {
	since, after := cy.b.OutCursor, ""
	if cy.other > 0 {
		since = nil
	}
	var hold, last *time.Time
	for {
		rows, err := cy.st.cycle.ContactsChangedSince(ctx, cy.b.Human, since, after)
		if err != nil {
			return contactsCursor(cy.b.OutCursor, hold, last), err
		}
		for _, r := range rows {
			if cy.writes >= contactsWritesMax {
				return contactsCursor(cy.b.OutCursor, minTime(hold, &r.ChangedAt), last), nil
			}
			err := cy.push(ctx, r)
			if err != nil && !errors.Is(err, errContactsRetry) {
				return contactsCursor(cy.b.OutCursor, minTime(hold, &r.ChangedAt), last), err
			}
			if err != nil {
				hold = minTime(hold, &r.ChangedAt)
			}
			at := r.ChangedAt
			since, after, last = &at, r.ID, &at
		}
		if len(rows) < store.ContactsCycleMax {
			return contactsCursor(cy.b.OutCursor, hold, last), nil
		}
	}
}

// contactsCursor is the out cursor to store: stored when nothing was read,
// the last row read when all were done, else 1 µs before the first row not
// done (never before the stored one).
func contactsCursor(stored, hold, last *time.Time) *time.Time {
	switch {
	case hold != nil:
		c := hold.Add(-time.Microsecond)
		if stored != nil && c.Before(*stored) {
			return stored
		}
		return &c
	case last != nil:
		return last
	}
	return stored
}

func minTime(a, b *time.Time) *time.Time {
	if a == nil || (b != nil && b.Before(*a)) {
		return b
	}
	return a
}

// push sends one changed contact: a member's delete, an update of a linked
// contact whose values changed since its hash, or a create.
func (cy *contactsCycle) push(ctx context.Context, r store.ContactOut) error {
	linked := r.GoogleResource != "" && r.GoogleAccount == cy.account
	switch {
	case r.DeletedAt != nil:
		if linked && !r.InOnly {
			cy.writes++
			if err := cy.call(ctx, func(a marketing.Plaintext) error {
				return cy.g.Google.DeleteContact(ctx, a, r.GoogleResource)
			}); err != nil {
				return err
			}
		}
		return notFoundOK(cy.st.cycle.DropDeletedContact(ctx, cy.b.Human, r.ID))
	case r.InOnly:
		return nil
	case linked:
		hash := store.ContactSyncHash(r.Contact)
		if hash == r.SyncHash {
			return nil
		}
		return cy.update(ctx, r, hash)
	}
	return cy.create(ctx, r)
}

func notFoundOK(err error) error {
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	return err
}

// update reads the person, changes only Spool's primary entries in its
// lists, and sends it with the stored etag (2.5 "Out", 11.3 "Write-back").
func (cy *contactsCycle) update(ctx context.Context, r store.ContactOut, hash string) error {
	var p gcal.Person
	err := cy.call(ctx, func(a marketing.Plaintext) error {
		var err error
		p, err = cy.g.Google.GetPerson(ctx, a, r.GoogleResource)
		return err
	})
	if errors.Is(err, gcal.ErrNotFound) { // deleted at Google: the next In half soft-deletes it
		return nil
	}
	if err != nil {
		return err
	}
	if p.ETag != r.GoogleETag {
		return errContactsRetry
	}
	googleFromContact(&p, r.Contact)
	fields := gcal.PeopleUpdateFields
	if r.Birthday == "" { // never clear Google's birthday (11.3)
		fields = strings.Replace(fields, ",birthdays", "", 1)
	}
	cy.writes++
	err = cy.call(ctx, func(a marketing.Plaintext) error {
		var err error
		p, err = cy.g.Google.UpdateContact(ctx, a, p, fields)
		return err
	})
	if errors.Is(err, gcal.ErrETagMismatch) {
		return errContactsRetry
	}
	if err != nil {
		return err
	}
	_, err = cy.st.cycle.LinkContact(ctx, cy.b.Human, r.ID,
		store.ContactLink{Account: cy.account, Resource: r.GoogleResource, ETag: p.ETag, SyncHash: hash})
	return notFoundOK(err)
}

// create makes the contact at Google and links it.
func (cy *contactsCycle) create(ctx context.Context, r store.ContactOut) error {
	var p gcal.Person
	googleFromContact(&p, r.Contact)
	cy.writes++
	err := cy.call(ctx, func(a marketing.Plaintext) error {
		var err error
		p, err = cy.g.Google.CreateContact(ctx, a, p)
		return err
	})
	if err != nil {
		return err
	}
	_, err = cy.st.cycle.LinkContact(ctx, cy.b.Human, r.ID, store.ContactLink{Account: cy.account,
		Resource: p.ResourceName, ETag: p.ETag, SyncHash: store.ContactSyncHash(r.Contact)})
	return notFoundOK(err)
}

// ---- the mapping of spec 11.3 ----

// primaryIndex is the index of the primary entry of n entries, else 0;
// -1 for none.
func primaryIndex(n int, primary func(int) bool) int {
	if n == 0 {
		return -1
	}
	for i := range n {
		if primary(i) {
			return i
		}
	}
	return 0
}

// contactCut is s cut at max characters, and whether it was cut.
func contactCut(s string, max int) (string, bool) {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) <= max {
		return s, false
	}
	return strings.TrimSpace(string([]rune(s)[:max])), true
}

var contactTagRe = regexp.MustCompile(`<[^>]*>`)

// contactFromGoogle maps a Google person to Spool's values (2.5 "In", 11.3):
// the primary entry of each list (else the first), the birthday's date (a
// free-form text alone is no birthday), the notes as text; a value over its
// cap is cut and in_only set; an email or phone Spool cannot hold is left
// out, and in_only set, so the Out half never overwrites Google's.
func contactFromGoogle(p gcal.Person) store.GooglePerson {
	var c store.Contact
	cut := false
	set := func(to *string, v string, max int) {
		var was bool
		*to, was = contactCut(v, max)
		cut = cut || was
	}
	if i := primaryIndex(len(p.Names), func(i int) bool { return p.Names[i].Metadata.IsPrimary() }); i >= 0 {
		set(&c.FirstName, p.Names[i].GivenName, store.ContactNameMax)
		set(&c.LastName, p.Names[i].FamilyName, store.ContactNameMax)
	}
	if i := primaryIndex(len(p.EmailAddresses), func(i int) bool { return p.EmailAddresses[i].Metadata.IsPrimary() }); i >= 0 {
		c.Email = strings.ToLower(strings.TrimSpace(p.EmailAddresses[i].Value))
	}
	if i := primaryIndex(len(p.PhoneNumbers), func(i int) bool { return p.PhoneNumbers[i].Metadata.IsPrimary() }); i >= 0 {
		c.Phone = strings.TrimSpace(p.PhoneNumbers[i].Value)
	}
	if i := primaryIndex(len(p.Organizations), func(i int) bool { return p.Organizations[i].Metadata.IsPrimary() }); i >= 0 {
		set(&c.Company, p.Organizations[i].Name, store.ContactCompanyMax)
		set(&c.JobTitle, p.Organizations[i].Title, store.ContactJobTitleMax)
	}
	c.Birthday = googleBirthday(p.Birthdays)
	if i := primaryIndex(len(p.Biographies), func(i int) bool { return p.Biographies[i].Metadata.IsPrimary() }); i >= 0 {
		b := p.Biographies[i]
		v := b.Value
		if b.ContentType == "TEXT_HTML" {
			v = html.UnescapeString(contactTagRe.ReplaceAllString(v, ""))
		}
		set(&c.Notes, v, store.ContactNotesMax)
	}
	c, dropped := contactKeepable(c)
	c.InOnly = cut || dropped
	return store.GooglePerson{Resource: p.ResourceName, ETag: p.ETag, Deleted: p.Metadata.Deleted,
		Values: c, UpdatedAt: p.UpdatedAt()}
}

// contactKeepable drops an email or a phone the store refuses, and answers
// whether it dropped one.
func contactKeepable(c store.Contact) (store.Contact, bool) {
	dropped := false
	for range 2 {
		_, err := store.CleanContact(c)
		switch {
		case errors.Is(err, store.ErrContactBadEmail):
			c.Email, dropped = "", true
		case errors.Is(err, store.ErrContactBadPhone):
			c.Phone, dropped = "", true
		default:
			return c, dropped
		}
	}
	return c, dropped
}

// googleBirthday is the primary (else first) birthday with a date, as
// YYYY-MM-DD or --MM-DD; "" for none or a date that is no date.
func googleBirthday(bs []gcal.Birthday) string {
	i := primaryIndex(len(bs), func(i int) bool { return bs[i].Metadata.IsPrimary() && bs[i].Date != nil })
	if i < 0 || bs[i].Date == nil {
		for j := range bs {
			if bs[j].Date != nil {
				i = j
				break
			}
		}
	}
	if i < 0 || bs[i].Date == nil {
		return ""
	}
	d := bs[i].Date
	y := d.Year
	if y == 0 {
		y = 2000 // a leap year: --02-29 is a birthday
	}
	if _, err := time.Parse("2006-01-02", fmt.Sprintf("%04d-%02d-%02d", y, d.Month, d.Day)); err != nil {
		return ""
	}
	if d.Year == 0 {
		return fmt.Sprintf("--%02d-%02d", d.Month, d.Day)
	}
	return fmt.Sprintf("%04d-%02d-%02d", d.Year, d.Month, d.Day)
}

// googleFromContact writes Spool's values into p (Spool -> Google, 2.5
// "Out", 11.3): only the primary entry of each list changes, every other
// entry Google holds is kept; an empty Spool value removes that entry. The
// birthday is written only when Spool holds one; the notes are one plain
// text biography.
func googleFromContact(p *gcal.Person, c store.Contact) {
	if i := primaryIndex(len(p.Names), func(i int) bool { return p.Names[i].Metadata.IsPrimary() }); i >= 0 {
		p.Names[i].GivenName, p.Names[i].FamilyName = c.FirstName, c.LastName
		if c.FirstName == "" && c.LastName == "" {
			p.Names = append(p.Names[:i], p.Names[i+1:]...)
		}
	} else if c.FirstName != "" || c.LastName != "" {
		p.Names = []gcal.Name{{GivenName: c.FirstName, FamilyName: c.LastName}}
	}
	p.EmailAddresses = setPrimary(p.EmailAddresses, c.Email,
		func(e gcal.EmailAddress) bool { return e.Metadata.IsPrimary() },
		func(e *gcal.EmailAddress, v string) { e.Value = v })
	p.PhoneNumbers = setPrimary(p.PhoneNumbers, c.Phone,
		func(e gcal.PhoneNumber) bool { return e.Metadata.IsPrimary() },
		func(e *gcal.PhoneNumber, v string) { e.Value = v })
	org := ""
	if c.Company != "" || c.JobTitle != "" {
		org = "\x00" // any non-empty value: the entry stays
	}
	p.Organizations = setPrimary(p.Organizations, org,
		func(e gcal.Organization) bool { return e.Metadata.IsPrimary() },
		func(e *gcal.Organization, _ string) { e.Name, e.Title = c.Company, c.JobTitle })
	if b := contactDate(c.Birthday); b != nil {
		p.Birthdays = []gcal.Birthday{{Date: b}}
	}
	p.Biographies = nil
	if c.Notes != "" {
		p.Biographies = []gcal.Biography{{Value: c.Notes, ContentType: "TEXT_PLAIN"}}
	}
}

// setPrimary sets v on the primary (else first) entry of list, removes
// that entry when v is "", or adds one when there is none.
func setPrimary[E any](list []E, v string, primary func(E) bool, put func(*E, string)) []E {
	i := primaryIndex(len(list), func(i int) bool { return primary(list[i]) })
	switch {
	case i >= 0 && v == "":
		return append(list[:i:i], list[i+1:]...)
	case i >= 0:
		put(&list[i], v)
		return list
	case v == "":
		return list
	}
	var e E
	put(&e, v)
	return append([]E{e}, list...)
}

// contactDate is a stored birthday as a Google date; nil for none.
func contactDate(b string) *gcal.Date {
	if b == "" {
		return nil
	}
	var d gcal.Date
	if rest, ok := strings.CutPrefix(b, "--"); ok {
		_, err := fmt.Sscanf(rest, "%02d-%02d", &d.Month, &d.Day)
		if err != nil {
			return nil
		}
		return &d
	}
	if _, err := fmt.Sscanf(b, "%04d-%02d-%02d", &d.Year, &d.Month, &d.Day); err != nil {
		return nil
	}
	return &d
}
