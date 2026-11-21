package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0304. Every statement runs in the operator scope: the
// view rules are the instance's, no tenant.

const costViewRuleCols = `workspace_id, label, match, share_bp, created_by, created_at`

// CostViewRules is CostViewRuleStore on Postgres.
func (s *Postgres) CostViewRules(ctx context.Context) ([]CostViewRule, error) {
	out := []CostViewRule{}
	err := s.asOperatorQuery(ctx, `SELECT `+costViewRuleCols+` FROM cost_view_rules
		ORDER BY workspace_id, label, match`, nil, func(rows pgx.Rows) error {
		var r CostViewRule
		if err := rows.Scan(&r.WorkspaceID, &r.Label, &r.Match, &r.ShareBP, &r.CreatedBy, &r.CreatedAt); err != nil {
			return err
		}
		r.CreatedAt = r.CreatedAt.UTC()
		out = append(out, r)
		return nil
	})
	return out, err
}

// PutCostViewRules is CostViewRuleStore on Postgres: the workspace's rows
// are deleted and the new ones inserted in one transaction, so a refused
// row (rdb 0304's CHECKs, the tenants FK) leaves the stored set whole.
func (s *Postgres) PutCostViewRules(ctx context.Context, workspaceID, createdBy string, rules []CostViewRule) ([]CostViewRule, error) {
	out, err := costViewPrepare(workspaceID, createdBy, rules)
	if err != nil {
		return nil, err
	}
	err = s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM cost_view_rules WHERE workspace_id = $1`, workspaceID); err != nil {
			return err
		}
		for i := range out {
			r := &out[i]
			var at time.Time
			if err := tx.QueryRow(ctx, `INSERT INTO cost_view_rules (`+costViewRuleCols+`)
				VALUES ($1, $2, $3, $4, $5, now()) RETURNING created_at`,
				r.WorkspaceID, r.Label, r.Match, r.ShareBP, r.CreatedBy).Scan(&at); err != nil {
				return err
			}
			r.CreatedAt = at.UTC()
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

var _ CostViewRuleStore = (*Postgres)(nil)
