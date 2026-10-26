package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Postgres contacts binding (contacts_sync.go). Member calls run in the
// workspace's scope and name (tenant_id, human_id) in every WHERE; the two
// calls that cannot name the workspace run under the operator scope.

const contactsSyncCols = `human_id, tenant_id, enabled, COALESCE(sync_token, ''), out_cursor, due_at,
	sync_lease_until, backoff_until, status_detail, last_synced_at, created_at, updated_at`

func scanContactsSync(r pgx.Row) (ContactsSync, error) {
	var b ContactsSync
	err := r.Scan(&b.Human, &b.Tenant, &b.Enabled, &b.SyncToken, &b.OutCursor, &b.DueAt,
		&b.SyncLeaseUntil, &b.BackoffUntil, &b.StatusDetail, &b.LastSyncedAt, &b.CreatedAt, &b.UpdatedAt)
	return b, err
}

// contactsSyncPGErr maps a missing row and a missing Google connection or
// seat (23503) to ErrNotFound, and the second binding (23505) to
// ErrContactsSyncElsewhere.
func contactsSyncPGErr(err error) error {
	switch {
	case errors.Is(err, pgx.ErrNoRows), sqlState(err) == "23503":
		return ErrNotFound
	case isUniqueViolation(err):
		return ErrContactsSyncElsewhere
	}
	return err
}

// ContactsSyncIn is ContactsSyncs.ContactsSyncIn.
func (s *Postgres) ContactsSyncIn(ctx context.Context, tenant, human string) (ContactsSync, error) {
	if err := checkPerson(human); err != nil {
		return ContactsSync{}, err
	}
	var out ContactsSync
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanContactsSync(tx.QueryRow(ctx, `SELECT `+contactsSyncCols+` FROM contacts_sync
			WHERE tenant_id = $1 AND human_id = $2`, tenant, human))
		return err
	})
	return out, contactsSyncPGErr(err)
}

// SetContactsSync is ContactsSyncs.SetContactsSync: an UPDATE, then a plain
// INSERT whose unique violation is the binding elsewhere. Never INSERT ...
// ON CONFLICT (human_id): against a row invisible from tenant that raises
// an RLS error, not 23505 (spec 2.2 step 3, seat note N5).
func (s *Postgres) SetContactsSync(ctx context.Context, tenant, human string, enabled bool, now time.Time) (ContactsSync, error) {
	if err := checkPerson(human); err != nil {
		return ContactsSync{}, err
	}
	var out ContactsSync
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanContactsSync(tx.QueryRow(ctx, `UPDATE contacts_sync
			SET enabled = $3, due_at = CASE WHEN $3 THEN $4 ELSE due_at END, updated_at = $4
			WHERE tenant_id = $1 AND human_id = $2 RETURNING `+contactsSyncCols, tenant, human, enabled, now))
		if !errors.Is(err, pgx.ErrNoRows) || !enabled {
			return err
		}
		out, err = scanContactsSync(tx.QueryRow(ctx, `INSERT INTO contacts_sync (human_id, tenant_id, due_at, created_at, updated_at)
			VALUES ($2, $1, $3, $3, $3) RETURNING `+contactsSyncCols, tenant, human, now))
		return err
	})
	return out, contactsSyncPGErr(err)
}

// MarkContactsSyncDue is ContactsSyncs.MarkContactsSyncDue.
func (s *Postgres) MarkContactsSyncDue(ctx context.Context, tenant, human string, now time.Time) error {
	if err := checkPerson(human); err != nil {
		return err
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var lease *time.Time
		if err := tx.QueryRow(ctx, `SELECT sync_lease_until FROM contacts_sync
			WHERE tenant_id = $1 AND human_id = $2 AND enabled FOR UPDATE`, tenant, human).Scan(&lease); err != nil {
			return err
		}
		if lease != nil && lease.After(now) {
			return ErrContactsSyncBusy
		}
		_, err := tx.Exec(ctx, `UPDATE contacts_sync SET due_at = $3, updated_at = $3
			WHERE tenant_id = $1 AND human_id = $2`, tenant, human, now)
		return err
	})
	return contactsSyncPGErr(err)
}

// ContactsSyncOf is ContactsSyncs.ContactsSyncOf, under the operator scope.
func (s *Postgres) ContactsSyncOf(ctx context.Context, human string) (ContactsSync, error) {
	if err := checkPerson(human); err != nil {
		return ContactsSync{}, err
	}
	var out ContactsSync
	found := false
	err := s.asOperatorQuery(ctx, `SELECT `+contactsSyncCols+` FROM contacts_sync WHERE human_id = $1`,
		[]any{human}, func(r pgx.Rows) error {
			var err error
			out, err = scanContactsSync(r)
			found = true
			return err
		})
	if err == nil && !found {
		err = ErrNotFound
	}
	return out, err
}

