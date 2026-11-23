package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// The private workspace's monthly invoice and its one reminder (spec 181
// row B12, gaps G6 and G13, rdb 0315). One invoice per workspace per month,
// in arrears, for the seats and the VM cost + 33% (Q-9 B, Q-16 B): the sum
// is the plan's QuoteMonth. It is paid by bank transfer (Q-18 C) and due 14
// days net from its issue date (Q-19 A); an unpaid one gets one reminder on
// day 15, and nothing else happens: no lease is refused, no seat stops, the
// owner decides each case by hand (Q-17 B).
//
// Who writes a month's invoice (fed by the VM's month cost, B4's
// do_spl_vm_cost_per_day, and the month's member count) is a later row, not
// B12; so is the owner's overdue list (B13), which marks one paid.

// InvoiceDueDays is the payment term: 14 days net from the issue date
// (Q-19 A). The reminder goes out on day 15, the first day after due_on.
const InvoiceDueDays = 14

var (
	// ErrInvoiceMonth: the month is not a month's first day, or the issue
	// date is before the month ends (the invoice is in arrears).
	ErrInvoiceMonth = errors.New("store: an invoice is for a whole month, issued after it ends")
)

// Invoice is one private_workspace_invoices row. Dates are UTC midnights.
type Invoice struct {
	Tenant        string
	Month         time.Time
	Currency      string
	Humans        int64
	SeatCents     int64
	VMCostMicros  int64
	VMPriceMicros string
	TotalMicros   string
	IssuedOn      time.Time
	DueOn         time.Time
	PaidAt        *time.Time
	RemindedAt    *time.Time
}

// Invoices is the store half of the monthly invoice. Optional: a store
// without it issues no invoice and sends no reminder.
type Invoices interface {
	// IssueInvoice writes tenant's invoice for month (its first day):
	// the plan's QuoteMonth of humans and vmCostMicros, issued on issuedOn,
	// due InvoiceDueDays later, unpaid. One per workspace per month: a
	// second call returns the row already there and created false.
	// ErrNoPricePlan: the workspace has no plan.
	IssueInvoice(ctx context.Context, tenant string, month time.Time, humans, vmCostMicros int64, issuedOn time.Time) (Invoice, bool, error)
	// Invoice reads tenant's invoice for month; ErrNotFound when none.
	Invoice(ctx context.Context, tenant string, month time.Time) (Invoice, error)
	// MarkInvoicePaid sets paid_at once, on the bank transfer (Q-18 C);
	// ErrNotFound when there is no such invoice. A paid one stays paid.
	MarkInvoicePaid(ctx context.Context, tenant string, month time.Time, at time.Time) error
	// ClaimInvoiceReminders marks reminded_at = now on every invoice of any
	// workspace that is unpaid, not yet reminded and past its due date on
	// now's UTC date, and returns them. A claimed invoice is never claimed
	// again: the reminder goes out once.
	ClaimInvoiceReminders(ctx context.Context, now time.Time) ([]Invoice, error)
	// ReleaseInvoiceReminder clears the claim made at at, when the reminder
	// reached nobody, so the next tick tries again.
	ReleaseInvoiceReminder(ctx context.Context, tenant string, month, at time.Time) error
}

var (
	_ Invoices = (*Memory)(nil)
	_ Invoices = (*Postgres)(nil)
)

