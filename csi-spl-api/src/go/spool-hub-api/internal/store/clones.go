package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Clone is one member_clones row: an admin "act as a member" session run inside
// a temporary technical human (specs/054). The row is the durable audit trail
// (who acted as whom, when, until when, and when/why it ended); it outlives the
// clone human, which is disabled and stripped of its memberships on stop.
type Clone struct {
	CloneHum  string
	TenantID  string
	TargetHum string
	CreatedBy string
	Role      string
	CreatedAt time.Time
	ExpiresAt time.Time
	EndedAt   *time.Time
	EndReason string
}

// CloneStart is the request to StartClone. TargetHum is the member X being
// cloned; CreatedBy is the admin Y. AdminName names Y for the clone's display
// name. IncludeDMs copies X's private (DM) channels too — off by the owner's
// default (specs/054 §8 Q1), so the clone sees channels and issues, not X's
// 1:1 conversations.
type CloneStart struct {
	TenantID   string
	TargetHum  string
	AdminName  string
	CreatedBy  string
	ExpiresAt  time.Time
	IncludeDMs bool
}

// cloneDisplayName is what the clone shows as, so its posts are unmistakably a
// test and never confused with the real member (specs/054 §3).
func cloneDisplayName(target, admin string) string {
	if target == "" {
		target = "user"
	}
	if admin == "" {
		admin = "an admin"
	}
	return target + " (test clone by " + admin + ")"
}

// StartClone mints a technical clone human of the target member, copies the
// target's tenant role and (non-DM) channel memberships as a snapshot, and
// records the member_clones row — all in one tenant transaction. The clone is
// given no human_identities, so nothing can ever sign in as it; the only
// session for it is the one the act-as handler mints. Returns ErrNotFound when
// the target is not an enabled member of the tenant.
func (s *Postgres) StartClone(ctx context.Context, in CloneStart, now time.Time) (Clone, error) {
	var cl Clone
	err := s.inTenant(ctx, in.TenantID, func(tx pgx.Tx) error {
		var role, targetName string
		var disabled bool
		err := tx.QueryRow(ctx, `SELECT m.role, coalesce(h.display_name, ''),
			(h.disabled_at IS NOT NULL OR m.disabled_at IS NOT NULL)
			FROM tenant_memberships m JOIN humans h ON h.human_id = m.human_id
			WHERE m.tenant_id = $1 AND m.human_id = $2`, in.TenantID, in.TargetHum).Scan(&role, &targetName, &disabled)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if disabled {
			return ErrNotFound
		}
		name := cloneDisplayName(targetName, in.AdminName)
		var clone string
		if err := tx.QueryRow(ctx, `INSERT INTO humans (display_name, technical, created_at)
			VALUES ($1, true, $2) RETURNING human_id`, name, now).Scan(&clone); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, created_at, admitted_by)
			VALUES ($1, $2, $3, $4, $5)`, in.TenantID, clone, role, now, in.CreatedBy); err != nil {
			return err
		}
		// Snapshot the target's channel memberships. Default channels (lobby,
		// tasks, alerts) are tenant-wide and carry no channel_humans row, so
		// they need no copy. Private (DM) channels are excluded unless asked.
		if _, err := tx.Exec(ctx, `INSERT INTO channel_humans (tenant_id, channel_id, human_id, joined_at, added_by)
			SELECT ch.tenant_id, ch.channel_id, $2, $3, 'clone'
			FROM channel_humans ch JOIN channels c ON c.tenant_id = ch.tenant_id AND c.channel_id = ch.channel_id
			WHERE ch.tenant_id = $1 AND ch.human_id = $4 AND ($5 OR NOT c.is_private)`,
			in.TenantID, clone, now, in.TargetHum, in.IncludeDMs); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO member_clones
			(clone_hum, tenant_id, target_hum, created_by, role, created_at, expires_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7)`,
			clone, in.TenantID, in.TargetHum, in.CreatedBy, role, now, in.ExpiresAt); err != nil {
			return err
		}
		cl = Clone{CloneHum: clone, TenantID: in.TenantID, TargetHum: in.TargetHum, CreatedBy: in.CreatedBy,
			Role: role, CreatedAt: now, ExpiresAt: in.ExpiresAt}
		return nil
	})
	return cl, err
}

