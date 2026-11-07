package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Postgres side of the contacts store (personal_contacts.go): every
// person call in inPerson, so rdb 0226's person_scope policy binds it to the
// session's own person, and every statement still names person_id (the
// policy is the second lock, not the only one). PurgeDeletedContacts is the
// one statement with no person: rdb 0226's door in a plain transaction.

const contactCols = `contact_id::text, first_name, last_name, COALESCE(email, ''), COALESCE(phone, ''),
	COALESCE(google_account, ''), COALESCE(google_resource, ''), created_at, updated_at,
	company, job_title, COALESCE(birthday, ''), notes, in_only,
	COALESCE((SELECT p.sha256 FROM personal.contact_photos p WHERE p.contact_id = personal.contacts.contact_id), '')`

// contactMatchSQL is contactMatches over the escaped query words in $2: no
// word misses the first name, the last name, the email and (for a word of
// digits) the phone's digits.
const contactMatchSQL = `NOT EXISTS (SELECT 1 FROM unnest($2::text[]) AS w(word) WHERE NOT (
		lower(first_name) LIKE w.word || '%' OR lower(last_name) LIKE w.word || '%'
		OR COALESCE(email, '') LIKE w.word || '%'
		OR (w.word ~ '^[0-9]+$' AND strpos(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g'), w.word) > 0)))`

// contactDests is where a contactCols row scans to.
func contactDests(c *Contact) []any {
	return []any{&c.ID, &c.FirstName, &c.LastName, &c.Email, &c.Phone, &c.GoogleAccount, &c.GoogleResource,
		&c.CreatedAt, &c.UpdatedAt, &c.Company, &c.JobTitle, &c.Birthday, &c.Notes, &c.InOnly, &c.PhotoSHA256}
}

func scanContact(r pgx.Row) (Contact, error) {
	var c Contact
	err := r.Scan(contactDests(&c)...)
	return c, err
}

// contactPGErr is realmPGErr, plus a missing row as ErrNotFound.
func contactPGErr(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return realmPGErr(err)
}

// likeEscaped is each word with LIKE's \, % and _ escaped (the default
// escape character is the backslash), never nil: pgx sends nil as NULL.
func likeEscaped(words []string) []string {
	out := make([]string, 0, len(words))
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	for _, w := range words {
		out = append(out, r.Replace(w))
	}
	return out
}

// nilEmpty is "" as NULL, for email and phone.
func nilEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// eachContact appends every row of a contactCols query to out.
func eachContact(ctx context.Context, tx pgx.Tx, sql string, args []any, out *[]Contact) error {
	return eachRow(ctx, tx, sql, args, func(r pgx.Rows) error {
		c, err := scanContact(r)
		*out = append(*out, c)
		return err
	})
}

// ListContacts is PersonalContacts.ListContacts.
func (s *Postgres) ListContacts(ctx context.Context, person string, q ContactQuery) (ContactPage, error) {
	at, after, err := parseContactCursor(q.After)
	if err != nil {
		return ContactPage{}, err
	}
	var atArg, afterArg any
	if after != "" {
		atArg, afterArg = at, after
	}
	limit := contactPageLimit(q)
	var rows []Contact
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		return eachContact(ctx, tx, `SELECT `+contactCols+` FROM personal.contacts
			WHERE person_id = $1 AND deleted_at IS NULL AND `+contactMatchSQL+`
			  AND ($3::timestamptz IS NULL OR (created_at, contact_id) > ($3::timestamptz, $4::uuid))
			ORDER BY created_at, contact_id LIMIT $5`,
			[]any{person, likeEscaped(contactWords(q.Q)), atArg, afterArg, limit + 1}, &rows)
	})
	if err != nil {
		return ContactPage{}, err
	}
	return contactPageOf(rows, limit), nil
}

