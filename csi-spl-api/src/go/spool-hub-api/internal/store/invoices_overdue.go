package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// The owner's overdue list (spec 181 row B13, gap G14; Q-17 B, Q-18 C):
// every private workspace's invoice that is unpaid and past its due date,
// so the owner decides each case by hand and marks one paid when its bank
// transfer arrives (MarkInvoicePaid, B12). A read only: nothing is decided
// here, and a listed workspace keeps working.

// OverdueInvoices is the cross-workspace read of the overdue list. Optional:
// a store without it has no overdue list.
type OverdueInvoices interface {
	// OverdueInvoices answers every invoice of any workspace that is unpaid
	// and past its due date on now's UTC date (the day the reminder goes
	// out, Q-19 A, and every day after), oldest due date first.
	OverdueInvoices(ctx context.Context, now time.Time) ([]Invoice, error)
}

var (
	_ OverdueInvoices = (*Memory)(nil)
	_ OverdueInvoices = (*Postgres)(nil)
)

// overdue: unpaid and today (UTC) is after due_on.
func overdue(inv Invoice, now time.Time) bool {
	return inv.PaidAt == nil && inv.DueOn.Before(utcDay(now))
}

// sortOverdue orders by due date, then workspace, then month.
func sortOverdue(out []Invoice) {
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if !a.DueOn.Equal(b.DueOn) {
			return a.DueOn.Before(b.DueOn)
		}
		if a.Tenant != b.Tenant {
			return a.Tenant < b.Tenant
		}
		return a.Month.Before(b.Month)
	})
}

// OverdueInvoices lists every overdue invoice (OverdueInvoices).
func (s *Memory) OverdueInvoices(_ context.Context, now time.Time) ([]Invoice, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Invoice
	for _, inv := range memInvoices[s] {
		if overdue(inv, now) {
			out = append(out, inv)
		}
	}
	sortOverdue(out)
	return out, nil
}

const invoiceOverdueSQL = `SELECT ` + invoiceCols + ` FROM private_workspace_invoices
	WHERE paid_at IS NULL AND due_on < ($1::timestamptz AT TIME ZONE 'UTC')::date
	ORDER BY due_on, tenant_id, month`

// OverdueInvoices lists every overdue invoice (OverdueInvoices). It runs in
// the operator scope: the list spans every workspace (TestOperatorScopeCallers).
func (s *Postgres) OverdueInvoices(ctx context.Context, now time.Time) ([]Invoice, error) {
	var out []Invoice
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, invoiceOverdueSQL, now.UTC())
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Invoice, error) { return scanInvoice(r) })
		return err
	})
	return out, err
}
