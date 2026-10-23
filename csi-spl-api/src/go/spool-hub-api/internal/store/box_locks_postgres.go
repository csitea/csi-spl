package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of box_locks.go (rdb 0213, spec 025 box owner lock, row B1).
// Every read and write runs in the workspace's own scope (rdb 0213's
// tenant_scope policy); the operator scope is the break-glass's only (row
// B6), never used here.

// ErrBoxLocksUnavailable: this database has no box_locks yet (rdb 0213 not
// applied). Reads answer "not locked", as before the lock existed.
var ErrBoxLocksUnavailable = errors.New("store: box locks need rdb 0213")

// hasBoxLocks is the catalogue probe for rdb 0213: the hub may roll before
// the migration reaches its database.
func (s *Postgres) hasBoxLocks(ctx context.Context) bool {
	return s.lockTab.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT to_regclass('box_locks') IS NOT NULL`).Scan(&ok)
		return ok, err
	}, s.now())
}

const boxLockCols = `tenant_id, box_id, lock_pubkey, box_pubkey, owners, peer_boxes, hide_posts, version,
	signed_body, signature, created_at, updated_at`

const boxLockSQL = `SELECT ` + boxLockCols + ` FROM box_locks WHERE tenant_id = $1 AND box_id = $2`

func boxLockDest(l *BoxLock) []any {
	return []any{&l.TenantID, &l.BoxID, &l.LockPubKey, &l.BoxPubKey, &l.Owners, &l.PeerBoxes, &l.HidePosts,
		&l.Version, &l.SignedBody, &l.Signature, &l.CreatedAt, &l.UpdatedAt}
}

// BoxLock implements BoxLockStore: the cache first, else one read in the
// workspace scope, verified before it is cached.
func (s *Postgres) BoxLock(ctx context.Context, tenant, box string) (*BoxLock, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	if l, ok := s.locks.get(tenant, box); ok {
		return l, nil
	}
	if !s.hasBoxLocks(ctx) {
		l, _ := s.expectLocks.apply(tenant, box, nil) // B6: a listed box stays refused
		return l, nil
	}
	gen := s.locks.generation()
	l := &BoxLock{}
	err := s.queryRowTenant(ctx, tenant, boxLockSQL, []any{tenant, box}, boxLockDest(l)...)
	if errors.Is(err, pgx.ErrNoRows) {
		l, err = nil, nil
	}
	if err != nil {
		return nil, err
	}
	if verifyLoaded(l) {
		if err := s.RecordBoxLockAudit(ctx, tamperAudit(l), s.now()); err != nil {
			return l, err
		}
	}
	l, bad := s.expectLocks.apply(tenant, box, l) // B6, section 6.4
	if bad {
		if err := s.RecordBoxLockAudit(ctx, expectedAudit(tenant, box), s.now()); err != nil {
			return l, err
		}
	}
	s.locks.put(gen, tenant, box, l)
	return l, nil
}

// CreateBoxLock implements BoxLockStore.
func (s *Postgres) CreateBoxLock(ctx context.Context, l BoxLock, by string, now time.Time) error {
	if err := checkTenant(l.TenantID); err != nil {
		return err
	}
	if err := VerifyBoxLock(l); err != nil {
		return err
	}
	if !s.hasBoxLocks(ctx) {
		return ErrBoxLocksUnavailable
	}
	now = now.UTC()
	defer s.locks.forget()
	return s.inTenant(ctx, l.TenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO box_locks (`+boxLockCols+`)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11)
			ON CONFLICT (tenant_id, box_id) DO NOTHING`, l.TenantID, l.BoxID, l.LockPubKey, l.BoxPubKey,
			l.Owners, nonNilStrings(l.PeerBoxes), l.HidePosts, l.Version, l.SignedBody, l.Signature, now)
		if err != nil {
			return mapFK(err)
		}
		if tag.RowsAffected() == 0 {
			return ErrBoxLockExists
		}
		return recordBoxLockAuditTx(ctx, tx, BoxLockAudit{TenantID: l.TenantID, BoxID: l.BoxID, HumanID: by,
			Path: "create", Verdict: BoxLockCreated}, now)
	})
}

