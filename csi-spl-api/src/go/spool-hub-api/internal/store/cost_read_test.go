package store

import (
	"context"
	"crypto/rand"
	"fmt"
	"math/big"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 123 lane 4b: the month read of the cost report. Postgres only
// (SPOOL_TEST_PG_DSN). Estate rows are shared by every test on the database,
// so each test reads a month of its own (costTestMonth).

var costMonthsTaken sync.Map

// costTestMonth is a random past month (2001..2019) no other test of this
// run writes.
func costTestMonth(t *testing.T) (from, to string, day func(int) string) {
	t.Helper()
	var n *big.Int
	for {
		var err error
		if n, err = rand.Int(rand.Reader, big.NewInt(19*12)); err != nil {
			t.Fatal(err)
		}
		if _, taken := costMonthsTaken.LoadOrStore(n.Int64(), true); !taken {
			break
		}
	}
	y, m := 2001+int(n.Int64())/12, 1+int(n.Int64())%12
	ny, nm := y, m+1
	if nm == 13 {
		ny, nm = y+1, 1
	}
	return fmt.Sprintf("%04d-%02d-01", y, m), fmt.Sprintf("%04d-%02d-01", ny, nm),
		func(d int) string { return fmt.Sprintf("%04d-%02d-%02d", y, m, d) }
}

// costSeed writes one cost line (tenant "" = estate) under the operator scope.
func costSeed(t *testing.T, pg *Postgres, tenant, day, source, pov, kind, origin string, units float64, usd, eur int64) {
	t.Helper()
	var tid any
	if tenant != "" {
		tid = tenant
	}
	ctx := context.Background()
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO cost_lines (day, source, project_or_vendor, tenant_id, kind, units,
			amount_micros, currency, usd_micros, eur_micros, fx_rate_day, origin, run_id)
			VALUES ($1::date, $2, $3, $4, $5, $6, $7, 'USD', $7, $8, $1::date, $9, 'run-1')`,
			day, source, pov, tid, kind, units, usd, eur, origin)
		return err
	}); err != nil {
		t.Fatal(err)
	}
}

func costCover(t *testing.T, pg *Postgres, day, source, state string) {
	t.Helper()
	ctx := context.Background()
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO cost_coverage (day, source, state, reason, run_id)
			VALUES ($1::date, $2, $3, NULLIF($4, ''), 'run-1')`, day, source, state, map[bool]string{true: "", false: "test"}[state == "ok"])
		return err
	}); err != nil {
		t.Fatal(err)
	}
}

func partsBy(parts []CostPart) map[string]CostPart {
	m := map[string]CostPart{}
	for _, p := range parts {
		m[fmt.Sprintf("%t/%s/%s/%s", p.Estate, p.Source, p.ProjectOrVendor, p.Kind)] = p
	}
	return m
}

