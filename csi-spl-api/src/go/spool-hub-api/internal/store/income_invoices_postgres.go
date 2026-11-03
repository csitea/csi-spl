package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0256. Every statement runs in the workspace's scope
// (inTenant): a query cannot see or write another workspace's invoices.

const incomeInvoiceCols = `invoice_no, payer, to_char(period, 'YYYY-MM'), to_char(issue_date, 'YYYY-MM-DD'),
	to_char(due_date, 'YYYY-MM-DD'), hours::float8, unit_price::float8, net::float8, vat_pct::float8,
	vat::float8, total::float8, currency`

// ListIncomeInvoices is IncomeInvoiceStore on Postgres.
func (s *Postgres) ListIncomeInvoices(ctx context.Context, tenant string, year int) ([]IncomeInvoice, error) {
	out := []IncomeInvoice{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+incomeInvoiceCols+` FROM income_invoices
			WHERE tenant_id = $1 AND period >= make_date($2, 1, 1) AND period < make_date($2 + 1, 1, 1)
			ORDER BY period, invoice_no`, tenant, year)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var in IncomeInvoice
			if err := rows.Scan(&in.InvoiceNo, &in.Payer, &in.Period, &in.IssueDate, &in.DueDate, &in.Hours,
				&in.UnitPrice, &in.Net, &in.VatPct, &in.Vat, &in.Total, &in.Currency); err != nil {
				return err
			}
			out = append(out, in)
		}
		return rows.Err()
	})
	return out, err
}

// IncomeYears is IncomeInvoiceStore on Postgres.
func (s *Postgres) IncomeYears(ctx context.Context, tenant string) ([]int, error) {
	out := []int{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT DISTINCT extract(year FROM period)::int AS y FROM income_invoices
			WHERE tenant_id = $1 ORDER BY y DESC`, tenant)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var y int
			if err := rows.Scan(&y); err != nil {
				return err
			}
			out = append(out, y)
		}
		return rows.Err()
	})
	return out, err
}

// UpsertIncomeInvoices is IncomeInvoiceStore on Postgres: one transaction,
// so one refused row stores none. xmax = 0 marks a fresh insert.
func (s *Postgres) UpsertIncomeInvoices(ctx context.Context, tenant string, rows []IncomeInvoice) (int, int, error) {
	if i, why := CheckIncomeInvoices(rows); why != "" {
		return 0, 0, fmt.Errorf("%w: row %d: %s", ErrIncomeInvoice, i, why)
	}
	ins, upd := 0, 0
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		for _, in := range rows {
			var fresh bool
			if err := tx.QueryRow(ctx, `INSERT INTO income_invoices (tenant_id, invoice_no, payer, period, issue_date,
				due_date, hours, unit_price, net, vat_pct, vat, total, currency)
				VALUES ($1, $2, $3, to_date($4, 'YYYY-MM'), $5::date, $6::date, $7::numeric, $8::numeric,
					$9::numeric, $10::numeric, $11::numeric, $12::numeric, $13)
				ON CONFLICT (tenant_id, invoice_no) DO UPDATE SET payer = EXCLUDED.payer, period = EXCLUDED.period,
					issue_date = EXCLUDED.issue_date, due_date = EXCLUDED.due_date, hours = EXCLUDED.hours,
					unit_price = EXCLUDED.unit_price, net = EXCLUDED.net, vat_pct = EXCLUDED.vat_pct,
					vat = EXCLUDED.vat, total = EXCLUDED.total, currency = EXCLUDED.currency, updated_at = now()
				RETURNING (xmax = 0)`,
				tenant, in.InvoiceNo, in.Payer, in.Period, in.IssueDate, in.DueDate, in.Hours, in.UnitPrice,
				in.Net, in.VatPct, in.Vat, in.Total, in.Currency).Scan(&fresh); err != nil {
				return err
			}
			if fresh {
				ins++
			} else {
				upd++
			}
		}
		return nil
	})
	if err != nil {
		return 0, 0, err
	}
	return ins, upd, nil
}

var _ IncomeInvoiceStore = (*Postgres)(nil)
