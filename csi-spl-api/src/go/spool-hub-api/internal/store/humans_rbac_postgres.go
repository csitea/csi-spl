package store

import (
	"context"
	"errors"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
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

// memberRolesCol is the role set of the membership row m (rdb 0201), sorted;
// orderRoles puts the primary first.
const memberRolesCol = `ARRAY(SELECT x.role_id FROM tenant_member_roles x
	WHERE x.tenant_id = m.tenant_id AND x.human_id = m.human_id ORDER BY x.role_id)`

// setHasOwnerSQL / setGrantsSQL are true when the role set of membership m
// holds a tenant-owner role / a role granting the permission in $3.
const (
	setHasOwnerSQL = `EXISTS (SELECT 1 FROM tenant_member_roles x JOIN rbac_roles r ON r.role_id = x.role_id
		WHERE x.tenant_id = m.tenant_id AND x.human_id = m.human_id AND r.tenant_owner)`
	setGrantsSQL = `EXISTS (SELECT 1 FROM tenant_member_roles x JOIN rbac_role_permissions g ON g.role_id = x.role_id
		WHERE x.tenant_id = m.tenant_id AND x.human_id = m.human_id AND g.permission_id = $3)`
)

// memberTx locks the tenant row (serialises the last-owner guard, like
// admitTx's seat count) and returns the member's primary role and whether
// its role set holds a tenant-owner role. ErrNotFound when not a member.
func memberTx(ctx context.Context, tx pgx.Tx, tenant, humanID string) (string, bool, error) {
	if _, err := tx.Exec(ctx, `SELECT 1 FROM tenants WHERE tenant_id = $1 FOR UPDATE`, tenant); err != nil {
		return "", false, err
	}
	var role string
	var owner bool
	err := tx.QueryRow(ctx, `SELECT m.role, `+setHasOwnerSQL+` FROM tenant_memberships m
		WHERE m.tenant_id = $1 AND m.human_id = $2`, tenant, humanID).Scan(&role, &owner)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, ErrNotFound
	}
	return role, owner, err
}

// memberSetTx is the member's role set, sorted (memberTx holds the lock).
func memberSetTx(ctx context.Context, tx pgx.Tx, tenant, humanID string) ([]string, error) {
	var set []string
	err := tx.QueryRow(ctx, `SELECT `+memberRolesCol+` FROM tenant_memberships m
		WHERE m.tenant_id = $1 AND m.human_id = $2`, tenant, humanID).Scan(&set)
	return set, err
}

// ownersLeftTx counts the other enabled members whose role set holds a
// tenant-owner role.
func ownersLeftTx(ctx context.Context, tx pgx.Tx, tenant, humanID string) (int, error) {
	var n int
	err := tx.QueryRow(ctx, `SELECT count(*) FROM tenant_memberships m
		JOIN humans h ON h.human_id = m.human_id
		WHERE m.tenant_id = $1 AND m.human_id <> $2 AND h.disabled_at IS NULL
		  AND m.disabled_at IS NULL AND `+setHasOwnerSQL,
		tenant, humanID).Scan(&n)
	return n, err
}

