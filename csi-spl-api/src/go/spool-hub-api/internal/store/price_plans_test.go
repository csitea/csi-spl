package store

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 181 row B1 (rdb 0302): the private-workspace price on both drivers.
// RED CONTROL (P5): a plan with a token line is refused and writes nothing;
// on Postgres the CHECKs refuse the same line written past the store. The
// month quote, what the monthly invoice in arrears charges (Q-9 B), is
// seats x 9 EUR + the VM cost + 33%.

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

// TestPricePlanNoTokenCheckAnyCase: the no-token CHECK of rdb 0302 holds a
// later widening of the line list in any case. The line list is dropped in a
// rolled-back transaction, so 'TOKEN' and 'LLM_X' reach that CHECK.
// RED CONTROL: without lower() in the CHECK both are written.
func TestPricePlanNoTokenCheckAnyCase(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	if err := seedPricePlan(ctx, pg, tenant); err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{"TOKEN", "LLM_X", "Ai_Token_Resale"} {
		tx, err := pg.pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		_, err = tx.Exec(ctx, `ALTER TABLE price_plan_lines DROP CONSTRAINT price_plan_lines_line_check`)
		if err == nil {
			_, err = tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant)
		}
		if err != nil {
			tx.Rollback(ctx) //nolint:errcheck
			t.Fatal(err)
		}
		_, err = tx.Exec(ctx, `INSERT INTO price_plan_lines (tenant_id, line, margin_pct) VALUES ($1, $2, 33)`, tenant, line)
		tx.Rollback(ctx) //nolint:errcheck
		var pe *pgconn.PgError
		if !errors.As(err, &pe) || pe.Code != "23514" || pe.ConstraintName != "price_plan_lines_no_token_check" {
			t.Errorf("line %q past a widened list: %v, want 23514 by price_plan_lines_no_token_check", line, err)
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
