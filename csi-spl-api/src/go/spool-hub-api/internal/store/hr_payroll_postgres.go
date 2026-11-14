package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0284, in the operator scope like rdb 0280.

const hrRateCols = `year, component, rate_pct::float8, applies_to, source, set_by, set_at`

func scanHRRate(row pgx.Row) (HRRate, error) {
	var r HRRate
	err := row.Scan(&r.Year, &r.Component, &r.RatePct, &r.AppliesTo, &r.Source, &r.SetBy, &r.SetAt)
	r.SetAt = r.SetAt.UTC()
	return r, err
}

// ListHRRates is HRRateStore on Postgres.
func (s *Postgres) ListHRRates(ctx context.Context, year int) ([]HRRate, error) {
	out := []HRRate{}
	err := s.asOperatorQuery(ctx, `SELECT `+hrRateCols+` FROM hr_rates WHERE year = $1 ORDER BY component`, []any{year},
		func(rows pgx.Rows) error {
			r, err := scanHRRate(rows)
			out = append(out, r)
			return err
		})
	return out, err
}

// SetHRRate is HRRateStore on Postgres.
func (s *Postgres) SetHRRate(ctx context.Context, r HRRate) (HRRate, error) {
	comps, err := s.ListHRComponents(ctx)
	if err != nil {
		return HRRate{}, err
	}
	if why := CheckHRRate(r, comps); why != "" {
		return HRRate{}, fmt.Errorf("hr rate: %s", why)
	}
	var out HRRate
	err = s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = scanHRRate(tx.QueryRow(ctx, `INSERT INTO hr_rates (year, component, rate_pct, applies_to, source, set_by)
			VALUES ($1, $2, $3::numeric, $4, $5, $6)
			ON CONFLICT (year, component) DO UPDATE SET rate_pct = EXCLUDED.rate_pct, applies_to = EXCLUDED.applies_to,
				source = EXCLUDED.source, set_by = EXCLUDED.set_by, set_at = now()
			RETURNING `+hrRateCols, r.Year, r.Component, r.RatePct, r.AppliesTo, r.Source, r.SetBy))
		return err
	})
	return out, err
}

// DeleteHRRate is HRRateStore on Postgres.
func (s *Postgres) DeleteHRRate(ctx context.Context, year int, component string) error {
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM hr_rates WHERE year = $1 AND component = $2`, year, component)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}

var _ HRRateStore = (*Postgres)(nil)