// contactPageOf is the first limit rows, with a Next when one more was read.
func contactPageOf(rows []Contact, limit int) ContactPage {
	p := ContactPage{Contacts: rows}
	if len(rows) > limit {
		p.Contacts = rows[:limit]
		p.Next = contactCursor(rows[limit-1])
	}
	if p.Contacts == nil {
		p.Contacts = []Contact{}
	}
	return p
}

// contactTx is one live contact inside the caller's transaction; lock takes
// its row for an update.
func contactTx(ctx context.Context, tx pgx.Tx, person, contactID string, lock bool) (Contact, error) {
	sql := `SELECT ` + contactCols + ` FROM personal.contacts
		WHERE person_id = $1 AND contact_id = $2::uuid AND deleted_at IS NULL`
	if lock {
		sql += ` FOR UPDATE`
	}
	c, err := scanContact(tx.QueryRow(ctx, sql, person, contactID))
	return c, contactPGErr(err)
}

// ContactOf is PersonalContacts.ContactOf.
func (s *Postgres) ContactOf(ctx context.Context, person, contactID string) (Contact, error) {
	if err := checkContactIDs(person, contactID); err != nil {
		return Contact{}, err
	}
	var out Contact
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		var err error
		out, err = contactTx(ctx, tx, person, contactID, false)
		return err
	})
	return out, err
}

// CreateContact is PersonalContacts.CreateContact.
func (s *Postgres) CreateContact(ctx context.Context, person string, c Contact, now time.Time) (Contact, error) {
	if err := checkPerson(person); err != nil {
		return Contact{}, err
	}
	c, err := cleanContact(c)
	if err != nil {
		return Contact{}, err
	}
	var out Contact
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		var err error
		out, err = scanContact(tx.QueryRow(ctx, `
			INSERT INTO personal.contacts (person_id, first_name, last_name, email, phone, created_at, updated_at,
				company, job_title, birthday, notes)
			VALUES ($1, $2, $3, $4, $5, $6, $6, $7, $8, $9, $10) RETURNING `+contactCols,
			person, c.FirstName, c.LastName, nilEmpty(c.Email), nilEmpty(c.Phone), contactTime(now),
			c.Company, c.JobTitle, nilEmpty(c.Birthday), c.Notes))
		return err
	})
	return out, contactPGErr(err)
}

// PatchContact is PersonalContacts.PatchContact.
func (s *Postgres) PatchContact(ctx context.Context, person, contactID string, p ContactPatch, now time.Time) (Contact, error) {
	if err := checkContactIDs(person, contactID); err != nil {
		return Contact{}, err
	}
	var out Contact
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		cur, err := contactTx(ctx, tx, person, contactID, true)
		if err != nil {
			return err
		}
		next, err := patchedContact(cur, p)
		if err != nil {
			return err
		}
		out, err = scanContact(tx.QueryRow(ctx, `
			UPDATE personal.contacts SET first_name = $3, last_name = $4, email = $5, phone = $6, updated_at = $7,
				company = $8, job_title = $9, birthday = $10, notes = $11
			WHERE person_id = $1 AND contact_id = $2::uuid AND deleted_at IS NULL RETURNING `+contactCols,
			person, contactID, next.FirstName, next.LastName, nilEmpty(next.Email), nilEmpty(next.Phone), contactTime(now),
			next.Company, next.JobTitle, nilEmpty(next.Birthday), next.Notes))
		return err
	})
	return out, contactPGErr(err)
}

// DeleteContact is PersonalContacts.DeleteContact.
func (s *Postgres) DeleteContact(ctx context.Context, person, contactID, by string, now time.Time) error {
	if err := checkContactIDs(person, contactID); err != nil {
		return err
	}
	if err := checkContactDeleter(by); err != nil {
		return err
	}
	return s.inPerson(ctx, person, func(tx pgx.Tx) error {
		sql := `DELETE FROM personal.contacts WHERE person_id = $1 AND contact_id = $2::uuid AND deleted_at IS NULL`
		args := []any{person, contactID}
		if by != "" {
			sql = `UPDATE personal.contacts SET deleted_at = $3, deleted_by = $4
				WHERE person_id = $1 AND contact_id = $2::uuid AND deleted_at IS NULL`
			args = append(args, contactTime(now), by)
		}
		tag, err := tx.Exec(ctx, sql, args...)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrNotFound
		}
		return err
	})
}

