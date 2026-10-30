package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Postgres side of rdb 0245. Every statement runs in the operator scope: the
// rows are the instance's, no tenant (operatorCallers says who reaches it).

const costEntryCols = `id::text, type, label, amount::float8, currency, to_char(period, 'YYYY-MM'), note, created_by, created_at`

func scanCostEntry(row pgx.Row) (CostEntry, error) {
	var e CostEntry
	err := row.Scan(&e.ID, &e.Type, &e.Label, &e.Amount, &e.Currency, &e.Period, &e.Note, &e.CreatedBy, &e.CreatedAt)
	e.CreatedAt = e.CreatedAt.UTC()
	return e, err
}

// ListCostEntries is CostEntryStore on Postgres. An empty filter matches
// every row; a month is the 1st of that month.
func (s *Postgres) ListCostEntries(ctx context.Context, typ, month string) ([]CostEntry, error) {
	out := []CostEntry{}
	err := s.asOperatorQuery(ctx, `SELECT `+costEntryCols+` FROM cost_entries
		WHERE ($1 = '' OR type = $1) AND ($2 = '' OR period = to_date($2, 'YYYY-MM'))
		ORDER BY period, created_at, id`, []any{typ, month},
		func(rows pgx.Rows) error {
			e, err := scanCostEntry(rows)
			out = append(out, e)
			return err
		})
	return out, err
}

// CreateCostEntry is CostEntryStore on Postgres.
func (s *Postgres) CreateCostEntry(ctx context.Context, e CostEntry) (CostEntry, error) {
	if why := CheckCostEntry(e); why != "" {
		return CostEntry{}, fmt.Errorf("cost entry: %s", why)
	}
	var out CostEntry
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = scanCostEntry(tx.QueryRow(ctx, `INSERT INTO cost_entries (id, type, label, amount, currency, period, note, created_by)
			VALUES ($1, $2, $3, $4::numeric, $5, to_date($6, 'YYYY-MM'), $7, $8) RETURNING `+costEntryCols,
			uuid.New(), e.Type, e.Label, e.Amount, e.Currency, e.Period, e.Note, e.CreatedBy))
		return err
	})
	return out, err
}

// DeleteCostEntry is CostEntryStore on Postgres.
func (s *Postgres) DeleteCostEntry(ctx context.Context, id string) error {
	if !uuidRe.MatchString(id) {
		return ErrNotFound
	}
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM cost_entries WHERE id = $1::uuid`, id)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}

var _ CostEntryStore = (*Postgres)(nil)