// MarkContactsPurgePending is ContactsSyncs.MarkContactsPurgePending, under
// the operator scope.
func (s *Postgres) MarkContactsPurgePending(ctx context.Context, persons []string, now time.Time) (int, error) {
	if err := checkContactsSyncPersons(persons); err != nil || len(persons) == 0 {
		return 0, err
	}
	var n int64
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE contacts_sync SET status_detail = $2, updated_at = $3
			WHERE human_id = ANY($1::text[])`, persons, ContactsPurgePendingDetail, now)
		n = tag.RowsAffected()
		return err
	})
	return int(n), err
}

// ClaimContactsSync is ContactsSyncs.ClaimContactsSync, under the operator
// scope: one UPDATE of the binding due longest whose Google connection is
// connected, SKIP LOCKED so two hub instances never claim the same row.
func (s *Postgres) ClaimContactsSync(ctx context.Context, now time.Time, lease time.Duration) (ContactsSync, ContactsLease, error) {
	until := gcalLeaseUntil(now, lease)
	var out ContactsSync
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = scanContactsSync(tx.QueryRow(ctx, `UPDATE contacts_sync SET sync_lease_until = $2
			WHERE human_id = (SELECT b.human_id FROM contacts_sync b
				JOIN gcal_connections g ON g.tenant_id = b.tenant_id AND g.human_id = b.human_id
				WHERE b.enabled AND b.due_at <= $1 AND g.status = 'connected'
					AND (b.sync_lease_until IS NULL OR b.sync_lease_until < $1)
					AND (b.backoff_until IS NULL OR b.backoff_until <= $1)
				ORDER BY b.due_at, b.human_id FOR UPDATE OF b SKIP LOCKED LIMIT 1)
			RETURNING `+contactsSyncCols, now, until))
		return err
	})
	if err != nil {
		return ContactsSync{}, ContactsLease{}, contactsSyncPGErr(err)
	}
	return out, ContactsLease{Tenant: out.Tenant, Human: out.Human, Until: *out.SyncLeaseUntil}, nil
}

// contactsFencedSet is one fenced UPDATE of the binding in its own
// workspace's scope: the WHERE matches only while it still holds lease l
// ($1 tenant, $2 human, $3 the token), set's own arguments from $4 on; no
// row matched is ErrContactsLeaseLost (as gcalFenced, spec 2.5).
func (s *Postgres) contactsFencedSet(ctx context.Context, l ContactsLease, set string, args ...any) error {
	if !contactsLeaseOK(l) {
		return ErrContactsLeaseLost
	}
	return s.inTenant(ctx, l.Tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE contacts_sync SET `+set+`
			WHERE tenant_id = $1 AND human_id = $2 AND sync_lease_until = $3`,
			append([]any{l.Tenant, l.Human, l.Until}, args...)...)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrContactsLeaseLost
		}
		return err
	})
}

// RenewContactsLease is ContactsSyncs.RenewContactsLease.
func (s *Postgres) RenewContactsLease(ctx context.Context, l ContactsLease, now time.Time, lease time.Duration) (ContactsLease, error) {
	next := l
	next.Until = gcalLeaseUntil(now, lease)
	return next, s.contactsFencedSet(ctx, l, `sync_lease_until = $4`, next.Until)
}

// SetContactsBackoff is ContactsSyncs.SetContactsBackoff.
func (s *Postgres) SetContactsBackoff(ctx context.Context, l ContactsLease, until *time.Time, detail string, now time.Time) error {
	if !contactsDetailOK(detail) {
		return ErrContactsSyncBad
	}
	return s.contactsFencedSet(ctx, l, `backoff_until = $4, status_detail = $5, updated_at = $6`, until, detail, now)
}

// FinishContactsSync is ContactsSyncs.FinishContactsSync.
func (s *Postgres) FinishContactsSync(ctx context.Context, l ContactsLease, d ContactsSyncDone, now time.Time) error {
	return s.contactsFencedSet(ctx, l, `sync_token = nullif($4, ''), out_cursor = coalesce($5, out_cursor),
		last_synced_at = $6, due_at = $7, sync_lease_until = NULL, updated_at = $6`,
		d.SyncToken, d.OutCursor, now, d.NextDue)
}