// ExportContacts is PersonalContacts.ExportContacts.
func (s *Postgres) ExportContacts(ctx context.Context, person string) ([]Contact, error) {
	out := []Contact{}
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		return eachContact(ctx, tx, `SELECT `+contactCols+` FROM personal.contacts
			WHERE person_id = $1 AND deleted_at IS NULL ORDER BY created_at, contact_id`, []any{person}, &out)
	})
	return out, err
}

// EraseContacts is PersonalContacts.EraseContacts.
func (s *Postgres) EraseContacts(ctx context.Context, person string) (int, error) {
	var n int64
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM personal.contacts WHERE person_id = $1`, person)
		n = tag.RowsAffected()
		return err
	})
	return int(n), err
}

// PurgeDeletedContacts is PersonalContacts.PurgeDeletedContacts: rdb 0226's
// door, in a plain pool transaction with no app.* setting. The door's own
// policies (TO spool_realm_contacts_purger, soft-deleted rows only) need
// none, and the operator scope would read no contact (spec 2.6 W4).
func (s *Postgres) PurgeDeletedContacts(ctx context.Context, before time.Time) ([]ContactPurged, error) {
	out := []ContactPurged{}
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT person_id, pending_google FROM personal.purge_deleted_contacts($1)`,
			[]any{before.UTC()}, func(r pgx.Rows) error {
				var p ContactPurged
				err := r.Scan(&p.Person, &p.PendingGoogle)
				out = append(out, p)
				return err
			})
	})
	return out, err
}

// contactOutCols is contactCols plus the cycle's columns (ContactOut).
const contactOutCols = contactCols + `, google_etag, COALESCE(sync_hash, ''), deleted_at,
	GREATEST(updated_at, COALESCE(deleted_at, updated_at))`

// ContactsChangedSince is ContactsCycle.ContactsChangedSince.
func (s *Postgres) ContactsChangedSince(ctx context.Context, person string, since *time.Time) ([]ContactOut, error) {
	out := []ContactOut{}
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT `+contactOutCols+` FROM personal.contacts
			WHERE person_id = $1 AND (deleted_at IS NULL OR deleted_by = 'member')
			  AND ($2::timestamptz IS NULL OR GREATEST(updated_at, COALESCE(deleted_at, updated_at)) > $2::timestamptz)
			ORDER BY GREATEST(updated_at, COALESCE(deleted_at, updated_at)), contact_id LIMIT $3`,
			[]any{person, since, ContactsCycleMax}, func(r pgx.Rows) error {
				var c ContactOut
				err := r.Scan(append(contactDests(&c.Contact), &c.GoogleETag, &c.SyncHash, &c.DeletedAt, &c.ChangedAt)...)
				out = append(out, c)
				return err
			})
	})
	return out, err
}

// LinkContact is ContactsCycle.LinkContact.
func (s *Postgres) LinkContact(ctx context.Context, person, contactID string, l ContactLink) (Contact, error) {
	if err := checkContactIDs(person, contactID); err != nil {
		return Contact{}, err
	}
	l, err := cleanContactLink(l)
	if err != nil {
		return Contact{}, err
	}
	var out Contact
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		var err error
		out, err = scanContact(tx.QueryRow(ctx, `UPDATE personal.contacts
			SET google_account = $3, google_resource = $4, google_etag = $5, sync_hash = $6
			WHERE person_id = $1 AND contact_id = $2::uuid AND deleted_at IS NULL RETURNING `+contactCols,
			person, contactID, nilEmpty(l.Account), nilEmpty(l.Resource), l.ETag, nilEmpty(l.SyncHash)))
		return err
	})
	if isUniqueViolation(err) { // rdb 0226 contacts_google
		return Contact{}, ErrConflict
	}
	return out, contactPGErr(err)
}

// DropDeletedContact is ContactsCycle.DropDeletedContact.
func (s *Postgres) DropDeletedContact(ctx context.Context, person, contactID string) error {
	if err := checkContactIDs(person, contactID); err != nil {
		return err
	}
	return s.inPerson(ctx, person, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM personal.contacts
			WHERE person_id = $1 AND contact_id = $2::uuid AND deleted_at IS NOT NULL`, person, contactID)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrNotFound
		}
		return err
	})
}

