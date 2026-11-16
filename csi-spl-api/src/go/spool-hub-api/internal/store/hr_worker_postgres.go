package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Postgres side of rdb 0286, in the operator scope. hr_tax_cards and
// hr_payslips are personal: every statement on them first sets
// app.costs_names (pgCostsNames) in its transaction, as their policy asks.

// hrPersonMissing is whether err says the person id is not an hr_people row
// (a foreign key miss, or no uuid at all).
func hrPersonMissing(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && (pe.Code == "23503" || pe.Code == "22P02")
}

const hrWorkerRateCols = `year, kind, age_from, age_to, rate_pct::float8, source, set_by, set_at`

func scanHRWorkerRate(row pgx.Row) (HRWorkerRate, error) {
	var r HRWorkerRate
	err := row.Scan(&r.Year, &r.Kind, &r.AgeFrom, &r.AgeTo, &r.RatePct, &r.Source, &r.SetBy, &r.SetAt)
	r.SetAt = r.SetAt.UTC()
	return r, err
}

// ListHRWorkerRates is HRWorkerStore on Postgres.
func (s *Postgres) ListHRWorkerRates(ctx context.Context, year int) ([]HRWorkerRate, error) {
	out := []HRWorkerRate{}
	err := s.asOperatorQuery(ctx, `SELECT `+hrWorkerRateCols+` FROM hr_worker_rates WHERE year = $1 ORDER BY kind, age_from`,
		[]any{year}, func(rows pgx.Rows) error {
			r, err := scanHRWorkerRate(rows)
			out = append(out, r)
			return err
		})
	return out, err
}

