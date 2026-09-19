package store

import (
	"context"
	"errors"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/jackc/pgx/v5"
)

// TenantRoles reads the roles visible to tenant under its RLS scope: the
// system rows (tenant_id NULL) and the tenant's own (phase 2).
func (s *Postgres) TenantRoles(ctx context.Context, tenant string) (map[string]rbac.Role, error) {
	out := map[string]rbac.Role{}
	err := s.queryTenant(ctx, tenant, `SELECT r.role_id, r.tenant_owner,
			COALESCE(array_agg(g.permission_id ORDER BY g.permission_id) FILTER (WHERE g.permission_id IS NOT NULL), '{}')
		FROM rbac_roles r LEFT JOIN rbac_role_permissions g ON g.role_id = r.role_id
		WHERE r.tenant_id IS NULL OR r.tenant_id = $1
		GROUP BY r.role_id, r.tenant_owner`, []any{tenant}, func(rows pgx.Rows) error {
		var r rbac.Role
		if err := rows.Scan(&r.ID, &r.TenantOwner, &r.Perms); err != nil {
			return err
		}
		out[r.ID] = r
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// memberTx locks the tenant row (serialises the last-owner guard, like
// admitTx's seat count) and returns the member's role and whether it is a
// tenant-owner role. ErrNotFound when not a member.
func memberTx(ctx context.Context, tx pgx.Tx, tenant, humanID string) (string, bool, error) {
	if _, err := tx.Exec(ctx, `SELECT 1 FROM tenants WHERE tenant_id = $1 FOR UPDATE`, tenant); err != nil {
		return "", false, err
	}
	var role string
	var owner bool
	err := tx.QueryRow(ctx, `SELECT m.role, r.tenant_owner FROM tenant_memberships m
		JOIN rbac_roles r ON r.role_id = m.role
		WHERE m.tenant_id = $1 AND m.human_id = $2`, tenant, humanID).Scan(&role, &owner)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, ErrNotFound
	}
	return role, owner, err
}

// ownersLeftTx counts the other enabled members holding a tenant-owner role.
func ownersLeftTx(ctx context.Context, tx pgx.Tx, tenant, humanID string) (int, error) {
	var n int
	err := tx.QueryRow(ctx, `SELECT count(*) FROM tenant_memberships m
		JOIN rbac_roles r ON r.role_id = m.role JOIN humans h ON h.human_id = m.human_id
		WHERE m.tenant_id = $1 AND m.human_id <> $2 AND r.tenant_owner AND h.disabled_at IS NULL`,
		tenant, humanID).Scan(&n)
	return n, err
}

func (s *Postgres) SetMemberRole(ctx context.Context, tenant, humanID, role, from string) error {
	role, err := normalizeRole(role, "")
	if err != nil {
		return err
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var newOwner bool
		err := tx.QueryRow(ctx, `SELECT tenant_owner FROM rbac_roles
			WHERE role_id = $1 AND (tenant_id IS NULL OR tenant_id = $2)`, role, tenant).Scan(&newOwner)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrUnknownRole
		}
		if err != nil {
			return err
		}
		cur, owner, err := memberTx(ctx, tx, tenant, humanID)
		if err != nil {
			return err
		}
		if from != "" && cur != rbac.Legacy(from) {
			return ErrRoleChanged
		}
		if owner && !newOwner {
			if n, err := ownersLeftTx(ctx, tx, tenant, humanID); err != nil {
				return err
			} else if n == 0 {
				return ErrLastOwner
			}
		}
		_, err = tx.Exec(ctx, `UPDATE tenant_memberships SET role = $3 WHERE tenant_id = $1 AND human_id = $2`,
			tenant, humanID, role)
		return err
	})
}

func (s *Postgres) RemoveMember(ctx context.Context, tenant, humanID string) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, owner, err := memberTx(ctx, tx, tenant, humanID)
		if err != nil {
			return err
		}
		if owner {
			if n, err := ownersLeftTx(ctx, tx, tenant, humanID); err != nil {
				return err
			} else if n == 0 {
				return ErrLastOwner
			}
		}
		_, err = tx.Exec(ctx, `DELETE FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID)
		return err
	})
}