// ChangeBoxLock implements BoxLockStore: the stored row is locked FOR
// UPDATE, so two changes at one version cannot both land.
func (s *Postgres) ChangeBoxLock(ctx context.Context, l BoxLock, by string, now time.Time) error {
	if err := checkTenant(l.TenantID); err != nil {
		return err
	}
	if err := VerifyBoxLock(l); err != nil {
		return err
	}
	if !s.hasBoxLocks(ctx) {
		return ErrBoxLocksUnavailable
	}
	now = now.UTC()
	defer s.locks.forget()
	return s.inTenant(ctx, l.TenantID, func(tx pgx.Tx) error {
		var prev BoxLock
		err := tx.QueryRow(ctx, boxLockSQL+` FOR UPDATE`, l.TenantID, l.BoxID).Scan(boxLockDest(&prev)...)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if err := checkBoxLockChange(prev, l); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE box_locks SET box_pubkey = $3, owners = $4, peer_boxes = $5,
			hide_posts = $6, version = $7, signed_body = $8, signature = $9, updated_at = $10
			WHERE tenant_id = $1 AND box_id = $2`, l.TenantID, l.BoxID, l.BoxPubKey, l.Owners,
			nonNilStrings(l.PeerBoxes), l.HidePosts, l.Version, l.SignedBody, l.Signature, now); err != nil {
			return err
		}
		return recordBoxLockAuditTx(ctx, tx, BoxLockAudit{TenantID: l.TenantID, BoxID: l.BoxID, HumanID: by,
			Path: "change", Verdict: BoxLockChanged}, now)
	})
}

// LiftBoxLock implements BoxLockStore.
func (s *Postgres) LiftBoxLock(ctx context.Context, tenant, box, by string, now time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if !s.hasBoxLocks(ctx) {
		return ErrBoxLocksUnavailable
	}
	now = now.UTC()
	defer s.locks.forget()
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM box_locks WHERE tenant_id = $1 AND box_id = $2`, tenant, box)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return recordBoxLockAuditTx(ctx, tx, BoxLockAudit{TenantID: tenant, BoxID: box, HumanID: by,
			Path: "lift", Verdict: BoxLockLifted}, now)
	})
}

// RecordBoxLockAudit implements BoxLockStore.
func (s *Postgres) RecordBoxLockAudit(ctx context.Context, a BoxLockAudit, now time.Time) error {
	if err := checkBoxLockAudit(a); err != nil {
		return err
	}
	if !s.hasBoxLocks(ctx) {
		return ErrBoxLocksUnavailable
	}
	return s.inTenant(ctx, a.TenantID, func(tx pgx.Tx) error {
		return recordBoxLockAuditTx(ctx, tx, a, now.UTC())
	})
}

// recordBoxLockAuditTx bumps the newest row of a's key first written within
// the window, else inserts one. Two racing first refusals may write two rows:
// the bump bounds a flood, it is not a uniqueness rule.
func recordBoxLockAuditTx(ctx context.Context, tx pgx.Tx, a BoxLockAudit, now time.Time) error {
	tag, err := tx.Exec(ctx, `UPDATE box_lock_audit SET count = count + 1, last_at = $8
		WHERE audit_id = (SELECT audit_id FROM box_lock_audit
			WHERE tenant_id = $1 AND box_id = $2 AND human_id IS NOT DISTINCT FROM NULLIF($3::text, '')
			AND from_box IS NOT DISTINCT FROM NULLIF($4::text, '') AND path = $5 AND verdict = $6 AND first_at > $7
			ORDER BY first_at DESC LIMIT 1)`,
		a.TenantID, a.BoxID, a.HumanID, a.FromBox, a.Path, a.Verdict, now.Add(-boxLockAuditWindow), now)
	if err != nil || tag.RowsAffected() > 0 {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO box_lock_audit (tenant_id, box_id, human_id, from_box, path, verdict, first_at, last_at)
		VALUES ($1, $2, NULLIF($3::text, ''), NULLIF($4::text, ''), $5, $6, $7, $7)`,
		a.TenantID, a.BoxID, a.HumanID, a.FromBox, a.Path, a.Verdict, now)
	return mapFK(err)
}

// BoxLockAudits implements BoxLockStore.
func (s *Postgres) BoxLockAudits(ctx context.Context, tenant, box string, limit int) ([]BoxLockAudit, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	if !s.hasBoxLocks(ctx) {
		return nil, nil
	}
	if limit <= 0 {
		limit = 100
	}
	var out []BoxLockAudit
	err := s.queryTenant(ctx, tenant, `SELECT tenant_id, box_id, COALESCE(human_id, ''), COALESCE(from_box, ''),
		path, verdict, first_at, last_at, count FROM box_lock_audit
		WHERE tenant_id = $1 AND box_id = $2 ORDER BY last_at DESC, audit_id DESC LIMIT $3`,
		[]any{tenant, box, limit}, func(r pgx.Rows) error {
			var a BoxLockAudit
			if err := r.Scan(&a.TenantID, &a.BoxID, &a.HumanID, &a.FromBox, &a.Path, &a.Verdict,
				&a.FirstAt, &a.LastAt, &a.Count); err != nil {
				return err
			}
			a.FirstAt, a.LastAt = a.FirstAt.UTC(), a.LastAt.UTC()
			out = append(out, a)
			return nil
		})
	return out, err
}

// nonNilStrings writes an empty list as '{}' rather than NULL.
func nonNilStrings(v []string) []string {
	if v == nil {
		return []string{}
	}
	return v
}
