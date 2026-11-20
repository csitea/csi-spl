package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Spec 181 row B1 (rdb 0302): the private-workspace price on both drivers.
// RED CONTROL (P5): a plan with a token line is refused and writes nothing;
// on Postgres the CHECKs refuse the same line written past the store. The
// month quote is seats x 9 EUR + the VM cost + 33%; a VM day is drawn from
// the prepaid balance once, never twice.

// seedPricePlan writes the private-VM plan of tenant through the store API
// (crosstenant_test.go seeds both rdb 0302 tables with it).
func seedPricePlan(ctx context.Context, pg *Postgres, tenant string) error {
	return pg.PutPricePlan(ctx, tenant, PrivateVMPlan())
}

func TestPricePlanTokenLineRefused(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			pp := s.(PricePlans)
			tenant := newTenant(t, s)
			for _, line := range []string{UsageKindIn, UsageKindOut, "llm_tokens_cache_read", "tokens", "AI_Tokens_resale"} {
				p := PrivateVMPlan()
				p.Lines = append(p.Lines, PlanLine{Line: line, CentsPerMonth: 1})
				if err := pp.PutPricePlan(ctx, tenant, p); !errors.Is(err, ErrPlanTokenLine) {
					t.Errorf("a plan with the token line %q: %v, want ErrPlanTokenLine (spec 181 P5)", line, err)
				}
				if _, err := p.QuoteMonth(1, 0); !errors.Is(err, ErrPlanTokenLine) {
					t.Errorf("a quote of a plan with the token line %q: %v, want ErrPlanTokenLine", line, err)
				}
			}
			if _, err := pp.PricePlan(ctx, tenant); !errors.Is(err, ErrNoPricePlan) {
				t.Errorf("after refused plans the workspace reads %v, want ErrNoPricePlan (nothing written)", err)
			}
			// CONTROL: the same workspace takes the plan without the token line.
			if err := pp.PutPricePlan(ctx, tenant, PrivateVMPlan()); err != nil {
				t.Fatalf("the private-VM plan: %v", err)
			}
		})
	}
}

// TestPricePlanTokenLineRefusedByRdb: rdb 0302 refuses a token line written
// past the store (23514), and a seat line with a margin (the shape CHECK).
func TestPricePlanTokenLineRefusedByRdb(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	if err := seedPricePlan(ctx, pg, tenant); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`INSERT INTO price_plan_lines (tenant_id, line, cents_per_month) VALUES ($1, 'llm_tokens_in', 1)`,
		`INSERT INTO price_plan_lines (tenant_id, line, margin_pct) VALUES ($1, 'token_resale', 33)`,
		`UPDATE price_plan_lines SET line = 'llm_tokens_out' WHERE tenant_id = $1 AND line = 'vm_cost'`,
		`UPDATE price_plan_lines SET margin_pct = 33 WHERE tenant_id = $1 AND line = 'seat_member'`,
		`UPDATE price_plans SET currency = 'USD' WHERE tenant_id = $1`,
	} {
		if _, err := pg.execTenant(ctx, tenant, q, tenant); pgCode(err) != "23514" {
			t.Errorf("%s: %v, want a CHECK refusal (23514)", q, err)
		}
	}
}

func TestPricePlanQuoteAndRoundTrip(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			pp := s.(PricePlans)
			tenant := newTenant(t, s)
			if err := pp.PutPricePlan(ctx, tenant, PrivateVMPlan()); err != nil {
				t.Fatal(err)
			}
			p, err := pp.PricePlan(ctx, tenant)
			if err != nil {
				t.Fatal(err)
			}
			seat, _ := p.Line(PlanLineSeatMember)
			vm, _ := p.Line(PlanLineVMCost)
			if p.Kind != PlanKindPrivateVM || p.Currency != "EUR" || len(p.Lines) != 2 || seat.CentsPerMonth != 900 || vm.MarginPct != 33 {
				t.Fatalf("plan read back %+v, want private_vm EUR, seat 900 cents, VM +33%%", p)
			}
			// 3 members x 9 EUR = 27 EUR; a 30 EUR VM month + 33% = 39.90 EUR.
			q, err := p.QuoteMonth(3, 30_000_000)
			if err != nil || q.SeatCents != 2700 || q.VMPriceMicros != "39900000.000000" || q.TotalMicros != "66900000.000000" {
				t.Errorf("QuoteMonth(3, 30 EUR) = %+v, %v; want 2700 cents + 39.90 EUR = 66.90 EUR", q, err)
			}
			if _, err := p.QuoteMonth(-1, 0); err == nil {
				t.Error("a negative member count is quoted")
			}
		})
	}
}

func TestPricePlanDrawVMDay(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			pp, ul := s.(PricePlans), s.(UsageLedger)
			tenant := newTenant(t, s)
			day := time.Date(2026, 11, 19, 0, 0, 0, 0, time.UTC)
			d := VMDay{VM: "ws-vm-1", Day: day, CostMicros: 3_000_000, At: day.Add(25 * time.Hour)}
			if _, err := pp.DrawVMDay(ctx, tenant, d); !errors.Is(err, ErrNoPricePlan) {
				t.Fatalf("a draw without a plan: %v, want ErrNoPricePlan", err)
			}
			if err := pp.PutPricePlan(ctx, tenant, PrivateVMPlan()); err != nil {
				t.Fatal(err)
			}
			if n, err := pp.DrawVMDay(ctx, tenant, d); err != nil || n != 1 {
				t.Fatalf("DrawVMDay = %d, %v; want 1 row", n, err)
			}
			if n, err := pp.DrawVMDay(ctx, tenant, d); err != nil || n != 0 {
				t.Errorf("the same day drawn again = %d, %v; want 0 (never a second charge)", n, err)
			}
			got, err := ul.TurnLedger(ctx, tenant, d.turnID())
			if err != nil || got.CostMicros != "3990000.000000" || got.Currency != "EUR" {
				t.Errorf("the drawn day reads %+v, %v; want 3 EUR + 33%% = 3990000 micros EUR", got, err)
			}
			if _, err := pp.DrawVMDay(ctx, tenant, VMDay{VM: "Bad VM", Day: day, CostMicros: 1, At: d.At}); err == nil {
				t.Error("a draw for a VM name that is no VM name is written")
			}
		})
	}
}

// TestPricePlanDrawLowersBalance: on Postgres the drawn day is spent from
// the workspace's prepaid top-up (token_budgets), the cost + 33% exactly.
func TestPricePlanDrawLowersBalance(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	day := time.Date(2026, 11, 19, 0, 0, 0, 0, time.UTC)
	top := int64(20_000_000)
	if _, err := pg.PutTokenBudget(ctx, tenant, TokenBudget{TopupMicros: &top, TopupCurrency: "EUR", ToppedUpAt: day}); err != nil {
		t.Fatal(err)
	}
	if err := seedPricePlan(ctx, pg, tenant); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.DrawVMDay(ctx, tenant, VMDay{VM: "ws-vm-1", Day: day, CostMicros: 3_000_000, At: day.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	uses, err := pg.BudgetUses(ctx, tenant, "", day.Add(2*time.Hour))
	if err != nil || len(uses) != 1 || uses[0].SpentMicros != "3990000.000000" || uses[0].DayTokens != 0 {
		t.Fatalf("budget after the VM day: %+v, %v; want 3990000 micros spent, 0 tokens", uses, err)
	}
}
