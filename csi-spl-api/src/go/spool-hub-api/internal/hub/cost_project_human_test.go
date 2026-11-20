package hub_test

import (
	"context"
	"net/http"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/jackc/pgx/v5"
)

// Spec 123 13.8 row P02: the served project cost carries the Human part
// from the store's human read. On Postgres the hours and prices are seeded
// for real; on the memory store costReadStub answers the seeded days of the
// workspace asked for, as RLS would.

// costHumanSeed is workspace -> its human days (the memory stand-in's).
var costHumanSeed sync.Map

func (c *costReadStub) CostProjectHumanDays(_ context.Context, q store.CostProjectHumanQuery) ([]store.CostProjectHumanDay, error) {
	days, _ := costHumanSeed.Load(q.Tenant)
	out, _ := days.([]store.CostProjectHumanDay)
	return append([]store.CostProjectHumanDay{}, out...), nil
}

// costHumanSeedOp gives the operator workspace 120 approved minutes on
// 2011-03-04 at 60 USD/h: 120.00 USD.
func costHumanSeedOp(t *testing.T, e *env, op string, stub *costReadStub) {
	t.Helper()
	if stub != nil {
		usd, amount := "USD", int64(120_000_000)
		costHumanSeed.Store(op, []store.CostProjectHumanDay{{Day: "2011-03-04", Currency: &usd, Minutes: 120,
			AmountMicros: &amount, USDMicros: &amount, EURMicros: &amount, SecondMicros: &amount}})
		return
	}
	ctx := context.Background()
	err := pgx.BeginFunc(ctx, e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, op); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO member_hourly_prices (tenant_id, member_id, valid_from, amount_micros, currency, set_by)
			VALUES ($1, 'HUM-p02', '2011-03-01', 60000000, 'USD', 'HUM-owner')`, op); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO hours_periods (tenant_id, member_id, period_start, period_end, state, decided_by)
			VALUES ($1, 'HUM-p02', '2011-03-01', '2011-03-31', 'frozen', 'HUM-owner')`, op); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, state, updated_by)
			VALUES ($1, 'HUM-p02', '2011-03-04', 'ws', 120, 'approved', 'HUM-p02')`, op)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

// TestCostProjectHumanServed: the operator admin's answer carries the Human
// part's 120 minutes (a frozen period, none pending); the other workspace,
// which booked nothing, reads 0 minutes. Only the minutes are asserted: the
// admin holds no hours.rates, so after P03's mask its Human money is null
// (13.6); the money itself is TestCostProjectHumanSum's. RED on the parent
// (no human read in the hub): Human is not_tracked, with no minutes.
func TestCostProjectHumanServed(t *testing.T) {
	e, op, other, who, whoOther, stub := costReadEnv(t)
	costHumanSeedOp(t, e, op, stub)
	code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs/project?month=2011-03", who[rbac.Admin], nil)
	_, by := projectParts(t, body)
	if h := by["human"]; code != http.StatusOK || h["completeness"] == "not_tracked" || h["minutes"] != float64(120) || h["pending_minutes"] != float64(0) {
		t.Fatalf("operator admin human %v (%d): want 120 min, 0 pending", h, code)
	}
	code, body = call(t, e, other, http.MethodGet, "/v1/tenant/costs/project?month=2011-03", whoOther[rbac.Admin], nil)
	_, by = projectParts(t, body)
	if h := by["human"]; code != http.StatusOK || h["minutes"] != float64(0) || h["completeness"] == "not_tracked" {
		t.Errorf("other admin human %v (%d): want 0 min, none of the operator's minutes", h, code)
	}
}
