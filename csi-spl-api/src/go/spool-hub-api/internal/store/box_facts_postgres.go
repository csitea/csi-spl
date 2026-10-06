package store

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0140, in the tenant scope.

func (s *Postgres) PutBoxFacts(ctx context.Context, tenant string, f BoxFactSheet) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO box_facts (tenant_id, box_id, reported_at, sheet)
			VALUES ($1, $2, $3, $4::jsonb)
			ON CONFLICT (tenant_id, box_id) DO UPDATE SET reported_at = EXCLUDED.reported_at, sheet = EXCLUDED.sheet`,
			tenant, f.Box, f.ReportedAt.UTC(), string(f.Sheet))
		return err
	})
}

func (s *Postgres) ListBoxFacts(ctx context.Context, tenant string) ([]BoxFactSheet, error) {
	out := []BoxFactSheet{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT box_id, reported_at, sheet FROM box_facts
			WHERE tenant_id = $1 ORDER BY box_id`, tenant)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var f BoxFactSheet
			if err := rows.Scan(&f.Box, &f.ReportedAt, &f.Sheet); err != nil {
				return err
			}
			f.ReportedAt = f.ReportedAt.UTC()
			out = append(out, f)
		}
		return rows.Err()
	})
	return out, err
}
