package store

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// The contacts store (spec 154 v1.1 sections 2.3, 2.6, 3 and 4, build row
// B2) over rdb 0226's realm table personal.contacts. The list is its
// person's own (O5 = B): one list, the same in every workspace, so no call
// takes a workspace. person comes only from the authenticated human session,
// as for the rest of the realm (personal.go). The Postgres side runs every
// statement in inPerson, so the person_scope policy binds it even where a
// WHERE person_id is forgotten; another person's contact id reads as
// ErrNotFound, never as a refusal (spec 4: 404 for another person's id).
//
// A soft-deleted contact (deleted_at set, its Google delete still to send)
// is gone from every read here at once (spec 2.6 "Erase one"). The 30-day
// purge of those rows reaches every person, so it is the one call with no
// person: PurgeDeletedContacts runs rdb 0226's SECURITY DEFINER door in a
// plain transaction, with no app.* setting and no operator scope (spec 2.6
// W4). The binding's side of that purge is contacts_sync.go's.
//
// No contact value goes into an error or a log line (spec 2.6, C12): the
// errors below name the field, never its value.

// The limits of rdb 0226's CHECKs.
const (
	ContactNameMax  = 100 // first_name, last_name, in characters
	ContactEmailMin = 3
	ContactEmailMax = 320
	ContactsPageMax = 100 // one page of ListContacts (spec 2.4 amendment: one match per page)
	contactWordsMax = 8   // the words of a query that count
)

// The deleted_by values of rdb 0226.
const (
	ContactDeletedByMember = "member"
	ContactDeletedByGoogle = "google-sync"
)

// The value errors, each an ErrRealmBad; the hub answers contact_empty,
// bad_email and bad_phone (spec 4).
var (
	ErrContactEmpty    = fmt.Errorf("%w: a contact needs a name, an email or a phone", ErrRealmBad)
	ErrContactBadEmail = fmt.Errorf("%w: the email is not an address", ErrRealmBad)
	ErrContactBadPhone = fmt.Errorf("%w: the phone is not a phone number", ErrRealmBad)
)

// contactPhoneRe is rdb 0226's phone CHECK: what people type, not E.164.
var contactPhoneRe = regexp.MustCompile(`^[+0-9 ().-]{3,40}$`)

// contactDigitsRe is a query word of digits only, matched against the phone
// with its spaces and punctuation removed (spec 2.3, C10b).
var contactDigitsRe = regexp.MustCompile(`^[0-9]+$`)