// stopCloneTx ends a live clone: marks the member_clones row, then disables the
// clone human and deletes its memberships and channel rows so it can act no
// more. The clone's MESSAGES are kept (owner decision, specs/054 §8 Q2): they
// already belong to the visibly-named technical human. tx is tenant- or
// operator-scoped by the caller.
func stopCloneTx(ctx context.Context, tx pgx.Tx, tenant, clone, reason string, now time.Time) (bool, error) {
	tag, err := tx.Exec(ctx, `UPDATE member_clones SET ended_at = $3, end_reason = $4
		WHERE tenant_id = $1 AND clone_hum = $2 AND ended_at IS NULL`, tenant, clone, now, reason)
	if err != nil {
		return false, err
	}
	if tag.RowsAffected() == 0 {
		return false, nil // not a live clone of this tenant
	}
	if _, err := tx.Exec(ctx, `DELETE FROM channel_humans WHERE tenant_id = $1 AND human_id = $2`, tenant, clone); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2`, tenant, clone); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE humans SET disabled_at = $2 WHERE human_id = $1 AND disabled_at IS NULL`, clone, now); err != nil {
		return false, err
	}
	return true, nil
}

// StopClone ends the clone in its tenant scope (the act-as sign-out). Returns
// ErrNotFound when clone is not a live clone of tenant.
func (s *Postgres) StopClone(ctx context.Context, tenant, clone, reason string, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		ok, err := stopCloneTx(ctx, tx, tenant, clone, reason, now)
		if err != nil {
			return err
		}
		if !ok {
			return ErrNotFound
		}
		return nil
	})
}

// Clone reads one clone by its human id, in tenant scope. ErrNotFound when it
// is not a clone of tenant. Used to recognise a clone session and to gate stop.
func (s *Postgres) Clone(ctx context.Context, tenant, clone string) (Clone, error) {
	var c Clone
	err := s.queryRowTenant(ctx, tenant, `SELECT clone_hum, tenant_id, target_hum, created_by, role,
		created_at, expires_at, ended_at, coalesce(end_reason, '')
		FROM member_clones WHERE tenant_id = $1 AND clone_hum = $2`, []any{tenant, clone},
		&c.CloneHum, &c.TenantID, &c.TargetHum, &c.CreatedBy, &c.Role, &c.CreatedAt, &c.ExpiresAt, &c.EndedAt, &c.EndReason)
	if errors.Is(err, pgx.ErrNoRows) {
		return Clone{}, ErrNotFound
	}
	return c, err
}

// ListClones is the tenant's act-as audit trail, newest first (specs/054 §7,
// read behind the audit.read permission).
func (s *Postgres) ListClones(ctx context.Context, tenant string) ([]Clone, error) {
	out := []Clone{}
	err := s.queryTenant(ctx, tenant, `SELECT clone_hum, tenant_id, target_hum, created_by, role,
		created_at, expires_at, ended_at, coalesce(end_reason, '')
		FROM member_clones WHERE tenant_id = $1 ORDER BY created_at DESC, clone_hum`, []any{tenant},
		func(rows pgx.Rows) error {
			var c Clone
			if err := rows.Scan(&c.CloneHum, &c.TenantID, &c.TargetHum, &c.CreatedBy, &c.Role,
				&c.CreatedAt, &c.ExpiresAt, &c.EndedAt, &c.EndReason); err != nil {
				return err
			}
			out = append(out, c)
			return nil
		})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// SweepClones expires every live clone past its expiry, across all tenants
// (the auto-expiry, specs/054 §5). It runs in the operator scope like Sweep, so
// no host cron is needed. Returns the number expired.
func (s *Postgres) SweepClones(ctx context.Context, now time.Time) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		type ref struct{ tenant, clone string }
		var due []ref
		rows, err := tx.Query(ctx, `SELECT tenant_id, clone_hum FROM member_clones
			WHERE ended_at IS NULL AND expires_at <= $1`, now)
		if err != nil {
			return err
		}
		if err := scanRows(rows, func(r pgx.Rows) error {
			var x ref
			if err := r.Scan(&x.tenant, &x.clone); err != nil {
				return err
			}
			due = append(due, x)
			return nil
		}); err != nil {
			return err
		}
		for _, x := range due {
			ok, err := stopCloneTx(ctx, tx, x.tenant, x.clone, "expired", now)
			if err != nil {
				return err
			}
			if ok {
				n++
			}
		}
		return nil
	})
	return n, err
}