// utcDay is t's UTC date at midnight.
func utcDay(t time.Time) time.Time {
	y, m, d := t.UTC().Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// newInvoice checks month and issuedOn and prices the invoice with plan.
func newInvoice(tenant string, plan PricePlan, month time.Time, humans, vmCostMicros int64, issuedOn time.Time) (Invoice, error) {
	month, issuedOn = utcDay(month), utcDay(issuedOn)
	if month.Day() != 1 || issuedOn.Before(month.AddDate(0, 1, 0)) {
		return Invoice{}, fmt.Errorf("%w: month %s issued %s", ErrInvoiceMonth, month.Format(time.DateOnly), issuedOn.Format(time.DateOnly))
	}
	q, err := plan.QuoteMonth(humans, vmCostMicros)
	if err != nil {
		return Invoice{}, err
	}
	return Invoice{Tenant: tenant, Month: month, Currency: q.Currency, Humans: q.Humans, SeatCents: q.SeatCents,
		VMCostMicros: q.VMCostMicros, VMPriceMicros: q.VMPriceMicros, TotalMicros: q.TotalMicros,
		IssuedOn: issuedOn, DueOn: issuedOn.AddDate(0, 0, InvoiceDueDays)}, nil
}

// reminderDue: unpaid, not reminded, and today (UTC) is after due_on.
func reminderDue(inv Invoice, now time.Time) bool {
	return inv.PaidAt == nil && inv.RemindedAt == nil && inv.DueOn.Before(utcDay(now))
}

// Memory side: a map beside the Memory struct, guarded by s.mu.
var memInvoices = map[*Memory]map[string]Invoice{}

func invoiceKey(tenant string, month time.Time) string {
	return tenant + "|" + utcDay(month).Format(time.DateOnly)
}

// IssueInvoice writes the month's invoice (Invoices).
func (s *Memory) IssueInvoice(ctx context.Context, tenant string, month time.Time, humans, vmCostMicros int64, issuedOn time.Time) (Invoice, bool, error) {
	plan, err := s.PricePlan(ctx, tenant)
	if err != nil {
		return Invoice{}, false, err
	}
	inv, err := newInvoice(tenant, plan, month, humans, vmCostMicros, issuedOn)
	if err != nil {
		return Invoice{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if memInvoices[s] == nil {
		memInvoices[s] = map[string]Invoice{}
	}
	if old, ok := memInvoices[s][invoiceKey(tenant, inv.Month)]; ok {
		return old, false, nil
	}
	memInvoices[s][invoiceKey(tenant, inv.Month)] = inv
	return inv, true, nil
}

// Invoice reads the month's invoice (Invoices).
func (s *Memory) Invoice(_ context.Context, tenant string, month time.Time) (Invoice, error) {
	if err := checkTenant(tenant); err != nil {
		return Invoice{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	inv, ok := memInvoices[s][invoiceKey(tenant, month)]
	if !ok {
		return Invoice{}, ErrNotFound
	}
	return inv, nil
}

// MarkInvoicePaid sets paid_at once (Invoices).
func (s *Memory) MarkInvoicePaid(_ context.Context, tenant string, month, at time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := invoiceKey(tenant, month)
	inv, ok := memInvoices[s][k]
	if !ok {
		return ErrNotFound
	}
	if inv.PaidAt == nil {
		at = at.UTC()
		inv.PaidAt = &at
		memInvoices[s][k] = inv
	}
	return nil
}

// ClaimInvoiceReminders claims every due reminder (Invoices).
func (s *Memory) ClaimInvoiceReminders(_ context.Context, now time.Time) ([]Invoice, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Invoice
	at := now.UTC().Truncate(time.Microsecond) // Postgres' precision, so both drivers return the same claim
	for k, inv := range memInvoices[s] {
		if !reminderDue(inv, now) {
			continue
		}
		inv.RemindedAt = &at
		memInvoices[s][k] = inv
		out = append(out, inv)
	}
	return out, nil
}

// ReleaseInvoiceReminder clears the claim made at at (Invoices).
func (s *Memory) ReleaseInvoiceReminder(_ context.Context, tenant string, month, at time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := invoiceKey(tenant, month)
	if inv, ok := memInvoices[s][k]; ok && inv.RemindedAt != nil && inv.RemindedAt.Equal(at.UTC()) {
		inv.RemindedAt = nil
		memInvoices[s][k] = inv
	}
	return nil
}

// Postgres side.
const (
	invoiceCols = `tenant_id, month, currency, humans, seat_cents, vm_cost_micros,
		vm_price_micros::text, total_micros::text, issued_on, due_on, paid_at, reminded_at`
	invoicePutSQL = `INSERT INTO private_workspace_invoices (tenant_id, month, currency, humans, seat_cents,
		vm_cost_micros, vm_price_micros, total_micros, issued_on, due_on)
		VALUES ($1, $2, $3, $4, $5, $6, $7::numeric, $8::numeric, $9, $10)
		ON CONFLICT (tenant_id, month) DO NOTHING`
	invoiceReadSQL = `SELECT ` + invoiceCols + ` FROM private_workspace_invoices WHERE tenant_id = $1 AND month = $2`
	invoicePaidSQL = `UPDATE private_workspace_invoices SET paid_at = coalesce(paid_at, $3)
		WHERE tenant_id = $1 AND month = $2`
	invoiceClaimSQL = `UPDATE private_workspace_invoices SET reminded_at = $1
		WHERE paid_at IS NULL AND reminded_at IS NULL AND due_on < ($1::timestamptz AT TIME ZONE 'UTC')::date
		RETURNING ` + invoiceCols
	invoiceReleaseSQL = `UPDATE private_workspace_invoices SET reminded_at = NULL
		WHERE tenant_id = $1 AND month = $2 AND reminded_at = $3`
)

func scanInvoice(r pgx.Row) (Invoice, error) {
	var inv Invoice
	err := r.Scan(&inv.Tenant, &inv.Month, &inv.Currency, &inv.Humans, &inv.SeatCents, &inv.VMCostMicros,
		&inv.VMPriceMicros, &inv.TotalMicros, &inv.IssuedOn, &inv.DueOn, &inv.PaidAt, &inv.RemindedAt)
	return inv, err
}

// IssueInvoice writes the month's invoice (Invoices).
func (s *Postgres) IssueInvoice(ctx context.Context, tenant string, month time.Time, humans, vmCostMicros int64, issuedOn time.Time) (Invoice, bool, error) {
	plan, err := s.PricePlan(ctx, tenant)
	if err != nil {
		return Invoice{}, false, err
	}
	inv, err := newInvoice(tenant, plan, month, humans, vmCostMicros, issuedOn)
	if err != nil {
		return Invoice{}, false, err
	}
	var created bool
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, invoicePutSQL, tenant, inv.Month, inv.Currency, inv.Humans, inv.SeatCents,
			inv.VMCostMicros, inv.VMPriceMicros, inv.TotalMicros, inv.IssuedOn, inv.DueOn)
		if err != nil {
			return err
		}
		created = tag.RowsAffected() == 1
		inv, err = scanInvoice(tx.QueryRow(ctx, invoiceReadSQL, tenant, inv.Month))
		return err
	})
	return inv, created, err
}

// Invoice reads the month's invoice (Invoices).
func (s *Postgres) Invoice(ctx context.Context, tenant string, month time.Time) (Invoice, error) {
	if err := checkTenant(tenant); err != nil {
		return Invoice{}, err
	}
	var inv Invoice
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) (err error) {
		inv, err = scanInvoice(tx.QueryRow(ctx, invoiceReadSQL, tenant, utcDay(month)))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Invoice{}, ErrNotFound
	}
	return inv, err
}

// MarkInvoicePaid sets paid_at once (Invoices).
func (s *Postgres) MarkInvoicePaid(ctx context.Context, tenant string, month, at time.Time) error {
	tag, err := s.execTenant(ctx, tenant, invoicePaidSQL, tenant, utcDay(month), at.UTC())
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

// ClaimInvoiceReminders claims every due reminder (Invoices). It runs in the
// operator scope: the tick serves every workspace (TestOperatorScopeCallers).
func (s *Postgres) ClaimInvoiceReminders(ctx context.Context, now time.Time) ([]Invoice, error) {
	var out []Invoice
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, invoiceClaimSQL, now.UTC().Truncate(time.Microsecond))
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Invoice, error) { return scanInvoice(r) })
		return err
	})
	return out, err
}

// ReleaseInvoiceReminder clears the claim made at at (Invoices).
func (s *Postgres) ReleaseInvoiceReminder(ctx context.Context, tenant string, month, at time.Time) error {
	_, err := s.execTenant(ctx, tenant, invoiceReleaseSQL, tenant, utcDay(month), at.UTC())
	return err
}
