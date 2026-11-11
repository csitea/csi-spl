package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0275. Every statement runs in the operator scope: the
// items are the instance's, no tenant (operatorCallers says who reaches it).

const costAllocCols = `source, project_or_vendor, kind, workspace_id, share_bp, created_by, created_at`

// costAllocRows folds rows of costAllocCols, item order, into splits.
type costAllocRows struct {
	out []CostAllocation
}

func (c *costAllocRows) scan(rows pgx.Rows) error {
	var (
		k  CostItemKey
		sh CostAllocShare
		by string
		at time.Time
	)
	if err := rows.Scan(&k.Source, &k.ProjectOrVendor, &k.Kind, &sh.WorkspaceID, &sh.ShareBP, &by, &at); err != nil {
		return err
	}
	if n := len(c.out); n == 0 || c.out[n-1].CostItemKey != k {
		c.out = append(c.out, CostAllocation{CostItemKey: k, CreatedBy: by, CreatedAt: at.UTC()})
	}
	last := &c.out[len(c.out)-1]
	last.Shares = append(last.Shares, sh)
	if at.After(last.CreatedAt) {
		last.CreatedAt, last.CreatedBy = at.UTC(), by
	}
	return nil
}

// CostAllocations is CostAllocationStore on Postgres.
func (s *Postgres) CostAllocations(ctx context.Context) ([]CostAllocation, error) {
	var c costAllocRows
	err := s.asOperatorQuery(ctx, `SELECT `+costAllocCols+` FROM cost_allocations
		ORDER BY source, project_or_vendor, kind, workspace_id`, nil, c.scan)
	if c.out == nil {
		c.out = []CostAllocation{}
	}
	return c.out, err
}

// PutCostAllocation is CostAllocationStore on Postgres: the item's rows are
// locked and read (the customer admin's rule is checked against them), then
// deleted and the new ones inserted, in one transaction.
func (s *Postgres) PutCostAllocation(ctx context.Context, a CostAllocation, within map[string]bool) (CostAllocation, error) {
	a.Shares = append([]CostAllocShare{}, a.Shares...)
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		old, err := costAllocLocked(ctx, tx, a.CostItemKey)
		if err != nil {
			return err
		}
		if err := checkCostAllocPut(a, old, within); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM cost_allocations WHERE source = $1 AND project_or_vendor = $2 AND kind = $3`,
			a.Source, a.ProjectOrVendor, a.Kind); err != nil {
			return err
		}
		a.CreatedAt = time.Now().UTC()
		for _, sh := range a.Shares {
			err := tx.QueryRow(ctx, `INSERT INTO cost_allocations (`+costAllocCols+`)
				VALUES ($1, $2, $3, $4, $5, $6, now()) RETURNING created_at`,
				a.Source, a.ProjectOrVendor, a.Kind, sh.WorkspaceID, sh.ShareBP, a.CreatedBy).Scan(&a.CreatedAt)
			if err != nil {
				return err
			}
		}
		a.CreatedAt = a.CreatedAt.UTC()
		return nil
	})
	if err != nil {
		return CostAllocation{}, err
	}
	sortCostAllocations([]CostAllocation{a})
	return a, nil
}

// costAllocLocked is the item's stored shares, locked FOR UPDATE so a
// concurrent write waits and the customer admin's check sees what it
// replaces. (A first write of an item locks no row; two first writes then
// race on the primary key and one fails.)
func costAllocLocked(ctx context.Context, tx pgx.Tx, k CostItemKey) ([]CostAllocShare, error) {
	rows, err := tx.Query(ctx, `SELECT workspace_id, share_bp FROM cost_allocations
		WHERE source = $1 AND project_or_vendor = $2 AND kind = $3 ORDER BY workspace_id FOR UPDATE`,
		k.Source, k.ProjectOrVendor, k.Kind)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (CostAllocShare, error) {
		var sh CostAllocShare
		err := r.Scan(&sh.WorkspaceID, &sh.ShareBP)
		return sh, err
	})
}

var _ CostAllocationStore = (*Postgres)(nil)