// setGrantsTx reports whether any role of set grants perm.
func setGrantsTx(ctx context.Context, tx pgx.Tx, set []string, perm string) (bool, error) {
	var ok bool
	err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM rbac_role_permissions
		WHERE role_id = ANY ($1::text[]) AND permission_id = $2)`, set, perm).Scan(&ok)
	return ok, err
}

// adminsLeftTx counts the other enabled members whose role set grants
// members.invite (the last-admin guard; memberTx holds the tenant lock).
func adminsLeftTx(ctx context.Context, tx pgx.Tx, tenant, humanID string) (int, error) {
	var n int
	err := tx.QueryRow(ctx, `SELECT count(*) FROM tenant_memberships m
		JOIN humans h ON h.human_id = m.human_id
		WHERE m.tenant_id = $1 AND m.human_id <> $2 AND h.disabled_at IS NULL AND m.disabled_at IS NULL
		  AND `+setGrantsSQL,
		tenant, humanID, rbac.MembersInvite).Scan(&n)
	return n, err
}

// lastAdminTx is ErrLastAdmin when the member's role set grants
// members.invite, next (the new set, nil = removal) does not, and no other
// enabled member keeps it.
func lastAdminTx(ctx context.Context, tx pgx.Tx, tenant, humanID string, next []string) error {
	cur, err := memberSetTx(ctx, tx, tenant, humanID)
	if err != nil {
		return err
	}
	was, err := setGrantsTx(ctx, tx, cur, rbac.MembersInvite)
	if err != nil || !was {
		return err
	}
	if len(next) > 0 {
		if still, err := setGrantsTx(ctx, tx, next, rbac.MembersInvite); err != nil || still {
			return err
		}
	}
	n, err := adminsLeftTx(ctx, tx, tenant, humanID)
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrLastAdmin
	}
	return nil
}

func (s *Postgres) SetMemberRole(ctx context.Context, tenant, humanID, role, from string) error {
	role, err := normalizeRole(role, "")
	if err != nil {
		return err
	}
	return s.setMemberRoles(ctx, tenant, humanID, []string{role}, role, func(cur string, _ []string) bool {
		return from == "" || cur == rbac.Legacy(from)
	})
}

// SetMemberRoles sets the member's whole role set (Humans.SetMemberRoles).
func (s *Postgres) SetMemberRoles(ctx context.Context, tenant, humanID string, roles []string, primary string, from []string) error {
	set, primary, err := normalizeRoleSet(roles, primary)
	if err != nil {
		return err
	}
	return s.setMemberRoles(ctx, tenant, humanID, set, primary, func(_ string, curSet []string) bool {
		return from == nil || sameRoles(curSet, from)
	})
}

// isExclusiveRoleViolation reports the rdb 0201 trigger's refusal of an
// exclusive role next to another.
func isExclusiveRoleViolation(err error) bool {
	var pe *pgconn.PgError
	return sqlState(err) == "23514" && errors.As(err, &pe) && pe.ConstraintName == "tenant_member_roles_exclusive"
}

// setMemberRoles writes a normalized set in one tenant transaction; primary
// "" is pickPrimary's. fromOK is the optimistic check on the primary and the
// set as they stand.
func (s *Postgres) setMemberRoles(ctx context.Context, tenant, humanID string, set []string, primary string,
	fromOK func(cur string, curSet []string) bool) error {
	defer s.hot.forget() // DB payload cut 5: the door cache holds the role set
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var n int
		var newOwner bool
		err := tx.QueryRow(ctx, `SELECT count(*), coalesce(bool_or(tenant_owner), false) FROM rbac_roles
			WHERE role_id = ANY ($1::text[]) AND (tenant_id IS NULL OR tenant_id = $2)`, set, tenant).Scan(&n, &newOwner)
		if err != nil {
			return err
		}
		if n != len(set) {
			return ErrUnknownRole
		}
		cur, owner, err := memberTx(ctx, tx, tenant, humanID)
		if err != nil {
			return err
		}
		curSet, err := memberSetTx(ctx, tx, tenant, humanID)
		if err != nil {
			return err
		}
		if !fromOK(cur, orderRoles(cur, curSet)) {
			return ErrRoleChanged
		}
		if owner && !newOwner {
			if n, err := ownersLeftTx(ctx, tx, tenant, humanID); err != nil {
				return err
			} else if n == 0 {
				return ErrLastOwner
			}
		}
		if err := lastAdminTx(ctx, tx, tenant, humanID, set); err != nil {
			return err
		}
		next := pickPrimary(set, primary, cur)
		// Drop what leaves the set first, so the primary trigger and the
		// exclusive-role trigger (rdb 0201) never see a mixed set; then the
		// primary (its trigger drops the old one); then whatever is missing.
		if _, err := tx.Exec(ctx, `DELETE FROM tenant_member_roles
			WHERE tenant_id = $1 AND human_id = $2 AND NOT (role_id = ANY ($3::text[]))`, tenant, humanID, set); err != nil {
			return err
		}
		if next != cur {
			if _, err := tx.Exec(ctx, `UPDATE tenant_memberships SET role = $3 WHERE tenant_id = $1 AND human_id = $2`,
				tenant, humanID, next); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, `INSERT INTO tenant_member_roles (tenant_id, human_id, role_id)
			SELECT $1, $2, r FROM unnest($3::text[]) AS r ON CONFLICT DO NOTHING`, tenant, humanID, set)
		return err
	})
	if isExclusiveRoleViolation(err) {
		return ErrBadRole
	}
	return err
}

func (s *Postgres) RemoveMember(ctx context.Context, tenant, humanID string) error {
	defer s.hot.forget() // DB payload cut 5: the door cache holds the membership
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return removeMemberTx(ctx, tx, tenant, humanID)
	})
}

// removeMemberTx is RemoveMember inside an open tenant transaction
// (BanMember shares it).
func removeMemberTx(ctx context.Context, tx pgx.Tx, tenant, humanID string) error {
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
	if err := lastAdminTx(ctx, tx, tenant, humanID, nil); err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `DELETE FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID)
	return err
}