// TestCostMonthReadSums: the month's lines summed per part, units and both
// currencies, days counted; a line of the day before the month and of the
// first day after it is not in it (month math, To exclusive); coverage per
// source per state, CoverTo ending the count.
func TestCostMonthReadSums(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	from, to, day := costTestMonth(t)
	a := newTenant(t, pg)
	pov, gcp, tok := uid("csi-spl-"), uid("gcp-"), uid("fleet_tokens.")
	costSeed(t, pg, "", day(1), gcp, pov, "cloud_run", "billing_export", 0, 1_500_000, 1_380_000)
	costSeed(t, pg, "", day(2), gcp, pov, "cloud_run", "billing_export", 0, 500_000, 460_000)
	costSeed(t, pg, "", day(2), tok, "claude", "output.standard", "transcript", 107, 0, 0)
	costSeed(t, pg, "", to, gcp, pov, "cloud_run", "billing_export", 0, 9_000_000, 9_000_000) // next month
	costSeed(t, pg, a, day(3), "hand", "openai", "invoice", "hand", 0, 20_000_000, 18_400_000)
	costCover(t, pg, day(1), gcp, "ok")
	costCover(t, pg, day(2), gcp, "missing")
	costCover(t, pg, day(3), gcp, "partial")
	costCover(t, pg, day(2), tok, "partial")

	got, err := pg.CostMonthRead(ctx, CostMonthQuery{Tenant: a, Estate: true, From: from, To: to})
	if err != nil {
		t.Fatal(err)
	}
	m := partsBy(got.Parts)
	if g := m["true/"+gcp+"/"+pov+"/cloud_run"]; g.USDMicros != 2_000_000 || g.EURMicros != 1_840_000 || g.Days != 2 || g.Origin != "billing_export" {
		t.Errorf("gcp part %+v, want 2 days, 2.00 USD, 1.84 EUR (the next month's 9.00 not in it)", g)
	}
	if g := m["true/"+tok+"/claude/output.standard"]; g.Units != 107 || g.USDMicros != 0 {
		t.Errorf("token part %+v, want 107 units, 0 USD", g)
	}
	if g := m["false/hand/openai/invoice"]; g.USDMicros != 20_000_000 || g.Origin != "hand" {
		t.Errorf("the workspace's own hand row %+v", g)
	}
	if len(got.Parts) != 3 || !got.Parts[0].Estate || got.Parts[2].Estate {
		t.Errorf("parts %+v: want 3, estate first", got.Parts)
	}
	cov := map[string]CostSourceDays{}
	for _, c := range got.Coverage {
		cov[c.Source] = c
	}
	if c := cov[gcp]; c.OK != 1 || c.Missing != 1 || c.Partial != 1 {
		t.Errorf("gcp coverage %+v", c)
	}
	got, err = pg.CostMonthRead(ctx, CostMonthQuery{Tenant: a, Estate: true, From: from, To: to, CoverTo: day(3)})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range got.Coverage {
		if c.Source == gcp && (c.OK != 1 || c.Missing != 1 || c.Partial != 0) {
			t.Errorf("CoverTo day 3: gcp coverage %+v, want day 3 not counted", c)
		}
	}
	for _, bad := range []CostMonthQuery{{Tenant: "", From: from, To: to}, {Tenant: a, From: to, To: from},
		{Tenant: a, From: from, To: to, CoverTo: "2000-01-01"}, {Tenant: a, From: "2001-01-01", To: "2001-03-01"}} {
		if _, err := pg.CostMonthRead(ctx, bad); err == nil {
			t.Errorf("%+v accepted", bad)
		}
	}
}

// TestCostMonthReadRLS (spec 123 section 8 "Tenant isolation" and "Estate
// scope"): workspace B's read holds none of A's rows and no estate row, even
// when the statement itself admits estate rows ($4 true) under B's tenant
// scope: RLS is the guard. Its coverage names only B's own sources.
// CONTROL: the same statement under the operator scope reads the estate row
// and A's, so B's zeros are the policy's, not an empty month.
func TestCostMonthReadRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	from, to, day := costTestMonth(t)
	a, b := newTenant(t, pg), newTenant(t, pg)
	gcp, hand := uid("gcp-"), uid("hand-")
	costSeed(t, pg, "", day(5), gcp, uid("csi-spl-"), "cloud_sql", "billing_export", 0, 3_000_000, 2_760_000)
	costSeed(t, pg, a, day(5), hand, "a-invoice", "invoice", "hand", 0, 1_000_000, 920_000)
	costSeed(t, pg, b, day(6), hand, "b-invoice", "invoice", "hand", 0, 2_000_000, 1_840_000)
	costCover(t, pg, day(5), gcp, "ok")
	costCover(t, pg, day(6), hand, "ok")

	got, err := pg.CostMonthRead(ctx, CostMonthQuery{Tenant: b, From: from, To: to})
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Parts) != 1 || got.Parts[0].ProjectOrVendor != "b-invoice" || got.Parts[0].Estate {
		t.Errorf("B reads %+v, want its own row only", got.Parts)
	}
	if len(got.Coverage) != 1 || got.Coverage[0].Source != hand {
		t.Errorf("B's coverage %+v, want its own source only", got.Coverage)
	}
	q := CostMonthQuery{Tenant: b, Estate: true, From: from, To: to}
	var forced, control CostMonth
	if err := pg.inTenant(ctx, b, func(tx pgx.Tx) (err error) { forced, err = costMonthIn(ctx, tx, q); return err }); err != nil {
		t.Fatal(err)
	}
	for _, p := range forced.Parts {
		if p.Estate || p.ProjectOrVendor == "a-invoice" {
			t.Errorf("under B's scope with the estate asked for, B reads %+v", p)
		}
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) (err error) { control, err = costMonthIn(ctx, tx, q); return err }); err != nil {
		t.Fatal(err)
	}
	if est := partsBy(control.Parts); len(control.Parts) != 2 || !control.Parts[0].Estate || est["false/"+hand+"/b-invoice/invoice"].USDMicros != 2_000_000 {
		t.Errorf("CONTROL: the operator scope reads %+v, want the estate row and B's", control.Parts)
	}
}
