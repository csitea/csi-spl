package store

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/jackc/pgx/v5"
)

// The private-workspace price (spec 181 row B1, sections 0.2 and 4, rdb
// 0302): a workspace's plan has two lines, never more. The seat line is
// cents per human member per month (agents are not seats, Q-6 A); the VM
// line is the VM's cloud cost (compute, disk, traffic, Q-8 A) + its margin,
// one rate of 33% for every workspace (Q-11 A); the currency is EUR (Q-7 A).
// No AI token is ever sold (P5, Q-10 A): a plan with a token line is
// refused here (ErrPlanTokenLine) and by rdb 0302's CHECKs.
//
// The plan is invoiced monthly in arrears, no prepaid balance (Q-9 B,
// Q-16 B): QuoteMonth prices one month (seats x cents + the VM's month cost
// x 1.33), exactly the invoice. Writing the invoice is a later row, not B1.

// The plan's kind, currency and lines (rdb 0302).
const (
	PlanKindPrivateVM  = "private_vm"
	PlanCurrency       = "EUR"
	PlanLineSeatMember = "seat_member"
	PlanLineVMCost     = "vm_cost"
	// PrivateVMSeatCents is 9 EUR per human member per month (Q-6 A, Q-7 A).
	PrivateVMSeatCents = 900
	// PrivateVMMarginPct is the one rate on the VM's cloud cost (Q-11 A).
	PrivateVMMarginPct = 33
	centMicros         = 10_000
)

var (
	// ErrPlanTokenLine: a plan line that would sell AI tokens (spec 181 P5).
	ErrPlanTokenLine = errors.New("store: a price plan never carries a token line (spec 181 P5)")
	// ErrNoPricePlan: the workspace has no price plan, or it has no VM line.
	ErrNoPricePlan = errors.New("store: no price plan")
)

// PlanLine is one price_plan_lines row: CentsPerMonth for the seat line,
// MarginPct for the VM line.
type PlanLine struct {
	Line          string
	CentsPerMonth int64
	MarginPct     int64
}

// PricePlan is a workspace's price: its kind, currency and lines.
type PricePlan struct {
	Kind     string
	Currency string
	Lines    []PlanLine
}

// PrivateVMPlan is the plan spec 181 sells: 9 EUR per human member per
// month and the VM's cloud cost + 33%.
func PrivateVMPlan() PricePlan {
	return PricePlan{Kind: PlanKindPrivateVM, Currency: PlanCurrency, Lines: []PlanLine{
		{Line: PlanLineSeatMember, CentsPerMonth: PrivateVMSeatCents},
		{Line: PlanLineVMCost, MarginPct: PrivateVMMarginPct},
	}}
}

// Line is the plan's line named name.
func (p PricePlan) Line(name string) (PlanLine, bool) {
	for _, l := range p.Lines {
		if l.Line == name {
			return l, true
		}
	}
	return PlanLine{}, false
}

// tokenLine reports whether a line name would price AI tokens.
func tokenLine(name string) bool {
	n := strings.ToLower(name)
	return strings.HasPrefix(n, "llm_") || strings.Contains(n, "token")
}

// checkPricePlan is the Go side of rdb 0302's CHECKs: the one kind and
// currency, exactly the seat line and the VM line, each in its shape. A
// token line is ErrPlanTokenLine before any other check of the lines.
func checkPricePlan(p PricePlan) error {
	for _, l := range p.Lines {
		if tokenLine(l.Line) {
			return fmt.Errorf("%w: %q", ErrPlanTokenLine, l.Line)
		}
	}
	if p.Kind != PlanKindPrivateVM || p.Currency != PlanCurrency {
		return fmt.Errorf("price plan: kind %q currency %q, want %s %s", p.Kind, p.Currency, PlanKindPrivateVM, PlanCurrency)
	}
	seen := map[string]bool{}
	for _, l := range p.Lines {
		switch {
		case seen[l.Line]:
			return fmt.Errorf("price plan: line %q twice", l.Line)
		case l.Line == PlanLineSeatMember && (l.CentsPerMonth < 0 || l.MarginPct != 0):
			return fmt.Errorf("price plan: the seat line takes cents per month >= 0 and no margin")
		case l.Line == PlanLineVMCost && (l.MarginPct < 0 || l.MarginPct > 100 || l.CentsPerMonth != 0):
			return fmt.Errorf("price plan: the VM line takes a margin of 0..100 %% and no cents")
		case l.Line != PlanLineSeatMember && l.Line != PlanLineVMCost:
			return fmt.Errorf("price plan: unknown line %q", l.Line)
		}
		seen[l.Line] = true
	}
	if len(seen) != 2 {
		return fmt.Errorf("price plan: a plan has the seat line and the VM line")
	}
	return nil
}

// PriceQuote is one month of a plan: the seat line in cents, the VM line as
// its cloud cost and its price in micros (exact decimal), and the total in
// micros. It has no token field: the plan sells none.
type PriceQuote struct {
	Currency      string
	Humans        int64
	SeatCents     int64
	VMCostMicros  int64
	VMPriceMicros string
	TotalMicros   string
}