// SetHRWorkerRates is HRWorkerStore on Postgres: one transaction removes the
// year's bands of kind and inserts the new ones.
func (s *Postgres) SetHRWorkerRates(ctx context.Context, year int, kind string, bands []HRWorkerRate) ([]HRWorkerRate, error) {
	if why := CheckHRWorkerRates(year, kind, bands); why != "" {
		return nil, fmt.Errorf("hr worker rates: %s", why)
	}
	out := []HRWorkerRate{}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM hr_worker_rates WHERE year = $1 AND kind = $2`, year, kind); err != nil {
			return err
		}
		for _, b := range bands {
			r, err := scanHRWorkerRate(tx.QueryRow(ctx, `INSERT INTO hr_worker_rates (year, kind, age_from, age_to, rate_pct, source, set_by)
				VALUES ($1, $2, $3, $4, $5::numeric, $6, $7) RETURNING `+hrWorkerRateCols,
				year, kind, b.AgeFrom, b.AgeTo, b.RatePct, b.Source, b.SetBy))
			if err != nil {
				return err
			}
			out = append(out, r)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

const hrTaxCardCols = `person_id::text, year, base_pct::float8, extra_pct::float8, income_limit::float8, source, set_by, set_at`

func scanHRTaxCard(row pgx.Row) (HRTaxCard, error) {
	var c HRTaxCard
	err := row.Scan(&c.PersonID, &c.Year, &c.BasePct, &c.ExtraPct, &c.IncomeLimit, &c.Source, &c.SetBy, &c.SetAt)
	c.SetAt = c.SetAt.UTC()
	return c, err
}

// ListHRTaxCards is HRWorkerStore on Postgres.
func (s *Postgres) ListHRTaxCards(ctx context.Context, year int) ([]HRTaxCard, error) {
	out := []HRTaxCard{}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
			return err
		}
		return eachRow(ctx, tx, `SELECT `+hrTaxCardCols+` FROM hr_tax_cards WHERE year = $1 ORDER BY person_id`, []any{year},
			func(rows pgx.Rows) error {
				c, err := scanHRTaxCard(rows)
				out = append(out, c)
				return err
			})
	})
	return out, err
}

// SetHRTaxCard is HRWorkerStore on Postgres.
func (s *Postgres) SetHRTaxCard(ctx context.Context, c HRTaxCard) (HRTaxCard, error) {
	if why := CheckHRTaxCard(c); why != "" {
		return HRTaxCard{}, fmt.Errorf("hr tax card: %s", why)
	}
	var out HRTaxCard
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
			return err
		}
		var err error
		out, err = scanHRTaxCard(tx.QueryRow(ctx, `INSERT INTO hr_tax_cards (person_id, year, base_pct, extra_pct, income_limit, source, set_by)
			VALUES ($1::uuid, $2, $3::numeric, $4::numeric, $5::numeric, $6, $7)
			ON CONFLICT (person_id, year) DO UPDATE SET base_pct = EXCLUDED.base_pct, extra_pct = EXCLUDED.extra_pct,
				income_limit = EXCLUDED.income_limit, source = EXCLUDED.source, set_by = EXCLUDED.set_by, set_at = now()
			RETURNING `+hrTaxCardCols, c.PersonID, c.Year, c.BasePct, c.ExtraPct, c.IncomeLimit, c.Source, c.SetBy))
		return err
	})
	if hrPersonMissing(err) {
		return HRTaxCard{}, ErrNotFound
	}
	return out, err
}

// DeleteHRTaxCard is HRWorkerStore on Postgres.
func (s *Postgres) DeleteHRTaxCard(ctx context.Context, personID string, year int) error {
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `DELETE FROM hr_tax_cards WHERE person_id = $1::uuid AND year = $2`, personID, year)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
	if hrPersonMissing(err) {
		return ErrNotFound
	}
	return err
}

const hrPayslipCols = `person_id::text, to_char(month, 'YYYY-MM'), currency, tyel_employee::float8,
	unemployment_employee::float8, tax_withheld::float8, net_pay::float8, set_by, set_at`

func scanHRPayslip(row pgx.Row) (HRPayslip, error) {
	var p HRPayslip
	err := row.Scan(&p.PersonID, &p.Month, &p.Currency, &p.TyelEmployee, &p.UnemploymentEmployee, &p.TaxWithheld, &p.NetPay, &p.SetBy, &p.SetAt)
	p.SetAt = p.SetAt.UTC()
	return p, err
}

// ListHRPayslips is HRWorkerStore on Postgres.
func (s *Postgres) ListHRPayslips(ctx context.Context, month string) ([]HRPayslip, error) {
	out := []HRPayslip{}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
			return err
		}
		return eachRow(ctx, tx, `SELECT `+hrPayslipCols+` FROM hr_payslips WHERE month = to_date($1, 'YYYY-MM')
			ORDER BY person_id, currency`, []any{month},
			func(rows pgx.Rows) error {
				p, err := scanHRPayslip(rows)
				out = append(out, p)
				return err
			})
	})
	return out, err
}

// SetHRPayslip is HRWorkerStore on Postgres.
func (s *Postgres) SetHRPayslip(ctx context.Context, p HRPayslip) (HRPayslip, error) {
	if why := CheckHRPayslip(p); why != "" {
		return HRPayslip{}, fmt.Errorf("hr payslip: %s", why)
	}
	var out HRPayslip
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
			return err
		}
		var err error
		out, err = scanHRPayslip(tx.QueryRow(ctx, `INSERT INTO hr_payslips (person_id, month, currency, tyel_employee,
				unemployment_employee, tax_withheld, net_pay, set_by)
			VALUES ($1::uuid, to_date($2, 'YYYY-MM'), $3, $4::numeric, $5::numeric, $6::numeric, $7::numeric, $8)
			ON CONFLICT (person_id, month, currency) DO UPDATE SET tyel_employee = EXCLUDED.tyel_employee,
				unemployment_employee = EXCLUDED.unemployment_employee, tax_withheld = EXCLUDED.tax_withheld,
				net_pay = EXCLUDED.net_pay, set_by = EXCLUDED.set_by, set_at = now()
			RETURNING `+hrPayslipCols, p.PersonID, p.Month, p.Currency, p.TyelEmployee, p.UnemploymentEmployee, p.TaxWithheld, p.NetPay, p.SetBy))
		return err
	})
	if hrPersonMissing(err) {
		return HRPayslip{}, ErrNotFound
	}
	return out, err
}

// DeleteHRPayslip is HRWorkerStore on Postgres.
func (s *Postgres) DeleteHRPayslip(ctx context.Context, personID, month, currency string) error {
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `DELETE FROM hr_payslips WHERE person_id = $1::uuid AND month = to_date($2, 'YYYY-MM') AND currency = $3`,
			personID, month, currency)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
	if hrPersonMissing(err) {
		return ErrNotFound
	}
	return err
}

var _ HRWorkerStore = (*Postgres)(nil)
