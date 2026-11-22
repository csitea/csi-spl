package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
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

// The limits of rdb 0265's CHECKs (spec 154 v1.3 sections 11.3, 11.4).
const (
	ContactCompanyMax  = 200 // company, in characters
	ContactJobTitleMax = 200 // job_title, in characters
	ContactNotesMax    = 8000
	ContactPhotoMax    = 64 << 10 // one picture, in bytes
)

// The deleted_by values of rdb 0226.
const (
	ContactDeletedByMember = "member"
	ContactDeletedByGoogle = "google-sync"
)

// The value errors, each an ErrRealmBad; the hub answers contact_empty,
// bad_email, bad_phone, too_long and bad_birthday (spec 4, 11.3).
var (
	ErrContactTooLong     = fmt.Errorf("%w: a value is over its cap", ErrRealmBad)
	ErrContactBadBirthday = fmt.Errorf("%w: the birthday is not a date", ErrRealmBad)
	ErrContactPhotoBad    = fmt.Errorf("%w: a bad picture", ErrRealmBad)
	ErrContactEmpty       = fmt.Errorf("%w: a contact needs a name, an email or a phone", ErrRealmBad)
	ErrContactBadEmail    = fmt.Errorf("%w: the email is not an address", ErrRealmBad)
	ErrContactBadPhone    = fmt.Errorf("%w: the phone is not a phone number", ErrRealmBad)
)

// contactPhoneRe is rdb 0226's phone CHECK: what people type, not E.164.
var contactPhoneRe = regexp.MustCompile(`^[+0-9 ().-]{3,40}$`)

// contactDigitsRe is a query word of digits only, matched against the phone
// with its spaces and punctuation removed (spec 2.3, C10b).
var contactDigitsRe = regexp.MustCompile(`^[0-9]+$`)

// contactBirthdayRe is rdb 0265's birthday CHECK: YYYY-MM-DD or --MM-DD.
var contactBirthdayRe = regexp.MustCompile(`^([0-9]{4}-|--)[0-9]{2}-[0-9]{2}$`)

// Contact is one live personal.contacts row. Email, Phone and Birthday "" =
// NULL. GoogleAccount and GoogleResource are both set or both "" (linked to
// Google under that account, spec 2.5). InOnly (spec 11.3) is the sync's to
// set, never a write here's. PhotoSHA256 is its picture's hash, "" for none;
// the bytes are read only by ContactPhoto (spec 11.4).
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
	Company        string
	JobTitle       string
	Birthday       string
	Notes          string
	InOnly         bool
	PhotoSHA256    string
}

// ContactPatch is a PATCH of a contact: nil fields are kept; "" clears one.
type ContactPatch struct {
	FirstName *string
	LastName  *string
	Email     *string
	Phone     *string
	Company   *string
	JobTitle  *string
	Birthday  *string
	Notes     *string
}

// ContactPhoto is one personal.contact_photos row. PutContactPhoto takes Mime,
// Bytes and SourceURLHash and computes the rest.
type ContactPhoto struct {
	Mime          string
	Bytes         []byte
	SHA256        string
	SourceURLHash string
	FetchedAt     time.Time
}