// vmUnitCost is (100 + margin) / 100, exact: the price of one micro of VM
// cost.
func vmUnitCost(marginPct int64) *big.Rat { return big.NewRat(100+marginPct, 100) }

// QuoteMonth prices a month of humans members on a VM whose month costs
// vmCostMicros: seats x cents, the VM cost x (100 + margin) / 100.
func (p PricePlan) QuoteMonth(humans, vmCostMicros int64) (PriceQuote, error) {
	if err := checkPricePlan(p); err != nil {
		return PriceQuote{}, err
	}
	if humans < 0 || vmCostMicros < 0 {
		return PriceQuote{}, fmt.Errorf("price quote: members and VM cost are >= 0")
	}
	seat, _ := p.Line(PlanLineSeatMember)
	vm, _ := p.Line(PlanLineVMCost)
	q := PriceQuote{Currency: p.Currency, Humans: humans, SeatCents: humans * seat.CentsPerMonth, VMCostMicros: vmCostMicros}
	vmPrice := new(big.Rat).Mul(big.NewRat(vmCostMicros, 1), vmUnitCost(vm.MarginPct))
	q.VMPriceMicros = vmPrice.FloatString(usageCostDecimal)
	q.TotalMicros = vmPrice.Add(vmPrice, big.NewRat(q.SeatCents*centMicros, 1)).FloatString(usageCostDecimal)
	return q, nil
}

// PricePlans is the store half of the private-workspace price. Optional: a
// store without it sells no private workspace.
type PricePlans interface {
	// PutPricePlan writes the workspace's plan, lines replaced whole.
	// ErrPlanTokenLine: a line would sell tokens; nothing is written.
	PutPricePlan(ctx context.Context, tenant string, p PricePlan) error
	// PricePlan reads it back; ErrNoPricePlan when none.
	PricePlan(ctx context.Context, tenant string) (PricePlan, error)
}

var (
	_ PricePlans = (*Memory)(nil)
	_ PricePlans = (*Postgres)(nil)
)

// Memory side: a map beside the Memory struct, guarded by s.mu.
var memPlans = map[*Memory]map[string]PricePlan{}

// PutPricePlan writes the workspace's plan (PricePlans).
func (s *Memory) PutPricePlan(_ context.Context, tenant string, p PricePlan) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if err := checkPricePlan(p); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if memPlans[s] == nil {
		memPlans[s] = map[string]PricePlan{}
	}
	p.Lines = append([]PlanLine(nil), p.Lines...)
	memPlans[s][tenant] = p
	return nil
}

// PricePlan reads the workspace's plan (PricePlans).
func (s *Memory) PricePlan(_ context.Context, tenant string) (PricePlan, error) {
	if err := checkTenant(tenant); err != nil {
		return PricePlan{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := memPlans[s][tenant]
	if !ok {
		return PricePlan{}, ErrNoPricePlan
	}
	p.Lines = append([]PlanLine(nil), p.Lines...)
	return p, nil
}

// Postgres side.
const (
	planPutSQL = `INSERT INTO price_plans (tenant_id, kind, currency) VALUES ($1, $2, $3)
		ON CONFLICT (tenant_id) DO UPDATE SET kind = EXCLUDED.kind, currency = EXCLUDED.currency, updated_at = now()`
	planLinesDropSQL = `DELETE FROM price_plan_lines WHERE tenant_id = $1`
	planLinePutSQL   = `INSERT INTO price_plan_lines (tenant_id, line, cents_per_month, margin_pct)
		VALUES ($1, $2, CASE WHEN $2 = 'seat_member' THEN $3::bigint END, CASE WHEN $2 = 'vm_cost' THEN $4::smallint END)`
	planReadSQL      = `SELECT kind, currency FROM price_plans WHERE tenant_id = $1`
	planLinesReadSQL = `SELECT line, coalesce(cents_per_month, 0), coalesce(margin_pct, 0)::bigint
		FROM price_plan_lines WHERE tenant_id = $1 ORDER BY line`
)

// PutPricePlan writes the workspace's plan (PricePlans).
func (s *Postgres) PutPricePlan(ctx context.Context, tenant string, p PricePlan) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if err := checkPricePlan(p); err != nil {
		return err
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, planPutSQL, tenant, p.Kind, p.Currency); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, planLinesDropSQL, tenant); err != nil {
			return err
		}
		for _, l := range p.Lines {
			if _, err := tx.Exec(ctx, planLinePutSQL, tenant, l.Line, l.CentsPerMonth, l.MarginPct); err != nil {
				return err
			}
		}
		return nil
	})
}

// PricePlan reads the workspace's plan (PricePlans).
func (s *Postgres) PricePlan(ctx context.Context, tenant string) (PricePlan, error) {
	if err := checkTenant(tenant); err != nil {
		return PricePlan{}, err
	}
	var p PricePlan
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, planReadSQL, tenant).Scan(&p.Kind, &p.Currency); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, planLinesReadSQL, tenant)
		if err != nil {
			return err
		}
		p.Lines, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (PlanLine, error) {
			var l PlanLine
			return l, r.Scan(&l.Line, &l.CentsPerMonth, &l.MarginPct)
		})
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return PricePlan{}, ErrNoPricePlan
	}
	return p, err
}
