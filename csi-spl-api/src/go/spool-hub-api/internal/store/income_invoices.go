package store

import (
	"context"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"sync"
	"time"
)

// The workspace's invoiced income, read by Reporting -> Incomes (SPL-4697,
// rdb 0258 income_invoices, spec 143 incomes.md; owner HUM-10, csitea topic
// 450418ab msg e793f8d0). One row is one invoice, keyed by its number within
// the workspace. Rows come in only through the operator's import
// (PUT /v1/operator/incomes); the workspace owner reads them.

// IncomeInvoice is one row of income_invoices. Period is the month worked
// YYYY-MM; IssueDate and DueDate are YYYY-MM-DD.
type IncomeInvoice struct {
	InvoiceNo string  `json:"invoice_no"`
	Payer     string  `json:"payer"`
	Period    string  `json:"period"`
	IssueDate string  `json:"issue_date"`
	DueDate   string  `json:"due_date"`
	Hours     float64 `json:"hours"`
	UnitPrice float64 `json:"unit_price"`
	Net       float64 `json:"net"`
	VatPct    float64 `json:"vat_pct"`
	Vat       float64 `json:"vat"`
	Total     float64 `json:"total"`
	Currency  string  `json:"currency"`
}

// ErrIncomeInvoice wraps every refusal of CheckIncomeInvoice.
var ErrIncomeInvoice = errors.New("income invoice")

// IncomeInvoiceBatchMax bounds one import: years of monthly invoices.
const IncomeInvoiceBatchMax = 500

// isDay is a date YYYY-MM-DD.
func isDay(v string) bool {
	t, err := time.Parse(time.DateOnly, v)
	return err == nil && t.Format(time.DateOnly) == v
}

// incomeAmount is a finite amount below 1e12 with at most 2 decimals.
func incomeAmount(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && math.Abs(v) < 1e12 && math.Abs(v*100-math.Round(v*100)) < 1e-6
}

// CheckIncomeInvoice names the first thing it may not carry ("" = fine): the
// Go side of rdb 0258's CHECKs.
func CheckIncomeInvoice(in IncomeInvoice) string {
	switch {
	case strings.TrimSpace(in.InvoiceNo) == "" || len(in.InvoiceNo) > 64:
		return "invoice_no must be 1..64 characters"
	case strings.TrimSpace(in.Payer) == "" || len(in.Payer) > 100:
		return "payer must be 1..100 characters"
	case !IsCostMonth(in.Period):
		return "period must be a month YYYY-MM"
	case !isDay(in.IssueDate) || !isDay(in.DueDate):
		return "issue_date and due_date must be dates YYYY-MM-DD"
	case in.DueDate < in.IssueDate:
		return "due_date must not be before issue_date"
	case !incomeAmount(in.Hours) || in.Hours < 0 || in.Hours >= 1e6:
		return "hours must be 0 or more, at most 2 decimals"
	case math.IsNaN(in.UnitPrice) || math.IsInf(in.UnitPrice, 0) || in.UnitPrice < 0 || in.UnitPrice >= 1e10:
		return "unit_price must be 0 or more"
	case !incomeAmount(in.Net) || !incomeAmount(in.Vat) || !incomeAmount(in.Total):
		return "net, vat and total must be amounts with at most 2 decimals"
	case math.Round((in.Net+in.Vat)*100) != math.Round(in.Total*100):
		return "net + vat must equal total"
	case math.IsNaN(in.VatPct) || in.VatPct < 0 || in.VatPct > 100:
		return "vat_pct must be 0..100"
	case !IsCurrencyCode(in.Currency):
		return "currency must be an ISO 4217 code such as EUR"
	}
	return ""
}