// ContactImportCounts is what became of an import's rows (spec 11.2.1). Add
// is the rows added by ImportContacts, or that PreviewContactsImport would add.
type ContactImportCounts struct {
	Add            int
	AlreadyThere   int
	DeletedHere    int
	FileDuplicates int
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
	// afterID continues a page inside one changed time: with since set,
	// a row changed exactly at since comes only when its id sorts after
	// afterID ("" = none of them), so a tie of more than ContactsCycleMax
	// rows (an import writes one time) is read whole, page by page.
	ContactsChangedSince(ctx context.Context, person string, since *time.Time, afterID string) ([]ContactOut, error)
	// LinkContact stores the Google link of a live contact, never its
	// updated_at (a link is no change to send). ErrConflict: another of
	// the person's contacts holds that link (rdb 0226 contacts_google).
	LinkContact(ctx context.Context, person, contactID string, l ContactLink) (Contact, error)
	// DropDeletedContact hard-deletes a soft-deleted contact once Google
	// confirmed its delete (spec 2.5 "Deletes"); ErrNotFound for a live one.
	DropDeletedContact(ctx context.Context, person, contactID string) error
	// ApplyGooglePeople is the In half of one page of Google people (spec
	// 2.5 "In", 11.2.2, 11.3; build row B8 amended): one transaction, under
	// the import's lock (B14's, so an import beside the sync adds a row
	// once), the match of planGooglePeople, then each insert, patch, link
	// and soft delete.
	ApplyGooglePeople(ctx context.Context, person string, a GoogleApply, people []GooglePerson, now time.Time) (GoogleApplied, error)
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
	// CreateContact adds c's values (the link, InOnly and the picture are ignored).
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
	// ImportContacts adds the rows that match nothing the person holds, all
	// or none (spec 11.2): a row that fails CleanContact refuses the whole
	// call, so the caller drops and reports those first. Two imports at once
	// add a row once. The match rule is contactImportKey.
	ImportContacts(ctx context.Context, person string, rows []Contact, now time.Time) (ContactImportCounts, error)
	// PreviewContactsImport is ImportContacts' counts, writing nothing.
	PreviewContactsImport(ctx context.Context, person string, rows []Contact) (ContactImportCounts, error)
	// PutContactPhoto stores or replaces a live contact's picture, never its
	// updated_at (a picture is not sent to Google, spec 11.4).
	PutContactPhoto(ctx context.Context, person, contactID string, p ContactPhoto, now time.Time) (ContactPhoto, error)
	// ContactPhoto is a live contact's picture; ErrNotFound for none.
	ContactPhoto(ctx context.Context, person, contactID string) (ContactPhoto, error)
	// DeleteContactPhoto removes a live contact's picture; ErrNotFound for none.
	DeleteContactPhoto(ctx context.Context, person, contactID string) error
	// CountContactPhotos is every picture the person's rows hold, those of
	// soft-deleted contacts too: what contacts.photo_max_per_person caps.
	CountContactPhotos(ctx context.Context, person string) (int, error)
}

var (
	_ PersonalContacts = (*Memory)(nil)
	_ PersonalContacts = (*Postgres)(nil)
)

// checkContactText is text within max characters.
func checkContactText(field, s string, max int) error {
	if utf8.RuneCountInString(s) > max {
		return fmt.Errorf("%w: %s above %d characters", ErrContactTooLong, field, max)
	}
	if !utf8.ValidString(s) || strings.ContainsRune(s, 0) {
		return fmt.Errorf("%w: %s is not valid text", ErrRealmBad, field)
	}
	return nil
}

