package store

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// incomeRow is a synthetic invoice: no real figure or payer (csi-spl is public).
func incomeRow(no, month string, hours float64) IncomeInvoice {
	return IncomeInvoice{InvoiceNo: no, Payer: "ACME", Period: month, IssueDate: month + "-28", DueDate: month + "-28",
		Hours: hours, UnitPrice: 10, Net: hours * 10, VatPct: 25, Vat: hours * 2.5, Total: hours * 12.5, Currency: "EUR"}
}

// SPL-4697, rdb 0256: an import inserts, the same import again only updates;
// the list is the year's rows in period order; years are newest first; a bad
// row refuses the whole batch; another workspace reads none. Memory and
// Postgres. RED CONTROL (base): the store kept no income invoices.
func TestIncomeInvoiceStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ii, ok := st.(IncomeInvoiceStore)
			if !ok {
				t.Fatalf("%s keeps no income invoices", name)
			}
			ten, other := newTenant(t, st), newTenant(t, st)
			batch := []IncomeInvoice{incomeRow("INV-0002", "2026-03", 100), incomeRow("INV-0001", "2026-02", 28.5), incomeRow("INV-0000", "2025-12", 4)}
			if ins, upd, err := ii.UpsertIncomeInvoices(ctx, ten, batch); err != nil || ins != 3 || upd != 0 {
				t.Fatalf("first import: %d %d %v, want 3 0", ins, upd, err)
			}
			batch[0].Hours, batch[0].Net, batch[0].Vat, batch[0].Total = 120, 1200, 300, 1500
			if ins, upd, err := ii.UpsertIncomeInvoices(ctx, ten, batch); err != nil || ins != 0 || upd != 3 {
				t.Fatalf("second import: %d %d %v, want 0 3", ins, upd, err)
			}
			got, err := ii.ListIncomeInvoices(ctx, ten, 2026)
			if err != nil || len(got) != 2 || got[0].InvoiceNo != "INV-0001" || got[1].Hours != 120 || got[1].Total != 1500 {
				t.Fatalf("2026: %+v %v", got, err)
			}
			if got[0] != batch[1] {
				t.Fatalf("round trip: %+v, want %+v", got[0], batch[1])
			}
			if years, err := ii.IncomeYears(ctx, ten); err != nil || len(years) != 2 || years[0] != 2026 || years[1] != 2025 {
				t.Fatalf("years: %v %v", years, err)
			}
			for why, bad := range map[string]IncomeInvoice{
				"sum":      func() IncomeInvoice { r := incomeRow("INV-9", "2026-04", 1); r.Total++; return r }(),
				"a day":    incomeRow("INV-9", "2026-04-01", 1),
				"currency": func() IncomeInvoice { r := incomeRow("INV-9", "2026-04", 1); r.Currency = "eur"; return r }(),
				"due":      func() IncomeInvoice { r := incomeRow("INV-9", "2026-04", 1); r.DueDate = "2026-04-01"; return r }(),
				"no payer": func() IncomeInvoice { r := incomeRow("INV-9", "2026-04", 1); r.Payer = " "; return r }(),
				"3 dec":    func() IncomeInvoice { r := incomeRow("INV-9", "2026-04", 1); r.Net, r.Total = 10.001, 12.501; return r }(),
			} {
				_, _, err := ii.UpsertIncomeInvoices(ctx, ten, []IncomeInvoice{incomeRow("INV-8", "2026-05", 1), bad})
				if !errors.Is(err, ErrIncomeInvoice) || !strings.Contains(err.Error(), "row 1") {
					t.Errorf("%s: %v, want a refusal of row 1", why, err)
				}
			}
			if _, _, err := ii.UpsertIncomeInvoices(ctx, ten, []IncomeInvoice{incomeRow("INV-7", "2026-05", 1), incomeRow("INV-7", "2026-06", 1)}); err == nil {
				t.Error("one invoice number twice in a batch was stored")
			}
			if got, _ := ii.ListIncomeInvoices(ctx, ten, 2026); len(got) != 2 {
				t.Fatalf("a refused batch stored rows: %+v", got)
			}
			if got, err := ii.ListIncomeInvoices(ctx, other, 2026); err != nil || len(got) != 0 {
				t.Fatalf("another workspace reads %+v %v, want none", got, err)
			}
			if _, err := ii.ListIncomeInvoices(ctx, "", 2026); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v, want ErrNoTenant", err)
			}
		})
	}
}

// SPL-4697, rdb 0256: no scope and another workspace read no invoice and may
// not insert one for this workspace; CONTROL: the workspace reads its own.
func TestIncomeInvoiceRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	ten, other := newTenant(t, pg), newTenant(t, pg)
	if _, _, err := pg.UpsertIncomeInvoices(ctx, ten, []IncomeInvoice{incomeRow("INV-RLS", "2026-01", 1)}); err != nil {
		t.Fatal(err)
	}
	for scope, run := range map[string]func(func(pgx.Tx) error) error{
		"none":            func(fn func(pgx.Tx) error) error { return pgx.BeginFunc(ctx, pg.pool, fn) },
		"other workspace": func(fn func(pgx.Tx) error) error { return pg.inTenant(ctx, other, fn) },
	} {
		var n int
		if err := run(func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM income_invoices WHERE tenant_id = $1`, ten).Scan(&n)
		}); err != nil || n != 0 {
			t.Errorf("%s scope reads %d invoices (%v), want 0", scope, n, err)
		}
		err := run(func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO income_invoices (tenant_id, invoice_no, payer, period, issue_date, due_date,
				hours, unit_price, net, vat_pct, vat, total, currency)
				VALUES ($1, 'X', 'X', '2026-01-01', '2026-01-01', '2026-01-01', 0, 0, 0, 0, 0, 0, 'EUR')`, ten)
			return err
		})
		if err == nil || !strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s scope insert: %v, want the RLS refusal", scope, err)
		}
	}
	if got, err := pg.ListIncomeInvoices(ctx, ten, 2026); err != nil || len(got) != 1 {
		t.Fatalf("CONTROL: the workspace reads its own: %+v %v", got, err)
	}
}