// CheckIncomeInvoices checks a whole import: 1..IncomeInvoiceBatchMax rows,
// each fine, no invoice number twice. It answers the index of the first bad
// row and why, or -1 and "".
func CheckIncomeInvoices(rows []IncomeInvoice) (int, string) {
	if len(rows) == 0 || len(rows) > IncomeInvoiceBatchMax {
		return -1, fmt.Sprintf("invoices must hold 1..%d rows", IncomeInvoiceBatchMax)
	}
	seen := map[string]bool{}
	for i, in := range rows {
		if why := CheckIncomeInvoice(in); why != "" {
			return i, why
		}
		if seen[in.InvoiceNo] {
			return i, "invoice_no " + in.InvoiceNo + " appears twice"
		}
		seen[in.InvoiceNo] = true
	}
	return -1, ""
}

// IncomeInvoiceStore is the store half of rdb 0258. Optional: the routes
// answer unsupported on a store without it.
type IncomeInvoiceStore interface {
	// ListIncomeInvoices is tenant's invoices of year (by period), period
	// then invoice number order.
	ListIncomeInvoices(ctx context.Context, tenant string, year int) ([]IncomeInvoice, error)
	// IncomeYears is the years tenant has invoices for, newest first.
	IncomeYears(ctx context.Context, tenant string) ([]int, error)
	// UpsertIncomeInvoices stores checked rows in tenant, keyed by invoice
	// number, all or none; it answers how many were new and how many replaced.
	UpsertIncomeInvoices(ctx context.Context, tenant string, rows []IncomeInvoice) (inserted, updated int, err error)
}

// The Memory driver keeps its rows beside the store, like the cost entries.
var (
	memIncomeMu sync.Mutex
	memIncome   = map[*Memory]map[string]map[string]IncomeInvoice{}
)

// ListIncomeInvoices is IncomeInvoiceStore on Memory.
func (s *Memory) ListIncomeInvoices(_ context.Context, tenant string, year int) ([]IncomeInvoice, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	memIncomeMu.Lock()
	defer memIncomeMu.Unlock()
	prefix := fmt.Sprintf("%04d-", year)
	out := []IncomeInvoice{}
	for _, in := range memIncome[s][tenant] {
		if strings.HasPrefix(in.Period, prefix) {
			out = append(out, in)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Period != out[j].Period {
			return out[i].Period < out[j].Period
		}
		return out[i].InvoiceNo < out[j].InvoiceNo
	})
	return out, nil
}

// IncomeYears is IncomeInvoiceStore on Memory.
func (s *Memory) IncomeYears(_ context.Context, tenant string) ([]int, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	memIncomeMu.Lock()
	defer memIncomeMu.Unlock()
	seen := map[int]bool{}
	out := []int{}
	for _, in := range memIncome[s][tenant] {
		var y int
		if _, err := fmt.Sscanf(in.Period, "%4d", &y); err == nil && !seen[y] {
			seen[y] = true
			out = append(out, y)
		}
	}
	sort.Sort(sort.Reverse(sort.IntSlice(out)))
	return out, nil
}

// UpsertIncomeInvoices is IncomeInvoiceStore on Memory.
func (s *Memory) UpsertIncomeInvoices(_ context.Context, tenant string, rows []IncomeInvoice) (int, int, error) {
	if err := checkTenant(tenant); err != nil {
		return 0, 0, err
	}
	if i, why := CheckIncomeInvoices(rows); why != "" {
		return 0, 0, fmt.Errorf("%w: row %d: %s", ErrIncomeInvoice, i, why)
	}
	memIncomeMu.Lock()
	defer memIncomeMu.Unlock()
	if memIncome[s] == nil {
		memIncome[s] = map[string]map[string]IncomeInvoice{}
	}
	if memIncome[s][tenant] == nil {
		memIncome[s][tenant] = map[string]IncomeInvoice{}
	}
	ins, upd := 0, 0
	for _, in := range rows {
		if _, ok := memIncome[s][tenant][in.InvoiceNo]; ok {
			upd++
		} else {
			ins++
		}
		memIncome[s][tenant][in.InvoiceNo] = in
	}
	return ins, upd, nil
}

var _ IncomeInvoiceStore = (*Memory)(nil)