// checkContactBirthday is a real date, YYYY-MM-DD or --MM-DD, or "".
func checkContactBirthday(b string) error {
	if b == "" {
		return nil
	}
	if !contactBirthdayRe.MatchString(b) {
		return ErrContactBadBirthday
	}
	if strings.HasPrefix(b, "--") {
		b = "2000" + b[1:] // a leap year: --02-29 is a birthday
	}
	if _, err := time.Parse("2006-01-02", b); err != nil {
		return ErrContactBadBirthday
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

// CleanContact is what every write does to a contact's values: B15's import
// sorts a file's rows with it, by the error, before ImportContacts.
func CleanContact(c Contact) (Contact, error) { return cleanContact(c) }

// cleanContact trims the values, lowercases the email (rdb 0226 holds it
// lowercased) and checks each, then that one of the four is left (a company
// alone is not a contact, spec 11.3).
func cleanContact(c Contact) (Contact, error) {
	c.FirstName, c.LastName = strings.TrimSpace(c.FirstName), strings.TrimSpace(c.LastName)
	c.Email, c.Phone = strings.ToLower(strings.TrimSpace(c.Email)), strings.TrimSpace(c.Phone)
	c.Company, c.JobTitle = strings.TrimSpace(c.Company), strings.TrimSpace(c.JobTitle)
	c.Birthday, c.Notes = strings.TrimSpace(c.Birthday), strings.TrimSpace(c.Notes)
	for _, f := range []struct {
		field, value string
		max          int
	}{
		{"first name", c.FirstName, ContactNameMax},
		{"last name", c.LastName, ContactNameMax},
		{"company", c.Company, ContactCompanyMax},
		{"job title", c.JobTitle, ContactJobTitleMax},
		{"notes", c.Notes, ContactNotesMax},
	} {
		if err := checkContactText(f.field, f.value, f.max); err != nil {
			return c, err
		}
	}
	if err := checkContactBirthday(c.Birthday); err != nil {
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
		{&c.Company, p.Company}, {&c.JobTitle, p.JobTitle}, {&c.Birthday, p.Birthday}, {&c.Notes, p.Notes},
	} {
		if f.from != nil {
			*f.to = *f.from
		}
	}
	return cleanContact(c)
}

// cleanContactRows is cleanContact of every row of an import; the error names
// the row, never a value.
func cleanContactRows(rows []Contact) ([]Contact, error) {
	out := make([]Contact, 0, len(rows))
	for i, r := range rows {
		c, err := cleanContact(r)
		if err != nil {
			return nil, fmt.Errorf("row %d: %w", i+1, err)
		}
		out = append(out, c)
	}
	return out, nil
}

// contactPhoneKey is a phone's key in the import's match: its digits, so one
// number written two ways is one number; the text when it has no digit.
func contactPhoneKey(phone string) string {
	if d := contactPhoneDigits(phone); d != "" {
		return "p\x00" + d
	}
	return "p\x00" + phone
}

// contactImportKey is the import's match rule (spec 11.2) on a cleaned
// contact: the email; else with no email the first and last name, as the
// operator's seed; else with neither the phone.
func contactImportKey(c Contact) string {
	switch {
	case c.Email != "":
		return "e\x00" + c.Email
	case c.FirstName != "" || c.LastName != "":
		return "n\x00" + c.FirstName + "\x00" + c.LastName
	}
	return contactPhoneKey(c.Phone)
}

// contactsHeld is every key a person's rows answer to, true when a live
// contact holds it, false when only a soft-deleted one does.
type contactsHeld map[string]bool

// add records c's keys: contactImportKey, and its phone too, because a row
// with only a phone matches any contact with that number.
func (h contactsHeld) add(c Contact, live bool) {
	k := contactImportKey(c)
	h[k] = h[k] || live
	if c.Phone != "" {
		p := contactPhoneKey(c.Phone)
		h[p] = h[p] || live
	}
}

// matchContactImport is both stores' one matcher: the rows to add and the
// counts. A row repeating an earlier row of the file is a file duplicate
// first; a live match wins over a soft-deleted one.
func matchContactImport(rows []Contact, held contactsHeld) ([]Contact, ContactImportCounts) {
	var n ContactImportCounts
	add := []Contact{}
	seen := contactsHeld{}
	for _, r := range rows {
		k := contactImportKey(r)
		if _, dup := seen[k]; dup {
			n.FileDuplicates++
			continue
		}
		seen.add(r, true)
		live, there := held[k]
		switch {
		case there && live:
			n.AlreadyThere++
		case there:
			n.DeletedHere++
		default:
			add = append(add, r)
		}
	}
	n.Add = len(add)
	return add, n
}

// cleanContactPhoto checks p against rdb 0265 and computes its hash. The
// magic bytes are the fetcher's (B16): mime here is only the column's rule.
func cleanContactPhoto(p ContactPhoto) (ContactPhoto, error) {
	switch p.Mime {
	case "image/png", "image/jpeg", "image/webp":
	default:
		return p, ErrContactPhotoBad
	}
	if len(p.Bytes) < 1 || len(p.Bytes) > ContactPhotoMax || !contactSyncHashRe.MatchString(p.SourceURLHash) {
		return p, ErrContactPhotoBad
	}
	sum := sha256.Sum256(p.Bytes)
	p.SHA256 = hex.EncodeToString(sum[:])
	return p, nil
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

// GooglePerson is one person of a Google list, mapped to Spool's values by
// the sync (spec 11.3): Values holds the eight values and InOnly (a value
// was cut at its cap). UpdatedAt is Google's update time of the person, zero
// when Google gave none (then a tie, which Spool wins).
type GooglePerson struct {
	Resource  string
	ETag      string
	Deleted   bool
	Values    Contact
	UpdatedAt time.Time
}

// GoogleApply is how a page is applied: the bound account the contacts are
// linked under, and NoDeletes for the first sync of a binding and for the
// full list after an expired sync token (spec 2.5: never deletes).
type GoogleApply struct {
	Account   string
	NoDeletes bool
}

// GoogleApplied counts what a page did. SpoolKept: a contact edited on both
// sides that Spool wins (its etag stored, the Out half sends it).
// OtherAccount: the person's live contacts linked under another account
// after the page (the binding moved account, C23d).
type GoogleApplied struct {
	Added, Linked, Updated, Deleted, SpoolKept, Unchanged, Skipped int
	OtherAccount                                                   int
}

// ContactSyncHash is the echo hash of spec 11.2.2: SHA-256 over the eight
// text values of 11.3, joined by newlines (cleaned values, as stored).
func ContactSyncHash(c Contact) string {
	sum := sha256.Sum256([]byte(strings.Join([]string{c.FirstName, c.LastName, c.Email, c.Phone,
		c.Company, c.JobTitle, c.Birthday, c.Notes}, "\n")))
	return hex.EncodeToString(sum[:])
}

// The kinds of a planned In-half write.
const (
	googleOpInsert = iota + 1 // a new contact, linked
	googleOpUpdate            // Google's values over a live contact, linked; updated_at = now
	googleOpLink              // the link only (etag, hash); updated_at kept: nothing to send
	googleOpDelete            // soft delete, deleted_by google-sync
)

// googleOp is one planned write of ApplyGooglePeople.
type googleOp struct {
	kind   int
	id     string // "" for an insert
	values Contact
	link   ContactLink
}

// planGooglePeople is both stores' one In-half rule (spec 2.5 "In",
// "Conflicts", "Deletes"; 11.3), on the person's rows (soft-deleted ones
// too), which it updates as it plans so a page is matched against itself:
//
//   - linked under the account and soft-deleted in Spool: nothing (a
//     delete wins on either side; a member's delete is the Out half's);
//   - linked, deleted at Google or left with none of the four: soft
//     deleted, unless a.NoDeletes;
//   - linked, the same hash: nothing, the new etag stored (echo);
//   - linked, Spool's values changed since its hash and Google's time not
//     after Spool's: Spool wins, the etag stored, the Out half sends it;
//   - linked, else: Google's values;
//   - not linked: the oldest live contact with the email that is not
//     linked under the account is linked (the newer side's values win),
//     else a new contact; a deleted or empty person is nothing.
func planGooglePeople(rows []*ContactOut, a GoogleApply, people []GooglePerson) ([]googleOp, GoogleApplied) {
	var ops []googleOp
	var n GoogleApplied
	for _, p := range people {
		vals, err := cleanContact(p.Values)
		empty := errors.Is(err, ErrContactEmpty)
		if err != nil && !empty {
			n.Skipped++
			continue
		}
		vals.InOnly = p.Values.InOnly
		link, lerr := cleanContactLink(ContactLink{Account: a.Account, Resource: p.Resource, ETag: p.ETag,
			SyncHash: ContactSyncHash(vals)})
		if lerr != nil || p.Resource == "" {
			n.Skipped++
			continue
		}
		r := linkedRow(rows, a.Account, p.Resource)
		op, count := planGooglePerson(rows, r, a, p, vals, link, p.Deleted || empty)
		*count(&n)++
		if op.kind == googleOpInsert { // a later person of the page matches it
			row := &ContactOut{}
			setGoogleRow(row, vals, link)
			rows = append(rows, row)
		}
		if op.kind != 0 {
			ops = append(ops, op)
		}
	}
	for _, r := range rows {
		if r.DeletedAt == nil && r.GoogleAccount != "" && r.GoogleAccount != a.Account {
			n.OtherAccount++
		}
	}
	return ops, n
}

// planGooglePerson plans one person against its linked row r (nil: none)
// and answers the counter it adds to.
func planGooglePerson(rows []*ContactOut, r *ContactOut, a GoogleApply, p GooglePerson, vals Contact,
	link ContactLink, gone bool) (googleOp, func(*GoogleApplied) *int) {
	unchanged := func(n *GoogleApplied) *int { return &n.Unchanged }
	switch {
	case r != nil && r.DeletedAt != nil:
		return googleOp{}, unchanged
	case r != nil && gone:
		if a.NoDeletes {
			return googleOp{}, unchanged
		}
		r.DeletedAt = &p.UpdatedAt
		return googleOp{kind: googleOpDelete, id: r.ID}, func(n *GoogleApplied) *int { return &n.Deleted }
	case r != nil && link.SyncHash == r.SyncHash:
		if p.ETag == r.GoogleETag {
			return googleOp{}, unchanged
		}
		r.GoogleETag = p.ETag
		return googleOp{kind: googleOpLink, id: r.ID, link: link}, unchanged
	case r != nil && ContactSyncHash(r.Contact) != r.SyncHash && !p.UpdatedAt.After(r.UpdatedAt):
		link.SyncHash, r.GoogleETag = r.SyncHash, p.ETag
		return googleOp{kind: googleOpLink, id: r.ID, link: link}, func(n *GoogleApplied) *int { return &n.SpoolKept }
	case r != nil:
		setGoogleRow(r, vals, link)
		return googleOp{kind: googleOpUpdate, id: r.ID, values: vals, link: link}, func(n *GoogleApplied) *int { return &n.Updated }
	case gone:
		return googleOp{}, unchanged
	}
	linked := func(n *GoogleApplied) *int { return &n.Linked }
	if m := emailRow(rows, a.Account, vals.Email); m != nil {
		if m.UpdatedAt.After(p.UpdatedAt) { // Spool's values: no hash, so the Out half sends them
			m.GoogleAccount, m.GoogleResource, m.GoogleETag, m.SyncHash = link.Account, link.Resource, link.ETag, ""
			link.SyncHash = ""
			return googleOp{kind: googleOpLink, id: m.ID, link: link}, linked
		}
		setGoogleRow(m, vals, link)
		return googleOp{kind: googleOpUpdate, id: m.ID, values: vals, link: link}, linked
	}
	return googleOp{kind: googleOpInsert, values: vals, link: link}, func(n *GoogleApplied) *int { return &n.Added }
}

// setGoogleRow is r after Google's values and link are written.
func setGoogleRow(r *ContactOut, vals Contact, link ContactLink) {
	id, created, updated := r.ID, r.CreatedAt, r.UpdatedAt
	r.Contact = vals
	r.ID, r.CreatedAt, r.UpdatedAt = id, created, updated
	r.GoogleAccount, r.GoogleResource, r.GoogleETag, r.SyncHash = link.Account, link.Resource, link.ETag, link.SyncHash
}

// linkedRow is the row linked under (account, resource), soft-deleted
// included, or nil.
func linkedRow(rows []*ContactOut, account, resource string) *ContactOut {
	for _, r := range rows {
		if r.GoogleAccount == account && r.GoogleResource == resource {
			return r
		}
	}
	return nil
}

// emailRow is the oldest live row with email that is not linked under
// account (spec 2.5 "Deletes", C20b), or nil.
func emailRow(rows []*ContactOut, account, email string) *ContactOut {
	if email == "" {
		return nil
	}
	var best *ContactOut
	for _, r := range rows {
		if r.DeletedAt != nil || r.Email != email || r.GoogleAccount == account || r.ID == "" {
			continue
		}
		if best == nil || r.CreatedAt.Before(best.CreatedAt) || (r.CreatedAt.Equal(best.CreatedAt) && r.ID < best.ID) {
			best = r
		}
	}
	return best
}

// checkGoogleApply is checkPerson plus a bound account rdb 0226 holds.
func checkGoogleApply(person string, a GoogleApply) (GoogleApply, error) {
	if err := checkPerson(person); err != nil {
		return a, err
	}
	a.Account = strings.ToLower(strings.TrimSpace(a.Account))
	if checkContactEmail(a.Account) != nil {
		return a, fmt.Errorf("%w: a bad Google account", ErrRealmBad)
	}
	return a, nil
}

// contactChangedAfter is the out read's keyset: changed after since, or at
// since with an id after afterID ("" = none at since).
func contactChangedAfter(changed time.Time, id string, since *time.Time, afterID string) bool {
	if since == nil || changed.After(*since) {
		return true
	}
	return afterID != "" && changed.Equal(*since) && id > afterID
}