// Contact is one live personal.contacts row. Email and Phone "" = NULL.
// GoogleAccount and GoogleResource are both set or both "" (linked to
// Google under that account, spec 2.5).
type Contact struct {
	ID             string
	FirstName      string
	LastName       string
	Email          string
	Phone          string
	GoogleAccount  string
	GoogleResource string
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// ContactPatch is a PATCH of a contact: nil fields are kept; "" clears one.
type ContactPatch struct {
	FirstName *string
	LastName  *string
	Email     *string
	Phone     *string
}

// ContactQuery is one ListContacts call. Q "" lists every contact; After is
// the Next of the page before ("" = the first page); Limit <= 0 or above
// ContactsPageMax is ContactsPageMax.
type ContactQuery struct {
	Q     string
	After string
	Limit int
}

// ContactPage is one page in created order; Next "" = the last page.
type ContactPage struct {
	Contacts []Contact
	Next     string
}

// ContactPurged is one person of a purge: PendingGoogle = a purged row was
// a member's delete of a linked contact that never reached Google (C7c).
type ContactPurged struct {
	Person        string
	PendingGoogle bool
}

// ContactsCycleMax is the most rows one outbound read returns: the cycle
// sends at most 200 writes, the rest the next cycle (spec 2.5 "Rate limits").
const ContactsCycleMax = 200

// ContactOut is one row of the cycle's outbound read: a contact changed
// since the out cursor, live or a member's soft delete still to send to
// Google, with its Google link (spec 2.5 "Out").
type ContactOut struct {
	Contact
	GoogleETag string
	SyncHash   string     // "" = NULL
	DeletedAt  *time.Time // nil = live
	ChangedAt  time.Time  // GREATEST(updated_at, COALESCE(deleted_at, updated_at)), the out cursor's clock
}

// ContactLink is the Google link a cycle stores on a contact: Account and
// Resource both set (linked under that account) or both "" (unlinked);
// SyncHash "" = NULL, else 64 hex characters (spec 2.5 "Echo").
type ContactLink struct {
	Account  string
	Resource string
	ETag     string
	SyncHash string
}

// The limits of rdb 0226's link CHECKs.
const (
	ContactGoogleResourceMax = 200
	ContactGoogleETagMax     = 200
)

// ContactsCycle is the sync cycle's half of the contacts store (spec 2.5,
// build row B8a), each call in inPerson of the binding's own human (seat
// note N1: the person is the claim's, not a session's).
type ContactsCycle interface {
	// ContactsChangedSince is the person's contacts whose changed time is
	// after since (nil: every one), live or soft-deleted by a member (the
	// Google delete still to send), in changed order, at most
	// ContactsCycleMax; a Google-side delete is never sent back.
	ContactsChangedSince(ctx context.Context, person string, since *time.Time) ([]ContactOut, error)
	// LinkContact stores the Google link of a live contact, never its
	// updated_at (a link is no change to send). ErrConflict: another of
	// the person's contacts holds that link (rdb 0226 contacts_google).
	LinkContact(ctx context.Context, person, contactID string, l ContactLink) (Contact, error)
	// DropDeletedContact hard-deletes a soft-deleted contact once Google
	// confirmed its delete (spec 2.5 "Deletes"); ErrNotFound for a live one.
	DropDeletedContact(ctx context.Context, person, contactID string) error
}

var (
	_ ContactsCycle = (*Memory)(nil)
	_ ContactsCycle = (*Postgres)(nil)
)

// cleanContactLink lowercases the account and checks l against rdb 0226.
func cleanContactLink(l ContactLink) (ContactLink, error) {
	l.Account = strings.ToLower(strings.TrimSpace(l.Account))
	bad := fmt.Errorf("%w: a bad Google link", ErrRealmBad)
	if (l.Account == "") != (l.Resource == "") || len(l.Resource) > ContactGoogleResourceMax ||
		len(l.ETag) > ContactGoogleETagMax || !utf8.ValidString(l.Resource+l.ETag) {
		return l, bad
	}
	if l.Account != "" && checkContactEmail(l.Account) != nil {
		return l, bad
	}
	if l.SyncHash != "" && !contactSyncHashRe.MatchString(l.SyncHash) {
		return l, bad
	}
	return l, nil
}

// contactSyncHashRe is a SHA-256 in hex (spec 2.5 "Echo").
var contactSyncHashRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// PersonalContacts is implemented by Memory and Postgres. person is the
// session's own HUM-*; anything else is ErrNoPerson before any SQL.
// ErrNotFound: no such live contact of this person.
type PersonalContacts interface {
	// ListContacts is a page of the person's live contacts in created
	// order, those matching q.Q only: each word a prefix of the first
	// name, the last name or the email, case-insensitive, or a run of the
	// phone's digits for a word of digits (spec 2.3). B5's search and the
	// list route (B3) both read it.
	ListContacts(ctx context.Context, person string, q ContactQuery) (ContactPage, error)
	// ContactOf is one live contact.
	ContactOf(ctx context.Context, person, contactID string) (Contact, error)
	// CreateContact adds c's four values (the rest is ignored).
	// ErrContactEmpty with none; ErrNotFound: no such human.
	CreateContact(ctx context.Context, person string, c Contact, now time.Time) (Contact, error)
	// PatchContact changes the values p sets; ErrContactEmpty when none
	// would be left.
	PatchContact(ctx context.Context, person, contactID string, p ContactPatch, now time.Time) (Contact, error)
	// DeleteContact removes a live contact: by "" deletes the row, by
	// ContactDeletedByMember or ContactDeletedByGoogle soft-deletes it
	// (spec 2.6 "Erase one": soft only when a Google delete must be sent).
	DeleteContact(ctx context.Context, person, contactID, by string, now time.Time) error
	// ExportContacts is every live contact in created order (spec 2.6).
	ExportContacts(ctx context.Context, person string) ([]Contact, error)
	// EraseContacts deletes every row of the person, soft-deleted ones
	// too (spec 2.6, C8e); the rows removed.
	EraseContacts(ctx context.Context, person string) (int, error)
	// PurgeDeletedContacts deletes every person's rows soft-deleted before
	// before and names each such person once (spec 2.6 W4, C2e).
	PurgeDeletedContacts(ctx context.Context, before time.Time) ([]ContactPurged, error)
}

var (
	_ PersonalContacts = (*Memory)(nil)
	_ PersonalContacts = (*Postgres)(nil)
)

// checkContactName is a name within ContactNameMax characters of text.
func checkContactName(field, s string) error {
	if utf8.RuneCountInString(s) > ContactNameMax {
		return fmt.Errorf("%w: %s above %d characters", ErrRealmBad, field, ContactNameMax)
	}
	if !utf8.ValidString(s) || strings.ContainsRune(s, 0) {
		return fmt.Errorf("%w: %s is not valid text", ErrRealmBad, field)
	}
	return nil
}

// checkContactEmail is an address as rdb 0226 holds it (already cleaned).
func checkContactEmail(e string) error {
	n := utf8.RuneCountInString(e)
	at := strings.IndexByte(e, '@')
	if n < ContactEmailMin || n > ContactEmailMax || at <= 0 || at == len(e)-1 ||
		strings.ContainsAny(e, " \t\r\n\x00") || !utf8.ValidString(e) {
		return ErrContactBadEmail
	}
	return nil
}

// cleanContact trims the four values, lowercases the email (rdb 0226 holds
// it lowercased) and checks each, then that one is left.
func cleanContact(c Contact) (Contact, error) {
	c.FirstName, c.LastName = strings.TrimSpace(c.FirstName), strings.TrimSpace(c.LastName)
	c.Email, c.Phone = strings.ToLower(strings.TrimSpace(c.Email)), strings.TrimSpace(c.Phone)
	if err := checkContactName("first name", c.FirstName); err != nil {
		return c, err
	}
	if err := checkContactName("last name", c.LastName); err != nil {
		return c, err
	}
	if c.Email != "" {
		if err := checkContactEmail(c.Email); err != nil {
			return c, err
		}
	}
	if c.Phone != "" && !contactPhoneRe.MatchString(c.Phone) {
		return c, ErrContactBadPhone
	}
	if c.FirstName == "" && c.LastName == "" && c.Email == "" && c.Phone == "" {
		return c, ErrContactEmpty
	}
	return c, nil
}

// patchedContact is c with p applied, cleaned.
func patchedContact(c Contact, p ContactPatch) (Contact, error) {
	for _, f := range []struct{ to, from *string }{
		{&c.FirstName, p.FirstName}, {&c.LastName, p.LastName}, {&c.Email, p.Email}, {&c.Phone, p.Phone},
	} {
		if f.from != nil {
			*f.to = *f.from
		}
	}
	return cleanContact(c)
}

// checkContactIDs is checkPerson plus every id a uuid: a malformed id is a
// contact nobody holds.
func checkContactIDs(person string, ids ...string) error {
	if err := checkPerson(person); err != nil {
		return err
	}
	for _, id := range ids {
		if !isUUID(id) {
			return ErrNotFound
		}
	}
	return nil
}

// checkContactDeleter is DeleteContact's by.
func checkContactDeleter(by string) error {
	if by != "" && by != ContactDeletedByMember && by != ContactDeletedByGoogle {
		return fmt.Errorf("%w: unknown deleted_by", ErrRealmBad)
	}
	return nil
}

// contactWords is a query's first contactWordsMax words, lowercased.
func contactWords(q string) []string {
	w := strings.Fields(strings.ToLower(q))
	if len(w) > contactWordsMax {
		w = w[:contactWordsMax]
	}
	return w
}

// contactPhoneDigits is the phone with every non-digit removed.
func contactPhoneDigits(phone string) string {
	return strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, phone)
}

