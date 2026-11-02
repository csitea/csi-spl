package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// RoleGrants is the tenant's stored rows, by role then action.
func (s *Postgres) RoleGrants(ctx context.Context, tenant string) ([]RoleGrant, error) {
	out := []RoleGrant{}
	err := s.queryTenant(ctx, tenant, `SELECT permission_id, role_id, granted, set_by, set_at
		FROM tenant_role_grants WHERE tenant_id = $1
		ORDER BY role_id COLLATE "C", permission_id COLLATE "C"`, []any{tenant}, func(rows pgx.Rows) error {
		var g RoleGrant
		if err := rows.Scan(&g.Action, &g.Role, &g.Granted, &g.SetBy, &g.SetAt); err != nil {
			return err
		}
		g.SetAt = g.SetAt.UTC()
		out = append(out, g)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// SetRoleCells writes a cell set in one transaction; other cells stay as they are.
func (s *Postgres) SetRoleCells(ctx context.Context, tenant, setBy string, cells []RoleCell, now time.Time) error {
	plan, err := planRoleCells(tenant, setBy, cells, now)
	if err != nil {
		return err
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return writeRolePlanTx(ctx, tx, tenant, plan, false)
	})
}

// ApplyRolePreset drops the tenant's rows and writes the preset's difference from today.
func (s *Postgres) ApplyRolePreset(ctx context.Context, tenant, setBy, preset string, now time.Time) error {
	plan, err := planRolePreset(tenant, setBy, preset, now)
	if err != nil {
		return err
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return writeRolePlanTx(ctx, tx, tenant, plan, true)
	})
}

// writeRolePlanTx applies a checked plan inside the caller's tenant
// transaction; dropAll first clears the tenant's rows (a preset). The tenant
// row's lock serialises writers, so two presets never leave a mix of their
// rows; NO KEY keeps it out of the way of the tenant's foreign-key checks.
func writeRolePlanTx(ctx context.Context, tx pgx.Tx, tenant string, plan roleCellPlan, dropAll bool) error {
	var one int
	err := tx.QueryRow(ctx, `SELECT 1 FROM tenants WHERE tenant_id = $1 FOR NO KEY UPDATE`, tenant).Scan(&one)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if dropAll {
		if _, err := tx.Exec(ctx, `DELETE FROM tenant_role_grants WHERE tenant_id = $1`, tenant); err != nil {
			return err
		}
	}
	if len(plan.drop) > 0 {
		roles, actions := make([]string, len(plan.drop)), make([]string, len(plan.drop))
		for i, c := range plan.drop {
			roles[i], actions[i] = c.Role, c.Action
		}
		if _, err := tx.Exec(ctx, `DELETE FROM tenant_role_grants
			WHERE tenant_id = $1 AND (role_id, permission_id) IN (SELECT r, p FROM unnest($2::text[], $3::text[]) AS c (r, p))`,
			tenant, roles, actions); err != nil {
			return err
		}
	}
	return upsertRoleGrantsTx(ctx, tx, tenant, plan.write)
}

// upsertRoleGrantsTx writes the rows as one statement. All rows of a plan
// share set_by and set_at.
func upsertRoleGrantsTx(ctx context.Context, tx pgx.Tx, tenant string, write []RoleGrant) error {
	if len(write) == 0 {
		return nil
	}
	roles, actions, granted := make([]string, len(write)), make([]string, len(write)), make([]bool, len(write))
	for i, g := range write {
		roles[i], actions[i], granted[i] = g.Role, g.Action, g.Granted
	}
	_, err := tx.Exec(ctx, `INSERT INTO tenant_role_grants (tenant_id, role_id, permission_id, granted, set_by, set_at)
		SELECT $1, r, p, g, $5, $6 FROM unnest($2::text[], $3::text[], $4::boolean[]) AS c (r, p, g)
		ON CONFLICT (tenant_id, role_id, permission_id) DO UPDATE
		SET granted = EXCLUDED.granted, set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at`,
		tenant, roles, actions, granted, write[0].SetBy, write[0].SetAt)
	return err
}
