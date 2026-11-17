package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0291. Every statement runs in the operator scope: the
// splits are the instance's, no tenant.

const costSplitCols = `split_kind, subject, workspace_id, share_bp, created_by, created_at`

// CostSplits is CostSplitStore on Postgres.
func (s *Postgres) CostSplits(ctx context.Context) ([]CostSplit, error) {
	out := []CostSplit{}
	err := s.asOperatorQuery(ctx, `SELECT `+costSplitCols+` FROM cost_splits
		ORDER BY split_kind, subject, workspace_id`, nil, func(rows pgx.Rows) error {
		var (
			k  CostSplitKey
			sh CostAllocShare
			by string
			at time.Time
		)
		if err := rows.Scan(&k.Kind, &k.Subject, &sh.WorkspaceID, &sh.ShareBP, &by, &at); err != nil {
			return err
		}
		if n := len(out); n == 0 || out[n-1].CostSplitKey != k {
			out = append(out, CostSplit{CostSplitKey: k, CreatedBy: by, CreatedAt: at.UTC()})
		}
		last := &out[len(out)-1]
		last.Shares = append(last.Shares, sh)
		if at.After(last.CreatedAt) {
			last.CreatedAt, last.CreatedBy = at.UTC(), by
		}
		return nil
	})
	return out, err
}

// PutCostSplit is CostSplitStore on Postgres: the split's rows are deleted
// and the new ones inserted in one transaction.
func (s *Postgres) PutCostSplit(ctx context.Context, sp CostSplit) (CostSplit, error) {
	if why := CheckCostSplit(sp); why != "" {
		return CostSplit{}, fmt.Errorf("cost split: %s", why)
	}
	sp.Shares = append([]CostAllocShare{}, sp.Shares...)
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM cost_splits WHERE split_kind = $1 AND subject = $2`,
			sp.Kind, sp.Subject); err != nil {
			return err
		}
		sp.CreatedAt = time.Now().UTC()
		for _, sh := range sp.Shares {
			err := tx.QueryRow(ctx, `INSERT INTO cost_splits (`+costSplitCols+`)
				VALUES ($1, $2, $3, $4, $5, now()) RETURNING created_at`,
				sp.Kind, sp.Subject, sh.WorkspaceID, sh.ShareBP, sp.CreatedBy).Scan(&sp.CreatedAt)
			if err != nil {
				return err
			}
		}
		sp.CreatedAt = sp.CreatedAt.UTC()
		return nil
	})
	if err != nil {
		return CostSplit{}, err
	}
	sortCostSplits([]CostSplit{sp})
	return sp, nil
}

var _ CostSplitStore = (*Postgres)(nil)