// contactMatches is the query rule of ListContacts on one contact; the
// Postgres statement (contactMatchSQL) is its twin.
func contactMatches(c Contact, words []string) bool {
	first, last := strings.ToLower(c.FirstName), strings.ToLower(c.LastName)
	for _, w := range words {
		hit := strings.HasPrefix(first, w) || strings.HasPrefix(last, w) || strings.HasPrefix(c.Email, w)
		if !hit && contactDigitsRe.MatchString(w) {
			hit = strings.Contains(contactPhoneDigits(c.Phone), w)
		}
		if !hit {
			return false
		}
	}
	return true
}

// contactPageLimit is q.Limit within 1..ContactsPageMax.
func contactPageLimit(q ContactQuery) int {
	if q.Limit <= 0 || q.Limit > ContactsPageMax {
		return ContactsPageMax
	}
	return q.Limit
}

// contactCursor is the opaque Next of a page ending at c: its created time
// in microseconds (Postgres's precision) and its id, the list's order.
func contactCursor(c Contact) string {
	return strconv.FormatInt(c.CreatedAt.UnixMicro(), 10) + "." + c.ID
}

// parseContactCursor reads a contactCursor; "" is the first page.
func parseContactCursor(s string) (at time.Time, id string, err error) {
	if s == "" {
		return time.Time{}, "", nil
	}
	us, rest, ok := strings.Cut(s, ".")
	n, perr := strconv.ParseInt(us, 10, 64)
	if !ok || perr != nil || !isUUID(rest) {
		return time.Time{}, "", fmt.Errorf("%w: a bad cursor", ErrRealmBad)
	}
	return time.UnixMicro(n).UTC(), rest, nil
}

// contactAfter reports whether c comes after the cursor (at, id).
func contactAfter(c Contact, at time.Time, id string) bool {
	if !c.CreatedAt.Equal(at) {
		return c.CreatedAt.After(at)
	}
	return c.ID > id
}

// contactTime is now as Postgres stores it, so both stores order alike.
func contactTime(now time.Time) time.Time { return now.UTC().Truncate(time.Microsecond) }