// contactsHeldTx is the person's keys, soft-deleted rows included.
func contactsHeldTx(ctx context.Context, tx pgx.Tx, person string) (contactsHeld, error) {
	held := contactsHeld{}
	err := eachRow(ctx, tx, `SELECT COALESCE(email, ''), first_name, last_name, COALESCE(phone, ''), deleted_at IS NULL
		FROM personal.contacts WHERE person_id = $1`, []any{person}, func(r pgx.Rows) error {
		var c Contact
		var live bool
		if err := r.Scan(&c.Email, &c.FirstName, &c.LastName, &c.Phone, &live); err != nil {
			return err
		}
		held.add(c, live)
		return nil
	})
	return held, err
}

// importContactsTx is the import inside the caller's transaction, on cleaned
// rows: the lock (the seed's form, spl-contacts-seed.func.sh), the match, one
// INSERT of every new row.
func importContactsTx(ctx context.Context, tx pgx.Tx, person string, rows []Contact, now time.Time) (ContactImportCounts, error) {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('contacts-import:' || $1::text))`, person); err != nil {
		return ContactImportCounts{}, err
	}
	held, err := contactsHeldTx(ctx, tx, person)
	if err != nil {
		return ContactImportCounts{}, err
	}
	add, n := matchContactImport(rows, held)
	if len(add) == 0 {
		return n, nil
	}
	cols := make([][]string, 8)
	for _, c := range add {
		for i, v := range []string{c.FirstName, c.LastName, c.Email, c.Phone, c.Company, c.JobTitle, c.Birthday, c.Notes} {
			cols[i] = append(cols[i], v)
		}
	}
	_, err = tx.Exec(ctx, `INSERT INTO personal.contacts (person_id, first_name, last_name, email, phone,
			company, job_title, birthday, notes, created_at, updated_at)
		SELECT $1, f, l, NULLIF(e, ''), NULLIF(p, ''), co, jt, NULLIF(b, ''), n, $2, $2
		FROM unnest($3::text[], $4::text[], $5::text[], $6::text[], $7::text[], $8::text[], $9::text[], $10::text[])
			AS r(f, l, e, p, co, jt, b, n)`,
		person, contactTime(now), cols[0], cols[1], cols[2], cols[3], cols[4], cols[5], cols[6], cols[7])
	return n, err
}

// ImportContacts is PersonalContacts.ImportContacts.
func (s *Postgres) ImportContacts(ctx context.Context, person string, rows []Contact, now time.Time) (ContactImportCounts, error) {
	if err := checkPerson(person); err != nil {
		return ContactImportCounts{}, err
	}
	rows, err := cleanContactRows(rows)
	if err != nil {
		return ContactImportCounts{}, err
	}
	var n ContactImportCounts
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		var err error
		n, err = importContactsTx(ctx, tx, person, rows, now)
		return err
	})
	if err != nil {
		return ContactImportCounts{}, contactPGErr(err)
	}
	return n, nil
}

// PreviewContactsImport is PersonalContacts.PreviewContactsImport.
func (s *Postgres) PreviewContactsImport(ctx context.Context, person string, rows []Contact) (ContactImportCounts, error) {
	if err := checkPerson(person); err != nil {
		return ContactImportCounts{}, err
	}
	rows, err := cleanContactRows(rows)
	if err != nil {
		return ContactImportCounts{}, err
	}
	var n ContactImportCounts
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		held, err := contactsHeldTx(ctx, tx, person)
		_, n = matchContactImport(rows, held)
		return err
	})
	if err != nil {
		return ContactImportCounts{}, err
	}
	return n, nil
}

// contactPhotoCols is a ContactPhoto row, in contactPhotoDests' order.
const contactPhotoCols = `mime, bytes, sha256, source_url_hash, fetched_at`

// contactPhotoDests is where a contactPhotoCols row scans to.
func contactPhotoDests(p *ContactPhoto) []any {
	return []any{&p.Mime, &p.Bytes, &p.SHA256, &p.SourceURLHash, &p.FetchedAt}
}

// PutContactPhoto is PersonalContacts.PutContactPhoto. The live contact is
// read first: another person's id ends here, as not found. Past it, the
// answer differs by whether that id has a picture (42501 with one, 23503
// without), which would tell the caller.
func (s *Postgres) PutContactPhoto(ctx context.Context, person, contactID string, p ContactPhoto, now time.Time) (ContactPhoto, error) {
	if err := checkContactIDs(person, contactID); err != nil {
		return ContactPhoto{}, err
	}
	p, err := cleanContactPhoto(p)
	if err != nil {
		return ContactPhoto{}, err
	}
	var out ContactPhoto
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		if _, err := contactTx(ctx, tx, person, contactID, true); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `INSERT INTO personal.contact_photos
				(person_id, contact_id, mime, bytes, sha256, source_url_hash, fetched_at)
			VALUES ($1, $2::uuid, $3, $4, $5, $6, $7)
			ON CONFLICT (contact_id) DO UPDATE SET mime = EXCLUDED.mime, bytes = EXCLUDED.bytes,
				sha256 = EXCLUDED.sha256, source_url_hash = EXCLUDED.source_url_hash, fetched_at = EXCLUDED.fetched_at
			RETURNING `+contactPhotoCols,
			person, contactID, p.Mime, p.Bytes, p.SHA256, p.SourceURLHash, contactTime(now)).Scan(contactPhotoDests(&out)...)
	})
	return out, contactPGErr(err)
}

// ContactPhoto is PersonalContacts.ContactPhoto.
func (s *Postgres) ContactPhoto(ctx context.Context, person, contactID string) (ContactPhoto, error) {
	if err := checkContactIDs(person, contactID); err != nil {
		return ContactPhoto{}, err
	}
	var out ContactPhoto
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		if _, err := contactTx(ctx, tx, person, contactID, false); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT `+contactPhotoCols+` FROM personal.contact_photos
			WHERE person_id = $1 AND contact_id = $2::uuid`, person, contactID).Scan(contactPhotoDests(&out)...)
	})
	return out, contactPGErr(err)
}

// DeleteContactPhoto is PersonalContacts.DeleteContactPhoto.
func (s *Postgres) DeleteContactPhoto(ctx context.Context, person, contactID string) error {
	if err := checkContactIDs(person, contactID); err != nil {
		return err
	}
	return s.inPerson(ctx, person, func(tx pgx.Tx) error {
		if _, err := contactTx(ctx, tx, person, contactID, true); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `DELETE FROM personal.contact_photos WHERE person_id = $1 AND contact_id = $2::uuid`,
			person, contactID)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrNotFound
		}
		return err
	})
}

// CountContactPhotos is PersonalContacts.CountContactPhotos.
func (s *Postgres) CountContactPhotos(ctx context.Context, person string) (int, error) {
	var n int
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM personal.contact_photos WHERE person_id = $1`, person).Scan(&n)
	})
	return n, err
}
