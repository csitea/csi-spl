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
	COALESCE(google_account, ''), COALESCE(google_resource, ''), created_at, updated_at`

// contactMatchSQL is contactMatches over the escaped query words in $2: no
// word misses the first name, the last name, the email and (for a word of
// digits) the phone's digits.
const contactMatchSQL = `NOT EXISTS (SELECT 1 FROM unnest($2::text[]) AS w(word) WHERE NOT (
		lower(first_name) LIKE w.word || '%' OR lower(last_name) LIKE w.word || '%'
		OR COALESCE(email, '') LIKE w.word || '%'
		OR (w.word ~ '^[0-9]+$' AND strpos(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g'), w.word) > 0)))`

func scanContact(r pgx.Row) (Contact, error) {
	var c Contact
	err := r.Scan(&c.ID, &c.FirstName, &c.LastName, &c.Email, &c.Phone, &c.GoogleAccount, &c.GoogleResource,
		&c.CreatedAt, &c.UpdatedAt)
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
			INSERT INTO personal.contacts (person_id, first_name, last_name, email, phone, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $6) RETURNING `+contactCols,
			person, c.FirstName, c.LastName, nilEmpty(c.Email), nilEmpty(c.Phone), contactTime(now)))
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
			UPDATE personal.contacts SET first_name = $3, last_name = $4, email = $5, phone = $6, updated_at = $7
			WHERE person_id = $1 AND contact_id = $2::uuid AND deleted_at IS NULL RETURNING `+contactCols,
			person, contactID, next.FirstName, next.LastName, nilEmpty(next.Email), nilEmpty(next.Phone), contactTime(now)))
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
